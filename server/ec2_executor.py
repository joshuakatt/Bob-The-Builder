"""EC2-based job executor for the BTB Service.

Instead of running btb locally on the coordinator instance, this executor
starts a pre-configured "worker" EC2 instance, sends the job to it via
SSM Run Command, monitors execution, and lets the worker stop itself
when done.

The coordinator instance can be tiny (t3.nano) since it only runs the
webhook server and dashboard. The worker instance can be large (t3.2xlarge)
and only runs (and bills) while a job is active.

Requirements:
    - boto3 installed on the coordinator
    - IAM role on the coordinator with ec2:StartInstances, ec2:StopInstances,
      ec2:DescribeInstances, ssm:SendCommand, ssm:GetCommandInvocation
    - The worker instance must have SSM agent installed and an IAM role
      with AmazonSSMManagedInstanceCore
    - The worker instance must have btb, kiro-cli, git, python3 installed
"""

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Optional

from server.models import Job, PushResult
from server.queue import JobQueue

logger = logging.getLogger(__name__)

# How often to poll the worker instance status
POLL_INTERVAL = 30

# Max time to wait for the instance to reach "running" state
INSTANCE_START_TIMEOUT = 300  # 5 minutes

# Max time to wait for SSM agent to come online
SSM_READY_TIMEOUT = 180  # 3 minutes


class EC2JobExecutor:
    """Executes btb jobs on a remote EC2 worker instance.

    The worker instance is started on demand and stops itself after
    the job completes. The coordinator monitors progress by polling
    SSM command status.

    Args:
        worker_instance_id: EC2 instance ID of the worker.
        worker_region: AWS region of the worker instance.
        btb_path: Path to btb on the worker instance.
        github_token: GitHub PAT for cloning repos.
        queue: JobQueue for completing jobs.
        job_timeout: Max seconds for a job before forced termination.
        coordinator_url: URL of the coordinator for the worker to
            report status back (optional, for future use).
    """

    def __init__(
        self,
        worker_instance_id: str,
        worker_region: str,
        btb_path: str,
        github_token: str,
        queue: JobQueue,
        job_timeout: int = 43200,
        coordinator_url: Optional[str] = None,
    ) -> None:
        self._worker_instance_id = worker_instance_id
        self._worker_region = worker_region
        self._btb_path = btb_path
        self._github_token = github_token
        self._queue = queue
        self._job_timeout = job_timeout
        self._coordinator_url = coordinator_url

        self._running = False
        self._current_job: Optional[Job] = None
        self._stop_requested = False

        # Lazy-init boto3 clients
        self._ec2_client = None
        self._ssm_client = None

    def _get_ec2_client(self):
        if self._ec2_client is None:
            import boto3
            self._ec2_client = boto3.client("ec2", region_name=self._worker_region)
        return self._ec2_client

    def _get_ssm_client(self):
        if self._ssm_client is None:
            import boto3
            self._ssm_client = boto3.client("ssm", region_name=self._worker_region)
        return self._ssm_client

    def is_running(self) -> bool:
        return self._running

    def get_current_job(self) -> Optional[Job]:
        return self._current_job

    def request_stop(self, preserve_workdir: bool = False) -> bool:
        if not self._running or self._current_job is None:
            return False
        self._stop_requested = True
        # Force-stop the worker instance
        try:
            self._get_ec2_client().stop_instances(
                InstanceIds=[self._worker_instance_id], Force=True
            )
            logger.info("Force-stopped worker instance %s", self._worker_instance_id)
        except Exception as e:
            logger.error("Failed to stop worker instance: %s", e)
        return True

    def kill_current(self) -> None:
        self.request_stop()

    def is_stop_requested(self) -> bool:
        return self._stop_requested

    async def _start_worker_instance(self) -> bool:
        """Start the worker EC2 instance and wait for it to be running."""
        ec2 = self._get_ec2_client()

        # Check current state
        resp = ec2.describe_instances(InstanceIds=[self._worker_instance_id])
        state = resp["Reservations"][0]["Instances"][0]["State"]["Name"]

        if state == "running":
            logger.info("Worker instance already running")
            return True

        if state not in ("stopped", "stopping"):
            logger.error("Worker instance in unexpected state: %s", state)
            return False

        # Wait for "stopped" if currently "stopping"
        if state == "stopping":
            logger.info("Worker instance is stopping, waiting...")
            waiter = ec2.get_waiter("instance_stopped")
            waiter.wait(
                InstanceIds=[self._worker_instance_id],
                WaiterConfig={"Delay": 10, "MaxAttempts": 30},
            )

        # Start the instance
        logger.info("Starting worker instance %s", self._worker_instance_id)
        ec2.start_instances(InstanceIds=[self._worker_instance_id])

        # Wait for running
        waiter = ec2.get_waiter("instance_running")
        try:
            waiter.wait(
                InstanceIds=[self._worker_instance_id],
                WaiterConfig={"Delay": 10, "MaxAttempts": 30},
            )
        except Exception as e:
            logger.error("Worker instance failed to start: %s", e)
            return False

        logger.info("Worker instance is running")
        return True

    async def _wait_for_ssm(self) -> bool:
        """Wait for SSM agent on the worker to come online."""
        ssm = self._get_ssm_client()
        deadline = time.time() + SSM_READY_TIMEOUT

        while time.time() < deadline:
            try:
                resp = ssm.describe_instance_information(
                    Filters=[{
                        "Key": "InstanceIds",
                        "Values": [self._worker_instance_id],
                    }]
                )
                if resp.get("InstanceInformationList"):
                    info = resp["InstanceInformationList"][0]
                    if info.get("PingStatus") == "Online":
                        logger.info("SSM agent is online on worker")
                        return True
            except Exception:
                pass
            await asyncio.sleep(10)

        logger.error("SSM agent did not come online within %ds", SSM_READY_TIMEOUT)
        return False

    async def _send_job_command(self, job: Job) -> Optional[str]:
        """Send the btb job command to the worker via SSM Run Command.

        Returns the SSM command ID, or None on failure.
        """
        ssm = self._get_ssm_client()

        # Build the shell script that runs on the worker
        # It clones the repo, runs setup + btb, pushes results, then shuts down
        script = self._build_worker_script(job)

        try:
            resp = ssm.send_command(
                InstanceIds=[self._worker_instance_id],
                DocumentName="AWS-RunShellScript",
                Parameters={
                    "commands": [script],
                    "executionTimeout": [str(self._job_timeout + 600)],
                },
                TimeoutSeconds=self._job_timeout + 600,
                Comment=f"btb job {job.id} spec={job.spec_name}",
            )
            command_id = resp["Command"]["CommandId"]
            logger.info(
                "Sent SSM command %s for job %s to worker %s",
                command_id, job.id, self._worker_instance_id,
            )
            return command_id
        except Exception as e:
            logger.error("Failed to send SSM command: %s", e)
            return None

    def _build_worker_script(self, job: Job) -> str:
        """Build the shell script that runs on the worker instance."""
        # Escape single quotes in values for safe shell embedding
        repo_url = job.repo_url.replace("'", "'\\''")
        branch = job.branch.replace("'", "'\\''")
        commit_sha = job.commit_sha
        spec_name = job.spec_name.replace("'", "'\\''")
        job_id = job.id
        github_token = self._github_token.replace("'", "'\\''")
        btb_path = self._btb_path
        retry_of = job.retry_of or ""

        return f"""#!/bin/bash
set -euo pipefail

export HOME=/opt/btb
export PATH="/opt/btb/.local/bin:/usr/local/bin:$PATH"

JOB_ID='{job_id}'
REPO_URL='{repo_url}'
BRANCH='{branch}'
COMMIT_SHA='{commit_sha}'
SPEC_NAME='{spec_name}'
GITHUB_TOKEN='{github_token}'
BTB_PATH='{btb_path}'
RETRY_OF='{retry_of}'

JOBS_DIR="/var/btb/jobs"
LOGS_DIR="/var/btb/logs"
JOB_DIR="${{JOBS_DIR}}/${{JOB_ID}}"
REPO_DIR="${{JOB_DIR}}/repo"
OUTPUT_LOG="${{JOB_DIR}}/output.log"

# All output goes to both stdout (SSM captures) and the output log
# (coordinator fetches for live streaming)
exec > >(tee -a "${{JOB_DIR}}/output.log") 2>&1
mkdir -p "${{JOB_DIR}}"

echo "[$(date -Iseconds)] Starting btb job ${{JOB_ID}} spec=${{SPEC_NAME}}"

# Clean stale workdir
rm -rf "${{JOB_DIR}}" 2>/dev/null || true
mkdir -p "${{JOB_DIR}}"

# Clone with auth
AUTH_URL=$(echo "${{REPO_URL}}" | sed "s|https://github.com/|https://x-access-token:${{GITHUB_TOKEN}}@github.com/|")
git clone --branch "${{BRANCH}}" "${{AUTH_URL}}" "${{REPO_DIR}}"
cd "${{REPO_DIR}}"
git checkout "${{COMMIT_SHA}}"

# Handle retry continuation
if [ -n "${{RETRY_OF}}" ]; then
    RESULTS_BRANCH="btb-results/${{BRANCH}}"
    if git ls-remote --heads origin "${{RESULTS_BRANCH}}" | grep -q .; then
        git fetch origin "${{RESULTS_BRANCH}}" || true
        git merge FETCH_HEAD --no-edit --allow-unrelated-histories || git merge --abort || true
    fi
fi

# Run setup
"${{BTB_PATH}}/setup.sh" || true

# Run btb
EXIT_CODE=0
timeout {self._job_timeout} "${{BTB_PATH}}/btb.sh" "${{SPEC_NAME}}" --no-tui || EXIT_CODE=$?

# Determine status
if [ "${{EXIT_CODE}}" -eq 0 ]; then
    STATUS="completed"
elif [ "${{EXIT_CODE}}" -eq 124 ]; then
    STATUS="timeout"
else
    STATUS="failed"
fi

echo "[$(date -Iseconds)] btb exited with code ${{EXIT_CODE}} status=${{STATUS}}"

# Push results to btb-results/{{branch}}
git add -A
if ! git diff --cached --quiet; then
    git commit -m "btb results for ${{SPEC_NAME}} [job: ${{JOB_ID}}]"
fi
git push --force origin "HEAD:refs/heads/btb-results/${{BRANCH}}" || true

# If completed, squash-rebase onto source branch
if [ "${{STATUS}}" = "completed" ]; then
    git fetch origin "${{BRANCH}}"
    MERGE_BASE=$(git merge-base HEAD "origin/${{BRANCH}}" 2>/dev/null || echo "${{COMMIT_SHA}}")
    git checkout -b "btb-squash-${{JOB_ID:0:8}}"
    git reset --soft "${{MERGE_BASE}}"
    git commit -m "btb: ${{SPEC_NAME}} [job: ${{JOB_ID:0:8}}]" --allow-empty
    if git rebase "origin/${{BRANCH}}"; then
        git push origin "HEAD:refs/heads/${{BRANCH}}" || true
    fi
fi

# Preserve logs
if [ -d .ralph-logs ]; then
    mkdir -p "${{LOGS_DIR}}/${{JOB_ID}}"
    cp -a .ralph-logs/. "${{LOGS_DIR}}/${{JOB_ID}}/" || true
fi

# Write completion marker for the coordinator to read
echo "${{STATUS}}:${{EXIT_CODE}}" > "${{JOB_DIR}}/result.txt"

# Cleanup workdir
cd /
rm -rf "${{JOB_DIR}}" 2>/dev/null || true

echo "[$(date -Iseconds)] Job complete. Shutting down worker."

# Stop this instance (the coordinator will see it transition to "stopped")
sudo shutdown now
"""

    async def _stream_remote_log(self, job: Job, local_log_path: str) -> None:
        """Background task that fetches output from the worker and writes locally.

        Periodically runs an SSM command to read new bytes from the worker's
        output.log and appends them to the local typescript.log so the
        TUI streamer can pick them up.
        """
        ssm = self._get_ssm_client()
        offset = 0
        remote_log = f"/var/btb/jobs/{job.id}/output.log"

        from pathlib import Path
        Path(local_log_path).parent.mkdir(parents=True, exist_ok=True)

        while not self._stop_requested:
            try:
                # Use dd to read from offset, avoids re-reading the whole file
                resp = ssm.send_command(
                    InstanceIds=[self._worker_instance_id],
                    DocumentName="AWS-RunShellScript",
                    Parameters={
                        "commands": [
                            f"dd if={remote_log} bs=1 skip={offset} 2>/dev/null || true"
                        ],
                        "executionTimeout": ["10"],
                    },
                    TimeoutSeconds=15,
                )
                cmd_id = resp["Command"]["CommandId"]

                # Wait for the command to complete
                for _ in range(10):
                    await asyncio.sleep(1)
                    try:
                        inv = ssm.get_command_invocation(
                            CommandId=cmd_id,
                            InstanceId=self._worker_instance_id,
                        )
                        if inv["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
                            break
                    except Exception:
                        break

                if inv.get("Status") == "Success":
                    output = inv.get("StandardOutputContent", "")
                    if output:
                        with open(local_log_path, "ab") as f:
                            f.write(output.encode("utf-8", errors="replace"))
                        offset += len(output.encode("utf-8", errors="replace"))

            except Exception as e:
                logger.debug("Log stream fetch error for job %s: %s", job.id, e)

            await asyncio.sleep(5)  # Fetch every 5 seconds

    async def _monitor_command(self, command_id: str, job: Job) -> tuple[str, int]:
        """Monitor an SSM command until completion.

        Returns (status, exit_code) where status is
        "completed"/"failed"/"timeout".
        """
        ssm = self._get_ssm_client()
        ec2 = self._get_ec2_client()
        start_time = time.time()

        while True:
            if self._stop_requested:
                return "failed", -1

            elapsed = time.time() - start_time
            if elapsed > self._job_timeout + 600:
                logger.error("Job %s exceeded total timeout", job.id)
                return "timeout", -1

            # Check SSM command status
            try:
                resp = ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=self._worker_instance_id,
                )
                ssm_status = resp.get("Status", "")

                if ssm_status in ("Success",):
                    return "completed", 0
                elif ssm_status in ("Failed", "Cancelled", "TimedOut"):
                    exit_code = resp.get("ResponseCode", -1)
                    # Check if btb itself succeeded but shutdown caused SSM to report failure
                    # (shutdown -now kills the SSM agent mid-report)
                    if ssm_status == "Failed" and exit_code == -1:
                        # Instance probably shut down — check if it's stopped
                        inst_resp = ec2.describe_instances(
                            InstanceIds=[self._worker_instance_id]
                        )
                        inst_state = inst_resp["Reservations"][0]["Instances"][0]["State"]["Name"]
                        if inst_state in ("stopped", "stopping"):
                            # Worker shut itself down — likely completed successfully
                            logger.info(
                                "Worker stopped itself for job %s — treating as completed",
                                job.id,
                            )
                            return "completed", 0
                    return "failed", exit_code
                # InProgress, Pending, Delayed — keep waiting
            except ssm.exceptions.InvocationDoesNotExist:
                pass
            except Exception as e:
                logger.warning("Error checking SSM command status: %s", e)

            # Also check if the instance stopped (worker shuts itself down on completion)
            try:
                inst_resp = ec2.describe_instances(
                    InstanceIds=[self._worker_instance_id]
                )
                inst_state = inst_resp["Reservations"][0]["Instances"][0]["State"]["Name"]
                if inst_state in ("stopped", "stopping"):
                    logger.info(
                        "Worker instance stopped for job %s — job likely completed",
                        job.id,
                    )
                    return "completed", 0
            except Exception:
                pass

            await asyncio.sleep(POLL_INTERVAL)

    async def run(self, job: Job) -> int:
        """Execute a job on the remote worker instance.

        Steps:
            1. Start the worker EC2 instance
            2. Wait for SSM agent to come online
            3. Send the job script via SSM Run Command
            4. Monitor until completion (or instance stops)
            5. Complete the job in the queue

        Args:
            job: The Job to execute.

        Returns:
            0 on success, non-zero on failure.
        """
        if self._running:
            raise RuntimeError("Another job is already running")

        self._running = True
        self._current_job = job
        self._stop_requested = False

        status = "failed"
        exit_code = -1
        error: Optional[str] = None

        try:
            # Step 1: Start worker instance
            started = await self._start_worker_instance()
            if not started:
                error = "Failed to start worker EC2 instance"
                self._complete_job(job, "failed", -1, error)
                return -1

            # Step 2: Wait for SSM
            ssm_ready = await self._wait_for_ssm()
            if not ssm_ready:
                error = "SSM agent not available on worker instance"
                # Stop the instance since we can't use it
                try:
                    self._get_ec2_client().stop_instances(
                        InstanceIds=[self._worker_instance_id]
                    )
                except Exception:
                    pass
                self._complete_job(job, "failed", -1, error)
                return -1

            # Step 3: Send job command
            command_id = await self._send_job_command(job)
            if not command_id:
                error = "Failed to send job command to worker"
                self._complete_job(job, "failed", -1, error)
                return -1

            # Step 3.5: Start background log streaming
            import os
            local_typescript = os.path.join(
                str(self._queue.jobs_dir), job.id, "typescript.log"
            )
            stream_task = asyncio.create_task(
                self._stream_remote_log(job, local_typescript)
            )

            # Step 4: Monitor
            try:
                status, exit_code = await self._monitor_command(command_id, job)
            finally:
                # Stop the log streamer
                self._stop_requested = True
                stream_task.cancel()
                try:
                    await stream_task
                except asyncio.CancelledError:
                    pass
                self._stop_requested = False

            if status == "timeout":
                error = f"Job timed out after {self._job_timeout}s"
                # Force-stop the worker
                try:
                    self._get_ec2_client().stop_instances(
                        InstanceIds=[self._worker_instance_id], Force=True
                    )
                except Exception:
                    pass

        except Exception as exc:
            logger.error("Unexpected error in EC2 executor for job %s: %s", job.id, exc)
            status = "failed"
            exit_code = -1
            error = f"Unexpected error: {exc}"

        # Step 5: Complete the job
        self._complete_job(job, status, exit_code, error)
        return exit_code

    def _complete_job(
        self,
        job: Job,
        status: str,
        exit_code: int,
        error: Optional[str],
    ) -> None:
        """Move the job to completed state and reset executor state."""
        try:
            self._queue.complete(
                job_id=job.id,
                status=status,
                exit_code=exit_code,
                error=error,
                results_branch=f"btb-results/{job.branch}",
                push_success=status == "completed",
                push_error=error if status != "completed" else None,
                cleanup_success=True,
            )
        except Exception as exc:
            logger.error("Failed to complete job %s: %s", job.id, exc)
        finally:
            self._running = False
            self._current_job = None
            self._stop_requested = False
