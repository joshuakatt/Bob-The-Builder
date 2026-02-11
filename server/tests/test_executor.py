"""Unit tests for server.executor module.

Tests mock subprocess calls to avoid actually running btb. Each test
verifies a specific aspect of the JobExecutor lifecycle: successful runs,
timeout handling, cleanup, retry continuation, and stale directory cleanup.
"""

import asyncio
import os
import shutil
from pathlib import Path
from typing import Optional
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from server.executor import JobExecutor, KILL_GRACE_PERIOD
from server.models import Job, PushResult
from server.pusher import ResultPusher
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
        status="running",
        submitted_at="2025-01-15T10:30:00Z",
        started_at="2025-01-15T10:31:00Z",
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
def tmp_dirs(tmp_path):
    """Create temporary directories for jobs, logs, and btb."""
    jobs_dir = tmp_path / "jobs"
    logs_dir = tmp_path / "logs"
    btb_path = tmp_path / "btb"
    queue_dir = tmp_path / "queue"
    completed_dir = tmp_path / "completed"

    jobs_dir.mkdir()
    logs_dir.mkdir()
    btb_path.mkdir()
    queue_dir.mkdir()
    completed_dir.mkdir()

    # Create a fake setup.sh
    setup_sh = btb_path / "setup.sh"
    setup_sh.write_text("#!/bin/bash\nexit 0\n")
    setup_sh.chmod(0o755)

    # Create a fake btb.sh
    btb_sh = btb_path / "btb.sh"
    btb_sh.write_text("#!/bin/bash\nexit 0\n")
    btb_sh.chmod(0o755)

    return {
        "jobs_dir": str(jobs_dir),
        "logs_dir": str(logs_dir),
        "btb_path": str(btb_path),
        "queue_dir": str(queue_dir),
        "completed_dir": str(completed_dir),
        "tmp_path": tmp_path,
    }


@pytest.fixture
def mock_pusher():
    """Create a mock ResultPusher that always succeeds."""
    pusher = AsyncMock(spec=ResultPusher)
    pusher.push_results = AsyncMock(
        return_value=PushResult(
            success=True,
            branch="btb-results/feature/auth",
            error=None,
        )
    )
    return pusher


@pytest.fixture
def mock_queue(tmp_dirs):
    """Create a real JobQueue backed by temp directories."""
    lock_file = os.path.join(tmp_dirs["tmp_path"], ".queue-lock")
    queue = JobQueue(
        queue_dir=tmp_dirs["queue_dir"],
        completed_dir=tmp_dirs["completed_dir"],
        jobs_dir=tmp_dirs["jobs_dir"],
        lock_file=lock_file,
    )
    return queue


@pytest.fixture
def executor(tmp_dirs, mock_pusher, mock_queue):
    """Create a JobExecutor with mocked dependencies."""
    return JobExecutor(
        btb_path=tmp_dirs["btb_path"],
        jobs_dir=tmp_dirs["jobs_dir"],
        logs_dir=tmp_dirs["logs_dir"],
        pusher=mock_pusher,
        queue=mock_queue,
        job_timeout=7200,
    )


def _create_fake_repo(job_dir: Path, with_logs: bool = True) -> None:
    """Create a minimal fake repo directory structure for testing."""
    repo_dir = job_dir / "repo"
    repo_dir.mkdir(parents=True, exist_ok=True)
    (repo_dir / "README.md").write_text("# Test\n")
    if with_logs:
        ralph_logs = repo_dir / ".ralph-logs"
        ralph_logs.mkdir()
        (ralph_logs / "debug.log").write_text("some log content\n")


def _make_mock_process(returncode: int = 0):
    """Create a mock asyncio.subprocess.Process."""
    proc = MagicMock()
    proc.returncode = returncode
    proc.pid = 12345
    proc.communicate = AsyncMock(return_value=(b"", b""))
    proc.wait = AsyncMock()
    proc.kill = MagicMock()
    return proc


def _make_standard_mocks(jobs_dir: str, job_id: str, btb_returncode: int = 0):
    """Create standard mock factories for clone→checkout→setup→btb lifecycle.

    The mock clone step creates the fake repo directory so that subsequent
    steps (push, log preservation) find it on disk.

    Returns:
        (mock_exec_factory, mock_shell_factory) — callables for patching.
    """
    call_count = 0
    job_dir = Path(jobs_dir) / job_id

    async def mock_create_subprocess_exec(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        proc = _make_mock_process(0)
        # On the clone call, create the fake repo directory
        if call_count == 1:
            _create_fake_repo(job_dir)
        return proc

    mock_btb_proc = _make_mock_process(btb_returncode)
    mock_btb_proc.pid = 99999

    async def mock_create_subprocess_shell(cmd, **kwargs):
        return mock_btb_proc

    return mock_create_subprocess_exec, mock_create_subprocess_shell


# --- State management tests ---


class TestExecutorState:
    def test_initial_state(self, executor):
        """Executor starts with no running job."""
        assert executor.is_running() is False
        assert executor.get_current_job() is None

    def test_kill_current_no_process(self, executor):
        """kill_current is a no-op when no process is running."""
        # Should not raise
        executor.kill_current()


# --- Successful run lifecycle ---


class TestSuccessfulRun:
    def test_successful_run_returns_zero(self, executor, mock_queue, tmp_dirs):
        """A successful btb run returns exit code 0."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                exit_code = asyncio.get_event_loop().run_until_complete(
                    executor.run(job)
                )

        assert exit_code == 0
        assert executor.is_running() is False
        assert executor.get_current_job() is None

    def test_successful_run_calls_pusher(self, executor, mock_pusher, mock_queue, tmp_dirs):
        """After a successful run, results are pushed back."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        mock_pusher.push_results.assert_called_once()

    def test_successful_run_preserves_logs(self, executor, mock_queue, tmp_dirs):
        """After a successful run, .ralph-logs/ are preserved."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        logs_dest = Path(tmp_dirs["logs_dir"]) / job.id
        assert logs_dest.exists()
        assert (logs_dest / "debug.log").exists()

    def test_successful_run_cleans_workdir(self, executor, mock_queue, tmp_dirs):
        """After a successful run, the working directory is deleted."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        assert not job_dir.exists()

    def test_successful_run_completes_job_in_queue(self, executor, mock_queue, tmp_dirs):
        """After a successful run, the job is moved to completed."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        # Job should be in completed directory
        completed_jobs = mock_queue.get_completed()
        assert len(completed_jobs) == 1
        assert completed_jobs[0].id == job.id
        assert completed_jobs[0].status == "completed"
        assert completed_jobs[0].exit_code == 0
        assert completed_jobs[0].push_success is True
        assert completed_jobs[0].cleanup_success is True


# --- Timeout handling ---


class TestTimeoutHandling:
    def test_timeout_returns_negative_one(self, tmp_dirs, mock_pusher, mock_queue):
        """A timed-out job returns exit code -1."""
        executor = JobExecutor(
            btb_path=tmp_dirs["btb_path"],
            jobs_dir=tmp_dirs["jobs_dir"],
            logs_dir=tmp_dirs["logs_dir"],
            pusher=mock_pusher,
            queue=mock_queue,
            job_timeout=1,  # 1 second timeout
        )

        job = make_job()
        mock_queue.enqueue(job)

        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        call_count = 0

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            proc = _make_mock_process(0)
            if call_count == 1:
                _create_fake_repo(job_dir)
            return proc

        # btb process that hangs
        mock_btb_proc = MagicMock()
        mock_btb_proc.returncode = None
        mock_btb_proc.pid = 99999

        async def hanging_communicate():
            await asyncio.sleep(100)  # Hang forever
            return (b"", b"")

        mock_btb_proc.communicate = hanging_communicate

        async def quick_wait():
            mock_btb_proc.returncode = -15  # SIGTERM
            return -15

        mock_btb_proc.wait = quick_wait
        mock_btb_proc.kill = MagicMock()

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                with patch("os.getpgid", return_value=99999):
                    with patch("os.killpg"):
                        exit_code = asyncio.get_event_loop().run_until_complete(
                            executor.run(job)
                        )

        assert exit_code == -1

    def test_timeout_records_timeout_status(self, tmp_dirs, mock_pusher, mock_queue):
        """A timed-out job is recorded with 'timeout' status."""
        executor = JobExecutor(
            btb_path=tmp_dirs["btb_path"],
            jobs_dir=tmp_dirs["jobs_dir"],
            logs_dir=tmp_dirs["logs_dir"],
            pusher=mock_pusher,
            queue=mock_queue,
            job_timeout=1,
        )

        job = make_job()
        mock_queue.enqueue(job)

        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        call_count = 0

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            proc = _make_mock_process(0)
            if call_count == 1:
                _create_fake_repo(job_dir)
            return proc

        mock_btb_proc = MagicMock()
        mock_btb_proc.returncode = None
        mock_btb_proc.pid = 99999

        async def hanging_communicate():
            await asyncio.sleep(100)
            return (b"", b"")

        mock_btb_proc.communicate = hanging_communicate

        async def quick_wait():
            mock_btb_proc.returncode = -15
            return -15

        mock_btb_proc.wait = quick_wait
        mock_btb_proc.kill = MagicMock()

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                with patch("os.getpgid", return_value=99999):
                    with patch("os.killpg"):
                        asyncio.get_event_loop().run_until_complete(
                            executor.run(job)
                        )

        completed_jobs = mock_queue.get_completed()
        assert len(completed_jobs) == 1
        assert completed_jobs[0].status == "timeout"


# --- Cleanup after completion ---


class TestCleanupAfterCompletion:
    def test_cleanup_on_btb_failure(self, executor, mock_queue, tmp_dirs):
        """Working directory is cleaned up even when btb fails."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, _ = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id, btb_returncode=1)

        # Override shell mock to return failure
        mock_btb_proc = _make_mock_process(1)
        mock_btb_proc.pid = 99999

        async def mock_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                exit_code = asyncio.get_event_loop().run_until_complete(
                    executor.run(job)
                )

        assert exit_code == 1
        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        assert not job_dir.exists()

        completed_jobs = mock_queue.get_completed()
        assert completed_jobs[0].status == "failed"

    def test_cleanup_failure_recorded(self, executor, mock_queue, tmp_dirs):
        """If cleanup fails, cleanup_success=False is recorded."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                # Make cleanup fail by patching shutil.rmtree
                with patch("server.executor.shutil.rmtree", side_effect=OSError("Permission denied")):
                    asyncio.get_event_loop().run_until_complete(
                        executor.run(job)
                    )

        completed_jobs = mock_queue.get_completed()
        assert len(completed_jobs) == 1
        assert completed_jobs[0].cleanup_success is False

    def test_push_failure_recorded(self, executor, mock_pusher, mock_queue, tmp_dirs):
        """If push fails, push_success=False and push_error are recorded."""
        mock_pusher.push_results = AsyncMock(
            return_value=PushResult(
                success=False,
                branch="btb-results/feature/auth",
                error="Remote unreachable",
            )
        )

        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        completed_jobs = mock_queue.get_completed()
        assert len(completed_jobs) == 1
        assert completed_jobs[0].push_success is False
        assert completed_jobs[0].push_error == "Remote unreachable"


# --- Retry continuation ---


class TestRetryContinuation:
    def test_retry_fetches_results_branch(self, executor, mock_queue, tmp_dirs):
        """When retry_of is set, executor fetches the results branch."""
        job = make_job(retry_of="original-job-id")
        mock_queue.enqueue(job)

        # Track git commands to verify fetch and merge
        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        call_count = 0

        # ls-remote returns a ref (branch exists)
        mock_ls_remote = _make_mock_process(0)
        mock_ls_remote.communicate = AsyncMock(
            return_value=(b"abc123\trefs/heads/btb-results/feature/auth\n", b"")
        )

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            proc = _make_mock_process(0)

            # clone
            if call_count == 1:
                _create_fake_repo(job_dir)
                return proc
            # checkout
            elif call_count == 2:
                return proc
            # ls-remote (retry check)
            elif call_count == 3:
                return mock_ls_remote
            # fetch, merge, setup
            else:
                return proc

        mock_btb_proc = _make_mock_process(0)
        mock_btb_proc.pid = 99999

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        # Verify that ls-remote, fetch, and merge were called
        assert call_count >= 5  # clone, checkout, ls-remote, fetch, merge, setup

    def test_no_retry_when_retry_of_not_set(self, executor, mock_queue, tmp_dirs):
        """When retry_of is None, no retry continuation is attempted."""
        job = make_job(retry_of=None)
        mock_queue.enqueue(job)

        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        call_count = 0

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            proc = _make_mock_process(0)
            if call_count == 1:
                _create_fake_repo(job_dir)
            return proc

        mock_btb_proc = _make_mock_process(0)
        mock_btb_proc.pid = 99999

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        # Should be: clone, checkout, setup — no ls-remote/fetch/merge
        assert call_count == 3

    def test_retry_continues_on_fetch_failure(self, executor, mock_queue, tmp_dirs):
        """If fetching the results branch fails, btb starts fresh."""
        job = make_job(retry_of="original-job-id")
        mock_queue.enqueue(job)

        job_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        call_count = 0

        # ls-remote returns a ref (branch exists)
        mock_ls_remote = _make_mock_process(0)
        mock_ls_remote.communicate = AsyncMock(
            return_value=(b"abc123\trefs/heads/btb-results/feature/auth\n", b"")
        )

        # fetch fails
        mock_fetch_fail = _make_mock_process(1)
        mock_fetch_fail.communicate = AsyncMock(
            return_value=(b"", b"fatal: could not fetch")
        )

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:  # clone
                _create_fake_repo(job_dir)
                return _make_mock_process(0)
            elif call_count == 2:  # checkout
                return _make_mock_process(0)
            elif call_count == 3:  # ls-remote
                return mock_ls_remote
            elif call_count == 4:  # fetch (fails)
                return mock_fetch_fail
            else:  # setup
                return _make_mock_process(0)

        mock_btb_proc = _make_mock_process(0)
        mock_btb_proc.pid = 99999

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                exit_code = asyncio.get_event_loop().run_until_complete(
                    executor.run(job)
                )

        # Should still succeed — fetch failure is non-fatal
        assert exit_code == 0


# --- Stale directory cleanup ---


class TestStaleDirectoryCleanup:
    def test_stale_directory_is_deleted(self, executor, mock_queue, tmp_dirs):
        """A pre-existing job directory is deleted before starting."""
        job = make_job()
        mock_queue.enqueue(job)

        # Create a stale directory
        stale_dir = Path(tmp_dirs["jobs_dir"]) / job.id
        stale_dir.mkdir(parents=True)
        (stale_dir / "leftover.txt").write_text("stale data\n")

        call_count = 0

        async def mock_create_subprocess_exec(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            proc = _make_mock_process(0)
            # After stale cleanup, clone creates the repo dir
            if call_count == 1:
                _create_fake_repo(stale_dir)
            return proc

        mock_btb_proc = _make_mock_process(0)
        mock_btb_proc.pid = 99999

        async def mock_create_subprocess_shell(cmd, **kwargs):
            return mock_btb_proc

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_create_subprocess_shell):
                exit_code = asyncio.get_event_loop().run_until_complete(
                    executor.run(job)
                )

        # Job should complete successfully despite stale dir
        assert exit_code == 0


# --- Single job invariant ---


class TestSingleJobInvariant:
    def test_cannot_run_two_jobs_simultaneously(self, executor):
        """Running a second job while one is active raises RuntimeError."""
        executor._running = True
        executor._current_job = make_job()

        with pytest.raises(RuntimeError, match="Another job is already running"):
            asyncio.get_event_loop().run_until_complete(
                executor.run(make_job(job_id="second-job"))
            )

    def test_state_reset_after_run(self, executor, mock_queue, tmp_dirs):
        """After a run completes, the executor is ready for the next job."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_exec, mock_shell = _make_standard_mocks(tmp_dirs["jobs_dir"], job.id)

        with patch("asyncio.create_subprocess_exec", side_effect=mock_exec):
            with patch("asyncio.create_subprocess_shell", side_effect=mock_shell):
                asyncio.get_event_loop().run_until_complete(executor.run(job))

        assert executor.is_running() is False
        assert executor.get_current_job() is None


# --- Clone failure ---


class TestCloneFailure:
    def test_clone_failure_records_failed_status(self, executor, mock_queue, tmp_dirs):
        """If git clone fails, the job is marked as failed."""
        job = make_job()
        mock_queue.enqueue(job)

        mock_clone_fail = _make_mock_process(128)
        mock_clone_fail.communicate = AsyncMock(
            return_value=(b"", b"fatal: repository not found")
        )

        async def mock_create_subprocess_exec(*args, **kwargs):
            return mock_clone_fail

        with patch("asyncio.create_subprocess_exec", side_effect=mock_create_subprocess_exec):
            exit_code = asyncio.get_event_loop().run_until_complete(
                executor.run(job)
            )

        assert exit_code == 128
        completed_jobs = mock_queue.get_completed()
        assert len(completed_jobs) == 1
        assert completed_jobs[0].status == "failed"
        assert "clone" in completed_jobs[0].error.lower() or "checkout" in completed_jobs[0].error.lower()
