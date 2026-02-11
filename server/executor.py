"""Job executor for the BTB Service.

Manages the full lifecycle of a single btb run: clone the repository,
optionally continue from a prior retry's results branch, run btb inside
``script`` for terminal capture, push results back, preserve logs, and
clean up the working directory.

Enforces a single-job-at-a-time invariant — only one btb process may
run at any given time.
"""

import asyncio
import logging
import os
import platform
import shutil
import signal
from pathlib import Path
from typing import Optional

from server.models import Job, PushResult
from server.pusher import ResultPusher
from server.queue import JobQueue

logger = logging.getLogger(__name__)

# Grace period (seconds) between SIGTERM and SIGKILL on timeout
KILL_GRACE_PERIOD = 10


class JobExecutor:
    """Executes a single btb job with full lifecycle management.

    The executor clones the repository, optionally merges prior retry
    work, runs ``setup.sh`` and ``btb.sh`` inside the ``script`` command
    for terminal capture, then handles result push-back, log
    preservation, and working directory cleanup.

    Args:
        btb_path: Absolute path to the btb installation directory.
        jobs_dir: Base directory for per-job working directories.
        logs_dir: Persistent directory for preserved btb logs.
        pusher: ResultPusher instance for pushing results back.
        queue: JobQueue instance for completing jobs.
        job_timeout: Maximum seconds a btb run may take before timeout.
    """

    def __init__(
        self,
        btb_path: str,
        jobs_dir: str,
        logs_dir: str,
        pusher: ResultPusher,
        queue: JobQueue,
        job_timeout: int = 7200,
    ) -> None:
        self._btb_path = btb_path
        self._jobs_dir = Path(jobs_dir)
        self._logs_dir = Path(logs_dir)
        self._pusher = pusher
        self._queue = queue
        self._job_timeout = job_timeout

        self._running = False
        self._current_job: Optional[Job] = None
        self._process: Optional[asyncio.subprocess.Process] = None

    def is_running(self) -> bool:
        """Return whether a job is currently being executed."""
        return self._running

    def get_current_job(self) -> Optional[Job]:
        """Return the currently running job, or None."""
        return self._current_job

    def kill_current(self) -> None:
        """Send SIGTERM to the current btb process group.

        If no process is running this is a no-op.
        """
        if self._process is None or self._process.returncode is not None:
            return
        try:
            pgid = os.getpgid(self._process.pid)
            os.killpg(pgid, signal.SIGTERM)
            logger.info("Sent SIGTERM to process group %d", pgid)
        except (ProcessLookupError, OSError) as exc:
            logger.warning("Failed to kill process group: %s", exc)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _job_dir(self, job: Job) -> Path:
        """Return the top-level working directory for a job."""
        return self._jobs_dir / job.id

    def _repo_dir(self, job: Job) -> Path:
        """Return the cloned repo directory inside the job working dir."""
        return self._job_dir(job) / "repo"

    def _typescript_path(self, job: Job) -> Path:
        """Return the path to the typescript log file."""
        return self._job_dir(job) / "typescript.log"

    async def _run_subprocess(
        self,
        args: list[str],
        cwd: str,
        timeout: Optional[float] = None,
    ) -> tuple[int, str, str]:
        """Run a command as an async subprocess and return results.

        Args:
            args: Command and arguments.
            cwd: Working directory.
            timeout: Optional timeout in seconds.

        Returns:
            Tuple of (return_code, stdout, stderr).
        """
        proc = await asyncio.create_subprocess_exec(
            *args,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return -1, "", "Command timed out"

        stdout = stdout_bytes.decode("utf-8", errors="replace").strip()
        stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
        return proc.returncode, stdout, stderr

    async def _clean_stale_workdir(self, job: Job) -> None:
        """Remove a stale working directory if it already exists.

        Logs a warning before deleting — a leftover directory indicates
        a previous run did not clean up properly.
        """
        job_dir = self._job_dir(job)
        if job_dir.exists():
            logger.warning(
                "Stale working directory found for job %s at %s — deleting",
                job.id,
                job_dir,
            )
            shutil.rmtree(str(job_dir), ignore_errors=True)

    async def _clone_repo(self, job: Job) -> int:
        """Clone the repository and checkout the target commit.

        Returns:
            0 on success, non-zero on failure.
        """
        repo_dir = self._repo_dir(job)
        job_dir = self._job_dir(job)
        job_dir.mkdir(parents=True, exist_ok=True)

        # Clone at the specified branch
        rc, _out, err = await self._run_subprocess(
            [
                "git", "clone",
                "--branch", job.branch,
                job.repo_url,
                str(repo_dir),
            ],
            cwd=str(job_dir),
            timeout=300,  # 5 min clone timeout
        )
        if rc != 0:
            logger.error("git clone failed for job %s: %s", job.id, err)
            return rc

        # Checkout the exact commit SHA
        rc, _out, err = await self._run_subprocess(
            ["git", "checkout", job.commit_sha],
            cwd=str(repo_dir),
            timeout=60,
        )
        if rc != 0:
            logger.error("git checkout failed for job %s: %s", job.id, err)
            return rc

        return 0

    async def _handle_retry_continuation(self, job: Job) -> None:
        """If this is a retry, fetch and merge prior btb work.

        Checks if ``btb-results/{branch}`` exists on the remote. If it
        does, fetches and merges the prior run's results so btb can
        continue from where it left off.

        Failures here are non-fatal — if the fetch/merge fails, btb
        simply starts from scratch.
        """
        if not job.retry_of:
            return

        repo_dir = self._repo_dir(job)
        results_branch = f"btb-results/{job.branch}"

        # Check if the results branch exists on the remote
        rc, out, _err = await self._run_subprocess(
            ["git", "ls-remote", "--heads", "origin", results_branch],
            cwd=str(repo_dir),
            timeout=60,
        )
        if rc != 0 or not out.strip():
            logger.info(
                "No results branch %s found for retry job %s — starting fresh",
                results_branch,
                job.id,
            )
            return

        # Fetch the results branch
        rc, _out, err = await self._run_subprocess(
            ["git", "fetch", "origin", results_branch],
            cwd=str(repo_dir),
            timeout=120,
        )
        if rc != 0:
            logger.warning(
                "Failed to fetch results branch %s for job %s: %s — starting fresh",
                results_branch,
                job.id,
                err,
            )
            return

        # Merge the results branch (allow unrelated histories in case of force-push)
        rc, _out, err = await self._run_subprocess(
            [
                "git", "merge", "FETCH_HEAD",
                "--no-edit",
                "--allow-unrelated-histories",
            ],
            cwd=str(repo_dir),
            timeout=60,
        )
        if rc != 0:
            logger.warning(
                "Failed to merge results branch for job %s: %s — starting fresh",
                job.id,
                err,
            )
            # Reset to clean state
            await self._run_subprocess(
                ["git", "merge", "--abort"],
                cwd=str(repo_dir),
                timeout=30,
            )
            return

        logger.info(
            "Merged prior btb work from %s for retry job %s",
            results_branch,
            job.id,
        )

    async def _run_setup(self, job: Job) -> int:
        """Run btb's setup.sh to install agents.

        Returns:
            0 on success, non-zero on failure.
        """
        setup_script = os.path.join(self._btb_path, "setup.sh")
        repo_dir = self._repo_dir(job)

        rc, _out, err = await self._run_subprocess(
            [setup_script],
            cwd=str(repo_dir),
            timeout=120,
        )
        if rc != 0:
            logger.error("setup.sh failed for job %s: %s", job.id, err)
        return rc

    async def _run_btb(self, job: Job) -> int:
        """Run btb inside ``script`` for terminal capture.

        Detects the platform and uses the appropriate ``script`` syntax:
        - macOS: ``script -q typescript.log btb.sh <spec>``
        - Linux: ``script -q -c "btb.sh <spec>" typescript.log``

        Implements timeout with SIGTERM → SIGKILL escalation.

        Returns:
            The btb exit code, or -1 on timeout.
        """
        repo_dir = self._repo_dir(job)
        typescript_path = self._typescript_path(job)
        btb_script = os.path.join(self._btb_path, "btb.sh")

        # Build the script command based on platform
        if platform.system() == "Darwin":
            # macOS: script -q <logfile> <command> <args>
            shell_cmd = f"script -q {typescript_path} {btb_script} {job.spec_name}"
        else:
            # Linux: script -q -c "<command> <args>" <logfile>
            shell_cmd = f'script -q -c "{btb_script} {job.spec_name}" {typescript_path}'

        # Use create_subprocess_shell since script needs shell-like invocation
        # Start in a new process group so we can kill the whole tree
        self._process = await asyncio.create_subprocess_shell(
            shell_cmd,
            cwd=str(repo_dir),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            preexec_fn=os.setsid,
        )

        try:
            _stdout, _stderr = await asyncio.wait_for(
                self._process.communicate(),
                timeout=self._job_timeout,
            )
            return self._process.returncode or 0
        except asyncio.TimeoutError:
            logger.warning(
                "Job %s timed out after %d seconds — sending SIGTERM",
                job.id,
                self._job_timeout,
            )
            # SIGTERM → wait grace period → SIGKILL
            try:
                pgid = os.getpgid(self._process.pid)
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, OSError):
                pass

            try:
                await asyncio.wait_for(
                    self._process.wait(),
                    timeout=KILL_GRACE_PERIOD,
                )
            except asyncio.TimeoutError:
                logger.warning(
                    "Job %s did not exit after SIGTERM — sending SIGKILL",
                    job.id,
                )
                try:
                    pgid = os.getpgid(self._process.pid)
                    os.killpg(pgid, signal.SIGKILL)
                except (ProcessLookupError, OSError):
                    pass
                await self._process.wait()

            return -1

    async def _push_results(self, job: Job, status: str = "") -> PushResult:
        """Push btb results back to the results branch.

        Args:
            job: The job whose results are being pushed.
            status: The job's terminal status (completed/failed/timeout).
        """
        repo_dir = self._repo_dir(job)
        return await self._pusher.push_results(
            job,
            str(repo_dir),
            status=status,
            job_id=job.id,
        )

    def _preserve_logs(self, job: Job) -> bool:
        """Copy ``.ralph-logs/`` to the persistent logs directory.

        Returns:
            True if logs were preserved successfully, False otherwise.
        """
        repo_dir = self._repo_dir(job)
        ralph_logs = repo_dir / ".ralph-logs"
        dest = self._logs_dir / job.id

        if not ralph_logs.exists():
            logger.info("No .ralph-logs/ found for job %s", job.id)
            return True

        try:
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copytree(str(ralph_logs), str(dest), dirs_exist_ok=True)
            logger.info("Preserved logs for job %s to %s", job.id, dest)
            return True
        except Exception as exc:
            logger.error(
                "Failed to preserve logs for job %s: %s", job.id, exc
            )
            return False

    def _cleanup_workdir(self, job: Job) -> bool:
        """Delete the entire job working directory.

        Returns:
            True if cleanup succeeded, False otherwise.
        """
        job_dir = self._job_dir(job)
        if not job_dir.exists():
            return True

        try:
            shutil.rmtree(str(job_dir))
            logger.info("Cleaned up working directory for job %s", job.id)
            return True
        except Exception as exc:
            logger.error(
                "Failed to clean up working directory for job %s: %s",
                job.id,
                exc,
            )
            return False

    # ------------------------------------------------------------------
    # Main entry point
    # ------------------------------------------------------------------

    async def run(self, job: Job) -> int:
        """Execute a full job lifecycle.

        Steps:
            1. Verify/clean stale working directory
            2. Clone repo and checkout commit
            3. Handle retry continuation (if ``retry_of`` is set)
            4. Run ``setup.sh``
            5. Run ``btb.sh`` inside ``script``
            6. Push results to ``btb-results/{branch}``
            7. Preserve ``.ralph-logs/``
            8. Delete working directory
            9. Move job to completed

        Args:
            job: The Job to execute.

        Returns:
            The btb exit code (0 for success, -1 for timeout, >0 for failure).
        """
        if self._running:
            raise RuntimeError("Another job is already running")

        self._running = True
        self._current_job = job
        self._process = None

        exit_code = -1
        status = "failed"
        error: Optional[str] = None
        push_result: Optional[PushResult] = None
        cleanup_success = False

        try:
            # Step 1: Clean stale working directory
            await self._clean_stale_workdir(job)

            # Step 2: Clone repo and checkout commit
            clone_rc = await self._clone_repo(job)
            if clone_rc != 0:
                exit_code = clone_rc
                error = "Git clone or checkout failed"
                status = "failed"
                # Still attempt push-back and cleanup even on clone failure
                # but only if the repo dir exists
                if self._repo_dir(job).exists():
                    push_result = await self._push_results(job, status="failed")
                self._preserve_logs(job)
                cleanup_success = self._cleanup_workdir(job)
                self._complete_job(
                    job, status, exit_code, error, push_result, cleanup_success
                )
                return exit_code

            # Step 3: Handle retry continuation
            await self._handle_retry_continuation(job)

            # Step 4: Run setup.sh
            setup_rc = await self._run_setup(job)
            if setup_rc != 0:
                exit_code = setup_rc
                error = "setup.sh failed"
                status = "failed"
                push_result = await self._push_results(job, status="failed")
                self._preserve_logs(job)
                cleanup_success = self._cleanup_workdir(job)
                self._complete_job(
                    job, status, exit_code, error, push_result, cleanup_success
                )
                return exit_code

            # Step 5: Run btb inside script
            exit_code = await self._run_btb(job)

            if exit_code == -1:
                status = "timeout"
                error = f"Job timed out after {self._job_timeout} seconds"
            elif exit_code == 0:
                status = "completed"
            else:
                status = "failed"
                error = f"btb exited with code {exit_code}"

        except Exception as exc:
            logger.error("Unexpected error running job %s: %s", job.id, exc)
            exit_code = -1
            status = "failed"
            error = f"Unexpected error: {exc}"

        # Steps 6-9: Post-execution lifecycle (always runs)
        try:
            # Step 6: Push results
            if self._repo_dir(job).exists():
                push_result = await self._push_results(job, status=status)
            else:
                push_result = PushResult(
                    success=False,
                    branch=f"btb-results/{job.branch}",
                    error="Repo directory does not exist",
                )
        except Exception as exc:
            logger.error("Push failed for job %s: %s", job.id, exc)
            push_result = PushResult(
                success=False,
                branch=f"btb-results/{job.branch}",
                error=str(exc),
            )

        # Step 7: Preserve logs
        self._preserve_logs(job)

        # Step 8: Cleanup working directory
        cleanup_success = self._cleanup_workdir(job)

        # Step 9: Complete the job
        self._complete_job(
            job, status, exit_code, error, push_result, cleanup_success
        )

        return exit_code

    def _complete_job(
        self,
        job: Job,
        status: str,
        exit_code: int,
        error: Optional[str],
        push_result: Optional[PushResult],
        cleanup_success: bool,
    ) -> None:
        """Move the job to completed state and reset executor state."""
        try:
            self._queue.complete(
                job_id=job.id,
                status=status,
                exit_code=exit_code,
                error=error,
                results_branch=push_result.branch if push_result else None,
                push_success=push_result.success if push_result else None,
                push_error=push_result.error if push_result else None,
                cleanup_success=cleanup_success,
            )
        except Exception as exc:
            logger.error(
                "Failed to complete job %s in queue: %s", job.id, exc
            )
        finally:
            self._running = False
            self._current_job = None
            self._process = None
