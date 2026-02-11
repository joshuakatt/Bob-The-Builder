"""Unit tests for server.queue module."""

import json
import time
from pathlib import Path

import pytest

from server.models import Job
from server.queue import JobQueue


# --- Helpers ---

def make_job(job_id: str = "test-job-1", **overrides) -> Job:
    """Create a Job with sensible defaults, allowing field overrides."""
    defaults = dict(
        id=job_id,
        repo_url="https://github.com/team/project.git",
        branch="feature/auth",
        commit_sha="abc123def456",
        pusher="developer1",
        spec_name="my-feature",
        status="pending",
        submitted_at="2025-01-15T10:30:00Z",
        started_at=None,
        completed_at=None,
        exit_code=None,
        error=None,
        results_branch=None,
        push_success=None,
        push_error=None,
        cleanup_success=None,
        retry_of=None,
    )
    defaults.update(overrides)
    return Job(**defaults)


@pytest.fixture
def queue(tmp_path) -> JobQueue:
    """Create a JobQueue using temporary directories."""
    return JobQueue(
        queue_dir=str(tmp_path / "queue"),
        completed_dir=str(tmp_path / "completed"),
        jobs_dir=str(tmp_path / "jobs"),
        lock_file=str(tmp_path / ".queue-lock"),
    )


# --- Constructor tests ---

class TestJobQueueInit:
    def test_creates_directories(self, tmp_path):
        q = JobQueue(
            queue_dir=str(tmp_path / "q"),
            completed_dir=str(tmp_path / "c"),
            jobs_dir=str(tmp_path / "j"),
            lock_file=str(tmp_path / "locks" / ".lock"),
        )
        assert (tmp_path / "q").is_dir()
        assert (tmp_path / "c").is_dir()
        assert (tmp_path / "j").is_dir()
        assert (tmp_path / "locks").is_dir()

    def test_existing_directories_ok(self, tmp_path):
        (tmp_path / "q").mkdir()
        (tmp_path / "c").mkdir()
        (tmp_path / "j").mkdir()
        # Should not raise
        JobQueue(
            queue_dir=str(tmp_path / "q"),
            completed_dir=str(tmp_path / "c"),
            jobs_dir=str(tmp_path / "j"),
            lock_file=str(tmp_path / ".lock"),
        )


# --- Enqueue tests ---

class TestEnqueue:
    def test_enqueue_returns_job_id(self, queue):
        job = make_job(job_id="abc-123")
        result = queue.enqueue(job)
        assert result == "abc-123"

    def test_enqueue_creates_file_in_queue_dir(self, queue):
        job = make_job(job_id="abc-123")
        queue.enqueue(job)
        files = list(queue.queue_dir.iterdir())
        assert len(files) == 1
        assert files[0].name.endswith("_abc-123.json")

    def test_enqueue_file_contains_valid_job_json(self, queue):
        job = make_job(job_id="abc-123")
        queue.enqueue(job)
        files = list(queue.queue_dir.iterdir())
        stored = Job.from_json(files[0].read_text())
        assert stored.id == "abc-123"
        assert stored.status == "pending"
        assert stored.repo_url == job.repo_url

    def test_enqueue_multiple_jobs_creates_multiple_files(self, queue):
        for i in range(3):
            queue.enqueue(make_job(job_id=f"job-{i}"))
        files = list(queue.queue_dir.iterdir())
        assert len(files) == 3

    def test_enqueue_preserves_all_job_fields(self, queue):
        job = make_job(
            job_id="full-job",
            retry_of="original-id",
            spec_name="special-spec",
        )
        queue.enqueue(job)
        files = list(queue.queue_dir.iterdir())
        stored = Job.from_json(files[0].read_text())
        assert stored == job


# --- Dequeue tests ---

class TestDequeue:
    def test_dequeue_empty_queue_returns_none(self, queue):
        assert queue.dequeue() is None

    def test_dequeue_returns_pending_job(self, queue):
        job = make_job(job_id="abc-123")
        queue.enqueue(job)
        result = queue.dequeue()
        assert result is not None
        assert result.id == "abc-123"

    def test_dequeue_sets_status_to_running(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        result = queue.dequeue()
        assert result.status == "running"

    def test_dequeue_sets_started_at(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        result = queue.dequeue()
        assert result.started_at is not None

    def test_dequeue_updates_file_on_disk(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        files = list(queue.queue_dir.iterdir())
        stored = Job.from_json(files[0].read_text())
        assert stored.status == "running"
        assert stored.started_at is not None

    def test_dequeue_skips_running_jobs(self, queue):
        queue.enqueue(make_job(job_id="job-1"))
        queue.enqueue(make_job(job_id="job-2"))
        # Dequeue first job (becomes running)
        first = queue.dequeue()
        assert first.id == "job-1"
        # Second dequeue should get job-2 (skips running job-1)
        second = queue.dequeue()
        assert second is not None
        assert second.id == "job-2"

    def test_dequeue_returns_none_when_all_running(self, queue):
        queue.enqueue(make_job(job_id="job-1"))
        queue.dequeue()  # job-1 is now running
        # No more pending jobs
        assert queue.dequeue() is None


# --- FIFO ordering tests ---

class TestFIFOOrdering:
    def test_fifo_order_preserved(self, queue):
        """Jobs dequeued in the same order they were enqueued."""
        ids = [f"job-{i}" for i in range(5)]
        for jid in ids:
            queue.enqueue(make_job(job_id=jid))
            # Small sleep to ensure distinct timestamps
            time.sleep(0.001)

        dequeued_ids = []
        for _ in range(5):
            job = queue.dequeue()
            assert job is not None
            dequeued_ids.append(job.id)

        assert dequeued_ids == ids

    def test_fifo_with_interleaved_complete(self, queue):
        """FIFO order maintained even when jobs complete between dequeues."""
        queue.enqueue(make_job(job_id="job-1"))
        time.sleep(0.001)
        queue.enqueue(make_job(job_id="job-2"))
        time.sleep(0.001)
        queue.enqueue(make_job(job_id="job-3"))

        first = queue.dequeue()
        assert first.id == "job-1"
        queue.complete("job-1", "completed", 0)

        second = queue.dequeue()
        assert second.id == "job-2"


# --- Complete tests ---

class TestComplete:
    def test_complete_moves_file_to_completed_dir(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0)

        queue_files = list(queue.queue_dir.iterdir())
        completed_files = list(queue.completed_dir.iterdir())
        assert len(queue_files) == 0
        assert len(completed_files) == 1
        assert completed_files[0].name.endswith("_abc-123.json")

    def test_complete_updates_status(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "failed", 1)

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.status == "failed"

    def test_complete_sets_completed_at(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0)

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.completed_at is not None

    def test_complete_sets_exit_code(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0)

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.exit_code == 0

    def test_complete_with_error(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "failed", 1, error="btb crashed")

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.error == "btb crashed"

    def test_complete_with_push_fields(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete(
            "abc-123",
            "completed",
            0,
            results_branch="btb-results/feature/auth",
            push_success=True,
        )

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.results_branch == "btb-results/feature/auth"
        assert job.push_success is True

    def test_complete_with_push_failure(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete(
            "abc-123",
            "completed",
            0,
            push_success=False,
            push_error="remote: Permission denied",
        )

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.push_success is False
        assert job.push_error == "remote: Permission denied"

    def test_complete_with_cleanup_success(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0, cleanup_success=True)

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.cleanup_success is True

    def test_complete_nonexistent_job_raises(self, queue):
        with pytest.raises(FileNotFoundError):
            queue.complete("nonexistent", "completed", 0)

    def test_complete_timeout_status(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete(
            "abc-123",
            "timeout",
            -9,
            error="Job exceeded 7200s timeout",
        )

        completed_files = list(queue.completed_dir.iterdir())
        job = Job.from_json(completed_files[0].read_text())
        assert job.status == "timeout"
        assert job.exit_code == -9
        assert job.error == "Job exceeded 7200s timeout"


# --- get_running tests ---

class TestGetRunning:
    def test_no_running_returns_none(self, queue):
        assert queue.get_running() is None

    def test_returns_running_job(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        running = queue.get_running()
        assert running is not None
        assert running.id == "abc-123"
        assert running.status == "running"

    def test_no_running_after_complete(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0)
        assert queue.get_running() is None

    def test_pending_jobs_not_returned(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        # Don't dequeue — job is still pending
        assert queue.get_running() is None


# --- get_pending tests ---

class TestGetPending:
    def test_empty_queue_returns_empty_list(self, queue):
        assert queue.get_pending() == []

    def test_returns_pending_jobs(self, queue):
        queue.enqueue(make_job(job_id="job-1"))
        queue.enqueue(make_job(job_id="job-2"))
        pending = queue.get_pending()
        assert len(pending) == 2

    def test_excludes_running_jobs(self, queue):
        queue.enqueue(make_job(job_id="job-1"))
        time.sleep(0.001)
        queue.enqueue(make_job(job_id="job-2"))
        queue.dequeue()  # job-1 becomes running
        pending = queue.get_pending()
        assert len(pending) == 1
        assert pending[0].id == "job-2"

    def test_fifo_order(self, queue):
        ids = ["job-a", "job-b", "job-c"]
        for jid in ids:
            queue.enqueue(make_job(job_id=jid))
            time.sleep(0.001)
        pending = queue.get_pending()
        assert [j.id for j in pending] == ids


# --- get_completed tests ---

class TestGetCompleted:
    def test_empty_returns_empty_list(self, queue):
        assert queue.get_completed() == []

    def test_returns_completed_jobs(self, queue):
        queue.enqueue(make_job(job_id="job-1"))
        queue.dequeue()
        queue.complete("job-1", "completed", 0)
        completed = queue.get_completed()
        assert len(completed) == 1
        assert completed[0].id == "job-1"

    def test_most_recent_first(self, queue):
        for i in range(3):
            queue.enqueue(make_job(job_id=f"job-{i}"))
            time.sleep(0.001)

        for i in range(3):
            queue.dequeue()
            queue.complete(f"job-{i}", "completed", 0)

        completed = queue.get_completed()
        # Most recent (job-2) should be first
        assert completed[0].id == "job-2"
        assert completed[-1].id == "job-0"

    def test_respects_limit(self, queue):
        for i in range(5):
            queue.enqueue(make_job(job_id=f"job-{i}"))
            time.sleep(0.001)

        for i in range(5):
            queue.dequeue()
            queue.complete(f"job-{i}", "completed", 0)

        completed = queue.get_completed(limit=2)
        assert len(completed) == 2


# --- get_job tests ---

class TestGetJob:
    def test_find_pending_job(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        job = queue.get_job("abc-123")
        assert job is not None
        assert job.id == "abc-123"
        assert job.status == "pending"

    def test_find_running_job(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        job = queue.get_job("abc-123")
        assert job is not None
        assert job.status == "running"

    def test_find_completed_job(self, queue):
        queue.enqueue(make_job(job_id="abc-123"))
        queue.dequeue()
        queue.complete("abc-123", "completed", 0)
        job = queue.get_job("abc-123")
        assert job is not None
        assert job.status == "completed"

    def test_nonexistent_job_returns_none(self, queue):
        assert queue.get_job("nonexistent") is None

    def test_find_among_multiple_jobs(self, queue):
        for i in range(5):
            queue.enqueue(make_job(job_id=f"job-{i}"))
            time.sleep(0.001)
        job = queue.get_job("job-3")
        assert job is not None
        assert job.id == "job-3"


# --- Full lifecycle test ---

class TestFullLifecycle:
    def test_enqueue_dequeue_complete_cycle(self, queue):
        """Full lifecycle: enqueue → dequeue → complete → verify."""
        job = make_job(job_id="lifecycle-test")
        queue.enqueue(job)

        # Verify pending
        assert len(queue.get_pending()) == 1
        assert queue.get_running() is None

        # Dequeue
        dequeued = queue.dequeue()
        assert dequeued.id == "lifecycle-test"
        assert dequeued.status == "running"
        assert len(queue.get_pending()) == 0
        assert queue.get_running() is not None

        # Complete
        queue.complete(
            "lifecycle-test",
            "completed",
            0,
            results_branch="btb-results/feature/auth",
            push_success=True,
            cleanup_success=True,
        )

        # Verify completed
        assert queue.get_running() is None
        assert len(queue.get_pending()) == 0
        completed = queue.get_completed()
        assert len(completed) == 1
        assert completed[0].id == "lifecycle-test"
        assert completed[0].status == "completed"
        assert completed[0].push_success is True
        assert completed[0].cleanup_success is True

        # get_job still finds it
        found = queue.get_job("lifecycle-test")
        assert found is not None
        assert found.status == "completed"
