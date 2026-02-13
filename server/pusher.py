"""Result pusher for the BTB Service.

Pushes btb results back to the original repository in two stages:

1. **Results branch** (``btb-results/{branch}``): Force-pushed as a
   receipt/debug artifact.  Always happens.

2. **Source branch** (``{branch}``): Squash-rebased on top of the latest
   ``origin/{branch}`` so multiple jobs compound their work.  Uses the
   resolver agent for rebase conflicts and the verifier agent for a
   post-rebase build check.  Only attempted for successful jobs.

Before pushing, the ``.btb`` file in the working directory is updated
with ``status``, ``last_run``, and ``job_id`` keys.

Push failure never raises — the caller always proceeds to cleanup.
"""

import asyncio
import glob
import logging
import os
import shutil
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

    # Find the .btb file (check both hidden and non-hidden patterns)
    btb_files = glob.glob(os.path.join(repo_dir, "*.btb"))
    # Also check for hidden .btb file (glob doesn't match dotfiles with *)
    hidden_btb = os.path.join(repo_dir, ".btb")
    if os.path.isfile(hidden_btb):
        btb_files.insert(0, hidden_btb)
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

    After a job completes, results are pushed in two stages:

    1. Force-push to ``btb-results/{branch}`` (always, as a receipt).
    2. Squash-rebase onto ``origin/{branch}`` and push (only for
       successful jobs).  Uses the resolver agent for conflicts and
       the verifier agent for a post-rebase build check.

    The push uses the clone's existing remote and credentials (inherited
    from the clone operation).  Push happens before cleanup so the
    working directory still exists.

    Args:
        btb_path: Path to the btb installation directory (for kiro-cli).
            If None, source-branch push-back is disabled.
    """

    def __init__(self, btb_path: Optional[str] = None) -> None:
        self._btb_path = btb_path

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

    # ------------------------------------------------------------------
    # Source-branch squash-rebase-push
    # ------------------------------------------------------------------

    async def _run_agent(
        self, agent: str, prompt: str, cwd: str, timeout: int = 600,
    ) -> tuple[int, str]:
        """Run a kiro-cli agent and return (exit_code, output).

        Args:
            agent: Agent name (e.g. "resolver", "verifier").
            prompt: The prompt to send to the agent.
            cwd: Working directory for the agent.
            timeout: Max seconds to wait.

        Returns:
            Tuple of (return_code, combined stdout+stderr).
        """
        if not self._btb_path:
            return -1, "btb_path not configured"

        # Ensure agent files are available in the working directory
        agent_src = os.path.join(self._btb_path, ".kiro", "agents")
        agent_dst = os.path.join(cwd, ".kiro", "agents")
        if os.path.isdir(agent_src):
            os.makedirs(agent_dst, exist_ok=True)
            for fname in os.listdir(agent_src):
                src_file = os.path.join(agent_src, fname)
                dst_file = os.path.join(agent_dst, fname)
                if os.path.isfile(src_file) and not os.path.exists(dst_file):
                    shutil.copy2(src_file, dst_file)

        proc = await asyncio.create_subprocess_exec(
            "kiro-cli", "chat", "--no-interactive",
            "--agent", agent,
            "--trust-all-tools",
            prompt,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            stdout_bytes, _ = await asyncio.wait_for(
                proc.communicate(), timeout=timeout,
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return -1, f"Agent {agent} timed out after {timeout}s"

        output = stdout_bytes.decode("utf-8", errors="replace").strip()
        return proc.returncode or 0, output

    async def push_to_source_branch(
        self,
        job: Job,
        repo_dir: str,
    ) -> PushResult:
        """Squash-rebase btb work onto the source branch and push.

        This compounds btb's work with any changes pushed to the source
        branch while btb was running (by other developers or other jobs).

        Steps:
            1. Fetch latest ``origin/{branch}``
            2. Create a temporary branch from the current HEAD
            3. Soft-reset to squash all btb commits into one
            4. Rebase the squashed commit onto ``origin/{branch}``
            5. If rebase conflicts, invoke the resolver agent
            6. Run the verifier agent to confirm the build passes
            7. Push to ``origin/{branch}``

        If any step fails, the source branch is left untouched and the
        error is reported.  The results branch (pushed earlier) still
        serves as the receipt.

        Args:
            job: The job whose results are being pushed.
            repo_dir: Path to the cloned repository working directory.

        Returns:
            A PushResult indicating success or failure.
        """
        source_branch = job.branch

        try:
            # Step 1: Fetch latest origin/{branch}
            logger.info(
                "Fetching latest origin/%s for squash-rebase (job %s)",
                source_branch, job.id,
            )
            rc, _out, err = await self._run_git(
                ["fetch", "origin", source_branch], cwd=repo_dir,
            )
            if rc != 0:
                error_msg = f"git fetch origin {source_branch} failed: {err}"
                logger.error("Source push failed for job %s: %s", job.id, error_msg)
                return PushResult(success=False, branch=source_branch, error=error_msg)

            # Step 2: Record the merge base (where btb branched from)
            rc, merge_base, err = await self._run_git(
                ["merge-base", "HEAD", f"origin/{source_branch}"],
                cwd=repo_dir,
            )
            if rc != 0:
                # Fallback: use the commit btb was cloned at
                merge_base = job.commit_sha
                logger.warning(
                    "merge-base failed for job %s, using clone commit %s",
                    job.id, merge_base,
                )

            # Step 3: Create a squash branch from current HEAD
            squash_branch = f"btb-squash-{job.id[:8]}"
            rc, _out, err = await self._run_git(
                ["checkout", "-b", squash_branch], cwd=repo_dir,
            )
            if rc != 0:
                error_msg = f"Failed to create squash branch: {err}"
                logger.error("Source push failed for job %s: %s", job.id, error_msg)
                return PushResult(success=False, branch=source_branch, error=error_msg)

            # Step 4: Soft-reset to merge base to squash all btb commits
            rc, _out, err = await self._run_git(
                ["reset", "--soft", merge_base], cwd=repo_dir,
            )
            if rc != 0:
                error_msg = f"git reset --soft failed: {err}"
                logger.error("Source push failed for job %s: %s", job.id, error_msg)
                return PushResult(success=False, branch=source_branch, error=error_msg)

            # Step 5: Commit the squashed changes
            commit_msg = f"btb: {job.spec_name} [job: {job.id[:8]}]"
            rc, _out, err = await self._run_git(
                ["commit", "-m", commit_msg, "--allow-empty"], cwd=repo_dir,
            )
            if rc != 0:
                error_msg = f"Squash commit failed: {err}"
                logger.error("Source push failed for job %s: %s", job.id, error_msg)
                return PushResult(success=False, branch=source_branch, error=error_msg)

            logger.info("Squashed btb work into single commit for job %s", job.id)

            # Step 6: Rebase onto origin/{branch}
            rc, _out, err = await self._run_git(
                ["rebase", f"origin/{source_branch}"], cwd=repo_dir,
            )
            if rc != 0:
                logger.warning(
                    "Rebase conflict for job %s — invoking resolver agent", job.id,
                )
                resolved = await self._resolve_rebase_conflicts(job, repo_dir)
                if not resolved:
                    # Abort the rebase and bail
                    await self._run_git(["rebase", "--abort"], cwd=repo_dir)
                    error_msg = "Rebase conflicts could not be resolved"
                    logger.error("Source push failed for job %s: %s", job.id, error_msg)
                    return PushResult(
                        success=False, branch=source_branch, error=error_msg,
                    )

            logger.info("Rebase successful for job %s", job.id)

            # Step 7: Run verifier agent to confirm build passes
            verified = await self._verify_build(job, repo_dir)
            if not verified:
                error_msg = "Post-rebase build verification failed"
                logger.error("Source push failed for job %s: %s", job.id, error_msg)
                return PushResult(
                    success=False, branch=source_branch, error=error_msg,
                )

            logger.info("Build verified for job %s", job.id)

            # Step 8: Push to origin/{branch}
            rc, _out, err = await self._run_git(
                ["push", "origin", f"HEAD:refs/heads/{source_branch}"],
                cwd=repo_dir,
            )
            if rc != 0:
                # Could be a race — someone pushed between our rebase and push.
                # One retry with a fresh rebase.
                logger.warning(
                    "Push to %s failed for job %s, retrying with fresh rebase: %s",
                    source_branch, job.id, err,
                )
                retry_result = await self._retry_push(job, repo_dir, source_branch)
                return retry_result

            logger.info(
                "Successfully pushed squashed results for job %s to %s",
                job.id, source_branch,
            )
            return PushResult(success=True, branch=source_branch, error=None)

        except Exception as exc:
            error_msg = f"Unexpected error during source push: {exc}"
            logger.error("Source push failed for job %s: %s", job.id, error_msg)
            return PushResult(
                success=False, branch=source_branch, error=error_msg,
            )

    async def _resolve_rebase_conflicts(
        self, job: Job, repo_dir: str,
    ) -> bool:
        """Invoke the resolver agent to handle rebase conflicts.

        Returns True if conflicts were resolved, False otherwise.
        """
        # Get list of conflicted files
        rc, conflicted, _ = await self._run_git(
            ["diff", "--name-only", "--diff-filter=U"], cwd=repo_dir,
        )
        if not conflicted.strip():
            # No conflicts — maybe the rebase failed for another reason
            return False

        prompt = f"""REBASE CONFLICT RESOLUTION NEEDED

CONTEXT:
- Job: {job.id}
- Spec: {job.spec_name}
- Source branch: {job.branch}
- btb's work is being rebased onto the latest origin/{job.branch}

CONFLICTED FILES:
{conflicted}

This is a REBASE conflict, not a merge conflict. The conflict markers
are the same (<<<<<<< / ======= / >>>>>>>) but the resolution flow is:

1. Read each conflicted file to understand both sides
2. Read the spec files if available for context on what btb was doing
3. Resolve each conflict, preserving ALL meaningful work from both sides
4. Run 'git add <file>' on each resolved file
5. Run 'git rebase --continue'

IMPORTANT: This is a squash-rebase of btb's work onto the latest source
branch. The "ours" side is the latest source branch (other developers'
work). The "theirs" side is btb's squashed work. Both must be preserved.

Output 'CONFLICTS_RESOLVED' when done."""

        rc, output = await self._run_agent(
            "resolver", prompt, repo_dir, timeout=300,
        )

        if "CONFLICTS_RESOLVED" in output:
            logger.info("Resolver agent resolved rebase conflicts for job %s", job.id)
            return True

        logger.error(
            "Resolver agent failed to resolve conflicts for job %s: rc=%d",
            job.id, rc,
        )
        return False

    async def _verify_build(self, job: Job, repo_dir: str) -> bool:
        """Invoke the verifier agent to confirm the build passes.

        Returns True if the build is verified, False otherwise.
        """
        prompt = f"""Verify that this repository builds and tests pass.

This is a post-rebase verification for btb job {job.id}.
The spec was: {job.spec_name}
The branch is: {job.branch}

Inspect the repository, determine the correct build/test commands,
and run them. Report BUILD_VERIFIED, BUILD_FAILED, or BUILD_UNKNOWN."""

        rc, output = await self._run_agent(
            "verifier", prompt, repo_dir, timeout=600,
        )

        if "BUILD_VERIFIED" in output:
            logger.info("Build verified for job %s", job.id)
            return True

        if "BUILD_UNKNOWN" in output:
            # Can't determine build — let it through with a warning
            logger.warning(
                "Verifier could not determine build commands for job %s — "
                "allowing push",
                job.id,
            )
            return True

        logger.error("Build verification failed for job %s: %s", job.id, output[-500:])
        return False

    async def _retry_push(
        self, job: Job, repo_dir: str, source_branch: str,
    ) -> PushResult:
        """Retry the push after a fresh fetch + rebase.

        Called when the initial push fails (race condition with another
        push to the same branch).
        """
        try:
            # Fresh fetch
            rc, _out, err = await self._run_git(
                ["fetch", "origin", source_branch], cwd=repo_dir,
            )
            if rc != 0:
                return PushResult(
                    success=False, branch=source_branch,
                    error=f"Retry fetch failed: {err}",
                )

            # Rebase again
            rc, _out, err = await self._run_git(
                ["rebase", f"origin/{source_branch}"], cwd=repo_dir,
            )
            if rc != 0:
                resolved = await self._resolve_rebase_conflicts(job, repo_dir)
                if not resolved:
                    await self._run_git(["rebase", "--abort"], cwd=repo_dir)
                    return PushResult(
                        success=False, branch=source_branch,
                        error="Retry rebase conflicts unresolvable",
                    )

            # Push again
            rc, _out, err = await self._run_git(
                ["push", "origin", f"HEAD:refs/heads/{source_branch}"],
                cwd=repo_dir,
            )
            if rc != 0:
                return PushResult(
                    success=False, branch=source_branch,
                    error=f"Retry push failed: {err}",
                )

            logger.info(
                "Retry push succeeded for job %s to %s", job.id, source_branch,
            )
            return PushResult(success=True, branch=source_branch, error=None)

        except Exception as exc:
            return PushResult(
                success=False, branch=source_branch,
                error=f"Retry failed: {exc}",
            )
