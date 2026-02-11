"""Unit tests for log retention cleanup logic.

Tests the ``run_log_cleanup`` function from ``server.main`` which scans
the completed directory for expired job JSON files and deletes both the
JSON and the preserved logs directory when the retention period has passed.

Validates: Requirements 7.3, 7.4
"""

import json
import os
from datetime import datetime, timezone, timedelta
from pathlib import Path

import pytest

from server.main import run_log_cleanup
from server.models import Job


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_job(
    job_id: str = "job-001",
    completed_at: str | None = None,
    status: str = "completed",
    **overrides,
) -> Job:
    """Create a Job with sensible defaults for cleanup tests."""
    defaults = dict(
        id=job_id,
        repo_url="https://github.com/team/project.git",
        branch="main",
        commit_sha="abc123",
        pusher="dev1",
        spec_name="my-spec",
        status=status,
        submitted_at="2025-01-01T00:00:00+00:00",
        started_at="2025-01-01T00:01:00+00:00",
        completed_at=completed_at,
        exit_code=0,
        error=None,
        results_branch=None,
        push_success=True,
        push_error=None,
        cleanup_success=True,
        retry_of=None,
    )
    defaults.update(overrides)
    return Job(**defaults)


def _write_job_file(completed_dir: Path, job: Job, prefix: str = "1700000000") -> Path:
    """Write a job JSON file into the completed directory and return its path."""
    filename = f"{prefix}_{job.id}.json"
    filepath = completed_dir / filename
    filepath.write_text(job.to_json())
    return filepath


def _create_logs_dir(logs_dir: Path, job_id: str) -> Path:
    """Create a fake preserved logs directory for a job."""
    job_logs = logs_dir / job_id
    job_logs.mkdir(parents=True, exist_ok=True)
    # Add some fake log files
    (job_logs / "debug.log").write_text("debug output\n")
    (job_logs / "task-1.log").write_text("task output\n")
    return job_logs


@pytest.fixture
def cleanup_dirs(tmp_path):
    """Create temporary completed and logs directories."""
    completed_dir = tmp_path / "completed"
    logs_dir = tmp_path / "logs"
    completed_dir.mkdir()
    logs_dir.mkdir()
    return completed_dir, logs_dir


# ---------------------------------------------------------------------------
# Tests: Jobs beyond retention period are deleted
# ---------------------------------------------------------------------------


class TestExpiredJobDeletion:
    """Jobs older than the retention period should be fully deleted."""

    def test_expired_job_json_is_deleted(self, cleanup_dirs):
        """Job JSON file is removed when completed_at exceeds retention."""
        completed_dir, logs_dir = cleanup_dirs
        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        job = _make_job(job_id="expired-1", completed_at=old_time)
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert not filepath.exists(), "Expired job JSON should be deleted"

    def test_expired_job_logs_are_deleted(self, cleanup_dirs):
        """Preserved logs directory is removed for expired jobs."""
        completed_dir, logs_dir = cleanup_dirs
        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        job = _make_job(job_id="expired-2", completed_at=old_time)
        _write_job_file(completed_dir, job)
        job_logs = _create_logs_dir(logs_dir, "expired-2")

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert not job_logs.exists(), "Expired job logs directory should be deleted"

    def test_expired_job_returns_count(self, cleanup_dirs):
        """run_log_cleanup returns the number of deleted jobs."""
        completed_dir, logs_dir = cleanup_dirs
        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        for i in range(3):
            job = _make_job(job_id=f"expired-{i}", completed_at=old_time)
            _write_job_file(completed_dir, job, prefix=f"170000000{i}")

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 3

    def test_expired_job_without_logs_dir(self, cleanup_dirs):
        """Cleanup succeeds even when no logs directory exists for the job."""
        completed_dir, logs_dir = cleanup_dirs
        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        job = _make_job(job_id="no-logs", completed_at=old_time)
        filepath = _write_job_file(completed_dir, job)

        # No logs directory created — should not raise
        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 1
        assert not filepath.exists()


# ---------------------------------------------------------------------------
# Tests: Jobs within retention period are kept
# ---------------------------------------------------------------------------


class TestRetainedJobs:
    """Jobs within the retention period should be preserved."""

    def test_recent_job_json_is_kept(self, cleanup_dirs):
        """Job JSON file is preserved when within retention period."""
        completed_dir, logs_dir = cleanup_dirs
        recent_time = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
        job = _make_job(job_id="recent-1", completed_at=recent_time)
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert filepath.exists(), "Recent job JSON should be preserved"

    def test_recent_job_logs_are_kept(self, cleanup_dirs):
        """Preserved logs directory is kept for recent jobs."""
        completed_dir, logs_dir = cleanup_dirs
        recent_time = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
        job = _make_job(job_id="recent-2", completed_at=recent_time)
        _write_job_file(completed_dir, job)
        job_logs = _create_logs_dir(logs_dir, "recent-2")

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert job_logs.exists(), "Recent job logs should be preserved"

    def test_job_exactly_at_retention_boundary_is_kept(self, cleanup_dirs):
        """Job completed exactly at the retention boundary is not deleted.

        The cutoff is computed as now - retention_days. A job completed
        at exactly the cutoff time is NOT older than the cutoff (it equals
        it), so it should be kept. In practice, the comparison is strict
        less-than, so a job at the boundary is retained.
        """
        completed_dir, logs_dir = cleanup_dirs
        # Use a time just barely within retention (1 second inside)
        boundary_time = (
            datetime.now(timezone.utc) - timedelta(days=7) + timedelta(seconds=1)
        ).isoformat()
        job = _make_job(job_id="boundary", completed_at=boundary_time)
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert filepath.exists(), "Job at retention boundary should be kept"

    def test_returns_zero_when_nothing_expired(self, cleanup_dirs):
        """Returns 0 when no jobs are expired."""
        completed_dir, logs_dir = cleanup_dirs
        recent_time = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
        job = _make_job(job_id="fresh", completed_at=recent_time)
        _write_job_file(completed_dir, job)

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 0


# ---------------------------------------------------------------------------
# Tests: Mixed expired and retained jobs
# ---------------------------------------------------------------------------


class TestMixedJobs:
    """When both expired and recent jobs exist, only expired ones are deleted."""

    def test_only_expired_jobs_are_deleted(self, cleanup_dirs):
        """Expired jobs are deleted while recent jobs are preserved."""
        completed_dir, logs_dir = cleanup_dirs

        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        recent_time = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()

        expired_job = _make_job(job_id="old-job", completed_at=old_time)
        recent_job = _make_job(job_id="new-job", completed_at=recent_time)

        expired_path = _write_job_file(completed_dir, expired_job, prefix="1700000001")
        recent_path = _write_job_file(completed_dir, recent_job, prefix="1700000002")

        _create_logs_dir(logs_dir, "old-job")
        recent_logs = _create_logs_dir(logs_dir, "new-job")

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 1
        assert not expired_path.exists(), "Expired job should be deleted"
        assert recent_path.exists(), "Recent job should be preserved"
        assert not (logs_dir / "old-job").exists(), "Expired logs should be deleted"
        assert recent_logs.exists(), "Recent logs should be preserved"


# ---------------------------------------------------------------------------
# Tests: Edge cases
# ---------------------------------------------------------------------------


class TestEdgeCases:
    """Edge cases: missing completed_at, malformed files, empty directory."""

    def test_job_without_completed_at_is_skipped(self, cleanup_dirs):
        """Jobs with no completed_at timestamp are never deleted."""
        completed_dir, logs_dir = cleanup_dirs
        job = _make_job(job_id="no-timestamp", completed_at=None, status="running")
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert filepath.exists(), "Job without completed_at should be skipped"

    def test_malformed_json_file_is_skipped(self, cleanup_dirs):
        """Malformed JSON files are skipped without crashing."""
        completed_dir, logs_dir = cleanup_dirs
        bad_file = completed_dir / "1700000000_bad-job.json"
        bad_file.write_text("this is not valid json {{{")

        # Should not raise
        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 0
        assert bad_file.exists(), "Malformed file should not be deleted"

    def test_empty_completed_directory(self, cleanup_dirs):
        """Cleanup handles an empty completed directory gracefully."""
        completed_dir, logs_dir = cleanup_dirs

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 0

    def test_nonexistent_completed_directory(self, tmp_path):
        """Cleanup handles a non-existent completed directory gracefully."""
        completed_dir = tmp_path / "does-not-exist"
        logs_dir = tmp_path / "logs"
        logs_dir.mkdir()

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 0

    def test_non_json_files_are_ignored(self, cleanup_dirs):
        """Non-JSON files in the completed directory are ignored."""
        completed_dir, logs_dir = cleanup_dirs

        # Create a non-JSON file
        (completed_dir / "README.txt").write_text("not a job file")
        (completed_dir / "backup.bak").write_text("backup data")

        # Also create a valid expired job to ensure cleanup still works
        old_time = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        job = _make_job(job_id="real-job", completed_at=old_time)
        _write_job_file(completed_dir, job)

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 1
        assert (completed_dir / "README.txt").exists()
        assert (completed_dir / "backup.bak").exists()

    def test_incomplete_job_json_is_skipped(self, cleanup_dirs):
        """JSON files with missing required Job fields are skipped."""
        completed_dir, logs_dir = cleanup_dirs
        incomplete = completed_dir / "1700000000_incomplete.json"
        incomplete.write_text(json.dumps({"id": "incomplete", "status": "done"}))

        count = run_log_cleanup(completed_dir, logs_dir, retention_days=7)

        assert count == 0
        assert incomplete.exists(), "Incomplete JSON should not be deleted"


# ---------------------------------------------------------------------------
# Tests: Configurable retention period
# ---------------------------------------------------------------------------


class TestConfigurableRetention:
    """Retention period is configurable and respected."""

    def test_custom_retention_1_day(self, cleanup_dirs):
        """With 1-day retention, 2-day-old jobs are deleted."""
        completed_dir, logs_dir = cleanup_dirs
        two_days_ago = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        job = _make_job(job_id="short-retention", completed_at=two_days_ago)
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=1)

        assert not filepath.exists()

    def test_custom_retention_30_days(self, cleanup_dirs):
        """With 30-day retention, 10-day-old jobs are kept."""
        completed_dir, logs_dir = cleanup_dirs
        ten_days_ago = (datetime.now(timezone.utc) - timedelta(days=10)).isoformat()
        job = _make_job(job_id="long-retention", completed_at=ten_days_ago)
        filepath = _write_job_file(completed_dir, job)

        run_log_cleanup(completed_dir, logs_dir, retention_days=30)

        assert filepath.exists()
