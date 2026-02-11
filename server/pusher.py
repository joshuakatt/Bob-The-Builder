"""Result pusher for the BTB Service.

Pushes btb results back to the original repository on a dedicated
``btb-results/{branch}`` branch after job completion.  Force-push is
used because each btb run produces a fresh result that supersedes any
previous results on the same branch.

Before pushing, the ``.btb`` file in the working directory is updated
with ``status``, ``last_run``, and ``job_id`` keys so the results branch
serves as a receipt of the last run.

Push failure never raises — the caller always proceeds to cleanup.
"""

import asyncio
import glob
import logging
import os
from datetime import datetime, timezone
from typing import Optional

from server.models import Job, PushResult

logger = logging.getLogger(__name__)


def update_btb_file(
    repo_dir: str,
    status: str,
    job_id: str,
    timestamp: Optional[str] = None,
) -> bool:
    """Update the .btb file in the repo with job status metadata.

    Finds the first ``*.btb`` file at the repo root, parses it as
    key-value pairs, and updates/adds ``status``, ``last_run``, and
    ``job_id`` keys while preserving existing keys (like ``spec``) and
    comments.

    Args:
        repo_dir: Path to the cloned repository working directory.
        status: Job terminal status (completed/failed/timeout).
        job_id: The job's unique identifier.
        timestamp: ISO 8601 timestamp for ``last_run``.  Defaults to
            the current UTC time if not provided.

    Returns:
        True if the file was updated successfully, False otherwise.
    """
    if timestamp is None:
        timestamp = datetime.now(timezone.utc).isoformat()

    # Find the .btb file
    btb_files = glob.glob(os.path.join(repo_dir, "*.btb"))
    if not btb_files:
        logger.warning("No .btb file found in %s — skipping status update", repo_dir)
        return False

    btb_path = btb_files[0]

    try:
        content = open(btb_path, "r").read()
    except OSError as e:
        logger.warning("Failed to read .btb file %s: %s", btb_path, e)
        return False

    # Parse existing lines, tracking which keys we've seen
    updates = {"status": status, "last_run": timestamp, "job_id": job_id}
    seen_keys: set[str] = set()
    new_lines: list[str] = []

    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        if "=" not in stripped:
            new_lines.append(line)
            continue

        key, _, _ = stripped.partition("=")
        key = key.strip()

        if key in updates:
            # Replace with updated value
            new_lines.append(f"{key}={updates[key]}")
            seen_keys.add(key)
        else:
            # Preserve existing key
            new_lines.append(line)

    # Append any keys that weren't already in the file
    for key, value in updates.items():
        if key not in seen_keys:
            new_lines.append(f"{key}={value}")

    try:
        with open(btb_path, "w") as f:
            f.write("\n".join(new_lines) + "\n")
        logger.info("Updated .btb file with status=%s for job %s", status, job_id)
        return True
    except OSError as e:
        logger.warning("Failed to write .btb file %s: %s", btb_path, e)
        return False


class ResultPusher:
    """Pushes btb results back to the original repository.

    After a job completes (regardless of success/failure/timeout), the
    working directory contents are force-pushed to a dedicated results
    branch so the developer can review btb's changes without SSH access.

    The push uses the clone's existing remote and credentials (inherited
    from the clone operation).  Push happens before cleanup so the
    working directory still exists.
    """

    @staticmethod
    def compute_results_branch(branch: str) -> str:
        """Compute the results branch name for a given source branch.

        Args:
            branch: The original branch name from the job.

        Returns:
            The results branch name in the form ``btb-results/{branch}``.
        """
        return f"btb-results/{branch}"

    async def _run_git(
        self, args: list[str], cwd: str
    ) -> tuple[int, str, str]:
        """Run a git command as an async subprocess.

        Args:
            args: Git sub-command and arguments (e.g. ``["add", "-A"]``).
            cwd: Working directory for the git command.

        Returns:
            A tuple of (return_code, stdout, stderr).
        """
        proc = await asyncio.create_subprocess_exec(
            "git", *args,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_bytes, stderr_bytes = await proc.communicate()
        stdout = stdout_bytes.decode("utf-8", errors="replace").strip()
        stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
        return proc.returncode, stdout, stderr

    async def push_results(
        self,
        job: Job,
        repo_dir: str,
        status: str = "",
        job_id: str = "",
        timestamp: Optional[str] = None,
    ) -> PushResult:
        """Push btb results to the results branch in the original repo.

        Steps:
            1. Compute results branch name: ``btb-results/{job.branch}``
            2. Update the ``.btb`` file with job status metadata
            3. Stage all changes with ``git add -A``
            4. Check if there are staged changes with ``git diff --cached --quiet``
            5. If changes exist, commit them
            6. Force-push to the results branch

        This method never raises exceptions — it always returns a
        :class:`PushResult` so the caller can proceed to cleanup.

        Args:
            job: The job whose results are being pushed.
            repo_dir: Path to the cloned repository working directory.
            status: Job terminal status (completed/failed/timeout).
            job_id: The job's unique identifier.
            timestamp: ISO 8601 timestamp for the ``last_run`` field.

        Returns:
            A :class:`PushResult` indicating success or failure.
        """
        results_branch = self.compute_results_branch(job.branch)

        try:
            # Step 0: Update .btb file with job status metadata
            if status and job_id:
                update_btb_file(repo_dir, status, job_id, timestamp)

            # Step 1: Stage all changes
            rc, _stdout, stderr = await self._run_git(["add", "-A"], cwd=repo_dir)
            if rc != 0:
                error_msg = f"git add -A failed (rc={rc}): {stderr}"
                logger.error("Push failed for job %s: %s", job.id, error_msg)
                return PushResult(success=False, branch=results_branch, error=error_msg)

            # Step 2: Check if there are staged changes
            rc, _stdout, _stderr = await self._run_git(
                ["diff", "--cached", "--quiet"], cwd=repo_dir
            )
            # rc == 0 means no changes; rc == 1 means there are changes
            if rc == 0:
                logger.info(
                    "No changes to commit for job %s, pushing current HEAD",
                    job.id,
                )
            else:
                # Step 3: Commit the changes
                commit_msg = f"btb results for {job.spec_name} [job: {job.id}]"
                rc, _stdout, stderr = await self._run_git(
                    ["commit", "-m", commit_msg], cwd=repo_dir
                )
                if rc != 0:
                    error_msg = f"git commit failed (rc={rc}): {stderr}"
                    logger.error("Push failed for job %s: %s", job.id, error_msg)
                    return PushResult(
                        success=False, branch=results_branch, error=error_msg
                    )
                logger.info("Committed btb results for job %s", job.id)

            # Step 4: Force-push to the results branch
            rc, _stdout, stderr = await self._run_git(
                [
                    "push", "--force", "origin",
                    f"HEAD:refs/heads/{results_branch}",
                ],
                cwd=repo_dir,
            )
            if rc != 0:
                error_msg = f"git push failed (rc={rc}): {stderr}"
                logger.error("Push failed for job %s: %s", job.id, error_msg)
                return PushResult(
                    success=False, branch=results_branch, error=error_msg
                )

            logger.info(
                "Successfully pushed results for job %s to %s",
                job.id,
                results_branch,
            )
            return PushResult(success=True, branch=results_branch, error=None)

        except Exception as exc:
            # Catch-all: push failure must never raise
            error_msg = f"Unexpected error during push: {exc}"
            logger.error("Push failed for job %s: %s", job.id, error_msg)
            return PushResult(
                success=False, branch=results_branch, error=error_msg
            )
