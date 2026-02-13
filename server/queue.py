"""Disk-based FIFO job queue for the BTB Service.

Jobs are persisted as JSON files in a queue directory, named with a
timestamp prefix for natural FIFO ordering when sorted alphabetically.
A file-based lock prevents race conditions during dequeue operations.
Completed jobs are moved to a separate completed directory.
"""

import fcntl
import json
import logging
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from server.models import Job

logger = logging.getLogger(__name__)

# Default lock file path; can be overridden via constructor
DEFAULT_LOCK_FILE = "/var/btb/.queue-lock"


class JobQueue:
    """Disk-based FIFO job queue.

    Jobs are stored as JSON files named ``{timestamp}_{job_id}.json``
    in the queue directory.  The timestamp prefix ensures natural FIFO
    ordering when the directory listing is sorted alphabetically.

    A file-based lock (using ``fcntl.flock``) serialises dequeue
    operations so that two concurrent pollers cannot grab the same job.

    Args:
        queue_dir: Path to the directory holding pending/running job files.
        completed_dir: Path to the directory holding completed job files.
        jobs_dir: Path to the base directory for per-job working directories.
        lock_file: Path to the lock file used for dequeue atomicity.
    """

    def __init__(
        self,
        queue_dir: str,
        completed_dir: str,
        jobs_dir: str,
        lock_file: str = DEFAULT_LOCK_FILE,
    ) -> None:
        self.queue_dir = Path(queue_dir)
        self.completed_dir = Path(completed_dir)
        self.jobs_dir = Path(jobs_dir)
        self.lock_file = Path(lock_file)

        # Create directories if they don't exist
        self.queue_dir.mkdir(parents=True, exist_ok=True)
        self.completed_dir.mkdir(parents=True, exist_ok=True)
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)

    def _make_filename(self, job: Job) -> str:
        """Generate a queue filename for a job.

        Uses a high-resolution UTC timestamp prefix for natural FIFO
        ordering when sorted alphabetically.

        Returns:
            Filename string like ``20250115103000123456_a1b2c3d4.json``.
        """
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S%f")
        return f"{timestamp}_{job.id}.json"

    def _read_job_file(self, path: Path) -> Job:
        """Read and deserialise a Job from a JSON file on disk.

        Args:
            path: Path to the JSON file.

        Returns:
            The deserialised Job.
        """
        return Job.from_json(path.read_text())

    def _write_job_file(self, path: Path, job: Job) -> None:
        """Serialise and write a Job to a JSON file on disk.

        Args:
            path: Destination file path.
            job: The Job to write.
        """
        path.write_text(job.to_json())

    def _sorted_queue_files(self) -> list[Path]:
        """Return queue directory JSON files sorted by filename (FIFO order).

        Returns:
            List of Path objects sorted alphabetically by name.
        """
        if not self.queue_dir.exists():
            return []
        files = [f for f in self.queue_dir.iterdir() if f.suffix == ".json"]
        files.sort(key=lambda p: p.name)
        return files

    def _sorted_completed_files(self) -> list[Path]:
        """Return completed directory JSON files sorted by filename (most recent first).

        Returns:
            List of Path objects sorted reverse-alphabetically by name.
        """
        if not self.completed_dir.exists():
            return []
        files = [f for f in self.completed_dir.iterdir() if f.suffix == ".json"]
        files.sort(key=lambda p: p.name, reverse=True)
        return files

    def _find_job_file_in_queue(self, job_id: str) -> Optional[Path]:
        """Find a job file in the queue directory by job ID.

        Args:
            job_id: The job ID to search for.

        Returns:
            Path to the matching file, or None if not found.
        """
        for f in self._sorted_queue_files():
            if f.name.endswith(f"_{job_id}.json"):
                return f
        return None

    def _find_job_file_in_completed(self, job_id: str) -> Optional[Path]:
        """Find a job file in the completed directory by job ID.

        Args:
            job_id: The job ID to search for.

        Returns:
            Path to the matching file, or None if not found.
        """
        for f in self._sorted_completed_files():
            if f.name.endswith(f"_{job_id}.json"):
                return f
        return None

    def enqueue(self, job: Job) -> str:
        """Add a job to the queue.

        Writes the job as a JSON file in the queue directory with a
        timestamp-prefixed filename for FIFO ordering.

        Args:
            job: The Job to enqueue.

        Returns:
            The job ID.
        """
        filename = self._make_filename(job)
        filepath = self.queue_dir / filename
        self._write_job_file(filepath, job)
        logger.info("Enqueued job %s as %s", job.id, filename)
        return job.id

    def dequeue(self) -> Optional[Job]:
        """Dequeue the next pending job.

        Acquires a file-based lock, scans the queue directory for the
        first job with status ``"pending"``, updates it to ``"running"``
        with a ``started_at`` timestamp, writes it back, and returns it.

        Returns:
            The dequeued Job (now with status ``"running"``), or None if
            no pending jobs are available.
        """
        lock_fd = open(self.lock_file, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)

            for filepath in self._sorted_queue_files():
                try:
                    job = self._read_job_file(filepath)
                except Exception:
                    logger.warning("Failed to read job file %s, skipping", filepath)
                    continue

                if job.status == "pending":
                    job.status = "running"
                    job.started_at = datetime.now(timezone.utc).isoformat()
                    self._write_job_file(filepath, job)
                    logger.info("Dequeued job %s", job.id)
                    return job

            return None
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()

    def get_running(self) -> Optional[Job]:
        """Get the currently running job, if any.

        Scans the queue directory for a job with status ``"running"``.

        Returns:
            The running Job, or None if no job is currently running.
        """
        for filepath in self._sorted_queue_files():
            try:
                job = self._read_job_file(filepath)
            except Exception:
                continue
            if job.status == "running":
                return job
        return None

    def get_pending(self) -> list[Job]:
        """Get all pending jobs in FIFO order.

        Returns:
            List of Jobs with status ``"pending"``, sorted by enqueue time.
        """
        pending: list[Job] = []
        for filepath in self._sorted_queue_files():
            try:
                job = self._read_job_file(filepath)
            except Exception:
                continue
            if job.status == "pending":
                pending.append(job)
        return pending

    def get_completed(self, limit: int = 20) -> list[Job]:
        """Get recently completed jobs.

        Args:
            limit: Maximum number of completed jobs to return.

        Returns:
            List of completed Jobs, most recent first.
        """
        completed: list[Job] = []
        for filepath in self._sorted_completed_files():
            if len(completed) >= limit:
                break
            try:
                job = self._read_job_file(filepath)
            except Exception:
                continue
            completed.append(job)
        return completed

    def complete(
        self,
        job_id: str,
        status: str,
        exit_code: int,
        error: Optional[str] = None,
        results_branch: Optional[str] = None,
        push_success: Optional[bool] = None,
        push_error: Optional[str] = None,
        cleanup_success: Optional[bool] = None,
    ) -> None:
        """Mark a job as complete and move it to the completed directory.

        Finds the job file in the queue directory, updates its status,
        timestamps, and optional fields, then moves it to the completed
        directory.

        Args:
            job_id: ID of the job to complete.
            status: Final status (e.g. ``"completed"``, ``"failed"``, ``"timeout"``).
            exit_code: The btb process exit code.
            error: Optional error message.
            results_branch: Optional results branch name.
            push_success: Whether the result push succeeded.
            push_error: Error message if push failed.
            cleanup_success: Whether working directory cleanup succeeded.

        Raises:
            FileNotFoundError: If the job file is not found in the queue directory.
        """
        filepath = self._find_job_file_in_queue(job_id)
        if filepath is None:
            raise FileNotFoundError(
                f"Job file for {job_id} not found in queue directory"
            )

        job = self._read_job_file(filepath)
        job.status = status
        job.completed_at = datetime.now(timezone.utc).isoformat()
        job.exit_code = exit_code
        if error is not None:
            job.error = error
        if results_branch is not None:
            job.results_branch = results_branch
        if push_success is not None:
            job.push_success = push_success
        if push_error is not None:
            job.push_error = push_error
        if cleanup_success is not None:
            job.cleanup_success = cleanup_success

        # Move to completed directory, preserving the filename
        dest = self.completed_dir / filepath.name
        self._write_job_file(dest, job)
        filepath.unlink()

        logger.info(
            "Completed job %s with status=%s exit_code=%d",
            job_id, status, exit_code,
        )

    def get_job(self, job_id: str) -> Optional[Job]:
        """Find a job by ID, searching both queue and completed directories.

        Args:
            job_id: The job ID to search for.

        Returns:
            The Job if found, or None.
        """
        # Search queue directory first
        filepath = self._find_job_file_in_queue(job_id)
        if filepath is not None:
            try:
                return self._read_job_file(filepath)
            except Exception:
                pass

        # Search completed directory
        filepath = self._find_job_file_in_completed(job_id)
        if filepath is not None:
            try:
                return self._read_job_file(filepath)
            except Exception:
                pass

        return None

    def get_stopped(self, limit: int = 20) -> list[Job]:
        """Get stopped jobs that still have preserved working directories.

        Args:
            limit: Maximum number of stopped jobs to return.

        Returns:
            List of stopped Jobs, most recent first.
        """
        stopped: list[Job] = []
        for filepath in self._sorted_queue_files():
            if len(stopped) >= limit:
                break
            try:
                job = self._read_job_file(filepath)
            except Exception:
                continue
            if job.status == "stopped":
                stopped.append(job)
        return stopped

    def update_job(self, job_id: str, **updates) -> Optional[Job]:
        """Update a job's fields in place.

        Args:
            job_id: The job ID to update.
            **updates: Field names and values to update.

        Returns:
            The updated Job, or None if not found.
        """
        filepath = self._find_job_file_in_queue(job_id)
        if filepath is None:
            filepath = self._find_job_file_in_completed(job_id)
        if filepath is None:
            return None

        try:
            job = self._read_job_file(filepath)
            for key, value in updates.items():
                if hasattr(job, key):
                    setattr(job, key, value)
            self._write_job_file(filepath, job)
            return job
        except Exception:
            return None

    def delete_job(self, job_id: str) -> bool:
        """Delete a job from the queue or completed directory.

        Args:
            job_id: The job ID to delete.

        Returns:
            True if deleted, False if not found.
        """
        filepath = self._find_job_file_in_queue(job_id)
        if filepath is None:
            filepath = self._find_job_file_in_completed(job_id)
        if filepath is None:
            return False

        try:
            filepath.unlink()
            logger.info("Deleted job %s", job_id)
            return True
        except Exception:
            return False

    def move_to_queue(self, job_id: str) -> bool:
        """Move a job from completed back to queue (for resume).

        Args:
            job_id: The job ID to move.

        Returns:
            True if moved, False if not found or already in queue.
        """
        # Check if already in queue
        if self._find_job_file_in_queue(job_id) is not None:
            return False

        filepath = self._find_job_file_in_completed(job_id)
        if filepath is None:
            return False

        try:
            job = self._read_job_file(filepath)
            # Move to queue directory
            dest = self.queue_dir / filepath.name
            self._write_job_file(dest, job)
            filepath.unlink()
            logger.info("Moved job %s back to queue", job_id)
            return True
        except Exception:
            return False
