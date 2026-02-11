"""Unit tests for the BTB Service dashboard API routes.

Tests cover:
- GET /api/jobs — returns correct structure with running, pending, completed
- GET /api/jobs/{id} — returns job details or 404
- POST /api/jobs/{id}/retry — creates new job (201), 404 for unknown, 409 for non-terminal
- GET /api/jobs/{id}/logs — returns file list
- GET /api/jobs/{id}/logs/{filename} — serves log file content
- GET / — serves the static HTML dashboard
"""

import json
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pytest
from aiohttp import web

from server.dashboard import setup_routes
from server.models import Job
from server.queue import JobQueue
from server.streamer import TUIStreamerManager


def make_job(
    status="pending",
    job_id=None,
    repo_url="https://github.com/team/project.git",
    branch="main",
    commit_sha="abc123",
    pusher="dev1",
    spec_name="my-spec",
    retry_of=None,
    push_success=None,
    push_error=None,
    cleanup_success=None,
):
    """Helper to create a Job with sensible defaults."""
    return Job(
        id=job_id or str(uuid.uuid4()),
        repo_url=repo_url,
        branch=branch,
        commit_sha=commit_sha,
        pusher=pusher,
        spec_name=spec_name,
        status=status,
        submitted_at=datetime.now(timezone.utc).isoformat(),
        started_at=datetime.now(timezone.utc).isoformat() if status != "pending" else None,
        completed_at=datetime.now(timezone.utc).isoformat() if status in ("completed", "failed", "timeout") else None,
        exit_code=0 if status == "completed" else (1 if status == "failed" else None),
        error="btb exited with code 1" if status == "failed" else None,
        results_branch=f"btb-results/{branch}" if status in ("completed", "failed", "timeout") else None,
        push_success=push_success,
        push_error=push_error,
        cleanup_success=cleanup_success,
        retry_of=retry_of,
    )


def create_test_app(tmp_path):
    """Create an aiohttp app with dashboard routes and temp directories."""
    queue_dir = tmp_path / "queue"
    completed_dir = tmp_path / "completed"
    jobs_dir = tmp_path / "jobs"
    logs_dir = tmp_path / "logs"
    lock_file = tmp_path / ".queue-lock"
    for d in [queue_dir, completed_dir, jobs_dir, logs_dir]:
        d.mkdir(exist_ok=True)

    queue = JobQueue(
        queue_dir=str(queue_dir),
        completed_dir=str(completed_dir),
        jobs_dir=str(jobs_dir),
        lock_file=str(lock_file),
    )

    app = web.Application()
    app["job_queue"] = queue
    app["streamer_manager"] = TUIStreamerManager()
    app["logs_dir"] = str(logs_dir)
    app["jobs_dir"] = str(jobs_dir)
    setup_routes(app)
    return app, queue, str(logs_dir)


# ---------------------------------------------------------------
# GET /api/jobs
# ---------------------------------------------------------------


class TestJobsList:
    @pytest.mark.asyncio
    async def test_empty(self, aiohttp_client, tmp_path):
        """GET /api/jobs returns correct structure when no jobs exist."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.get("/api/jobs")
        assert resp.status == 200
        data = await resp.json()
        assert data["running"] is None
        assert data["pending"] == []
        assert data["completed"] == []

    @pytest.mark.asyncio
    async def test_with_pending(self, aiohttp_client, tmp_path):
        """GET /api/jobs returns pending jobs."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        resp = await client.get("/api/jobs")
        assert resp.status == 200
        data = await resp.json()
        assert data["running"] is None
        assert len(data["pending"]) == 1
        assert data["pending"][0]["id"] == job.id

    @pytest.mark.asyncio
    async def test_with_running(self, aiohttp_client, tmp_path):
        """GET /api/jobs returns the running job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()  # moves to running

        resp = await client.get("/api/jobs")
        assert resp.status == 200
        data = await resp.json()
        assert data["running"] is not None
        assert data["running"]["id"] == job.id
        assert data["running"]["status"] == "running"

    @pytest.mark.asyncio
    async def test_with_completed(self, aiohttp_client, tmp_path):
        """GET /api/jobs returns completed jobs."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()
        queue.complete(job.id, status="completed", exit_code=0)

        resp = await client.get("/api/jobs")
        assert resp.status == 200
        data = await resp.json()
        assert data["running"] is None
        assert len(data["completed"]) == 1
        assert data["completed"][0]["id"] == job.id
        assert data["completed"][0]["status"] == "completed"


# ---------------------------------------------------------------
# GET /api/jobs/{id}
# ---------------------------------------------------------------


class TestJobDetail:
    @pytest.mark.asyncio
    async def test_found(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id} returns job details when found."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        resp = await client.get(f"/api/jobs/{job.id}")
        assert resp.status == 200
        data = await resp.json()
        assert data["id"] == job.id
        assert data["repo_url"] == job.repo_url
        assert data["branch"] == job.branch
        assert data["spec_name"] == job.spec_name
        assert data["pusher"] == job.pusher

    @pytest.mark.asyncio
    async def test_not_found(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id} returns 404 for unknown job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.get("/api/jobs/nonexistent-id")
        assert resp.status == 404
        data = await resp.json()
        assert "error" in data

    @pytest.mark.asyncio
    async def test_includes_push_cleanup_retry_fields(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id} includes push, cleanup, and retry fields."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(
            status="pending",
            push_success=True,
            cleanup_success=True,
            retry_of="original-job-id",
        )
        queue.enqueue(job)

        resp = await client.get(f"/api/jobs/{job.id}")
        assert resp.status == 200
        data = await resp.json()
        assert data["push_success"] is True
        assert data["cleanup_success"] is True
        assert data["retry_of"] == "original-job-id"


# ---------------------------------------------------------------
# POST /api/jobs/{id}/retry
# ---------------------------------------------------------------


class TestJobRetry:
    @pytest.mark.asyncio
    async def test_retry_completed_job(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry creates a new job for a completed job (201)."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()
        queue.complete(job.id, status="completed", exit_code=0)

        resp = await client.post(f"/api/jobs/{job.id}/retry")
        assert resp.status == 201
        data = await resp.json()
        assert "job_id" in data
        new_job_id = data["job_id"]

        # Verify the new job exists and has correct fields
        new_job = queue.get_job(new_job_id)
        assert new_job is not None
        assert new_job.repo_url == job.repo_url
        assert new_job.branch == job.branch
        assert new_job.commit_sha == job.commit_sha
        assert new_job.spec_name == job.spec_name
        assert new_job.pusher == job.pusher
        assert new_job.status == "pending"
        assert new_job.retry_of == job.id

    @pytest.mark.asyncio
    async def test_retry_failed_job(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry works for failed jobs."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()
        queue.complete(job.id, status="failed", exit_code=1, error="btb failed")

        resp = await client.post(f"/api/jobs/{job.id}/retry")
        assert resp.status == 201
        data = await resp.json()
        new_job = queue.get_job(data["job_id"])
        assert new_job.retry_of == job.id

    @pytest.mark.asyncio
    async def test_retry_timeout_job(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry works for timed-out jobs."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()
        queue.complete(job.id, status="timeout", exit_code=-1)

        resp = await client.post(f"/api/jobs/{job.id}/retry")
        assert resp.status == 201

    @pytest.mark.asyncio
    async def test_retry_not_found(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry returns 404 for unknown job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.post("/api/jobs/nonexistent-id/retry")
        assert resp.status == 404
        data = await resp.json()
        assert "error" in data

    @pytest.mark.asyncio
    async def test_retry_pending_job_409(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry returns 409 for a pending job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        resp = await client.post(f"/api/jobs/{job.id}/retry")
        assert resp.status == 409
        data = await resp.json()
        assert "error" in data

    @pytest.mark.asyncio
    async def test_retry_running_job_409(self, aiohttp_client, tmp_path):
        """POST /api/jobs/{id}/retry returns 409 for a running job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)
        queue.dequeue()  # moves to running

        resp = await client.post(f"/api/jobs/{job.id}/retry")
        assert resp.status == 409


# ---------------------------------------------------------------
# GET /api/jobs/{id}/logs
# ---------------------------------------------------------------


class TestJobLogs:
    @pytest.mark.asyncio
    async def test_logs_list_with_files(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs returns list of log files."""
        app, queue, logs_dir = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        # Create some log files
        log_dir = Path(logs_dir) / job.id
        log_dir.mkdir(parents=True)
        (log_dir / "debug.log").write_text("debug output")
        (log_dir / "task-1.log").write_text("task 1 output")

        resp = await client.get(f"/api/jobs/{job.id}/logs")
        assert resp.status == 200
        data = await resp.json()
        assert "files" in data
        assert sorted(data["files"]) == ["debug.log", "task-1.log"]

    @pytest.mark.asyncio
    async def test_logs_list_no_logs_dir(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs returns empty list when no logs directory exists."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        resp = await client.get(f"/api/jobs/{job.id}/logs")
        assert resp.status == 200
        data = await resp.json()
        assert data["files"] == []

    @pytest.mark.asyncio
    async def test_logs_list_job_not_found(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs returns 404 for unknown job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.get("/api/jobs/nonexistent-id/logs")
        assert resp.status == 404


# ---------------------------------------------------------------
# GET /api/jobs/{id}/logs/{filename}
# ---------------------------------------------------------------


class TestJobLogFile:
    @pytest.mark.asyncio
    async def test_log_file_served(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs/{filename} serves the log file content."""
        app, queue, logs_dir = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        log_dir = Path(logs_dir) / job.id
        log_dir.mkdir(parents=True)
        (log_dir / "debug.log").write_text("hello world")

        resp = await client.get(f"/api/jobs/{job.id}/logs/debug.log")
        assert resp.status == 200
        text = await resp.text()
        assert "hello world" in text

    @pytest.mark.asyncio
    async def test_log_file_not_found(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs/{filename} returns 404 for missing file."""
        app, queue, logs_dir = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        job = make_job(status="pending")
        queue.enqueue(job)

        log_dir = Path(logs_dir) / job.id
        log_dir.mkdir(parents=True)

        resp = await client.get(f"/api/jobs/{job.id}/logs/nonexistent.log")
        assert resp.status == 404

    @pytest.mark.asyncio
    async def test_log_file_job_not_found(self, aiohttp_client, tmp_path):
        """GET /api/jobs/{id}/logs/{filename} returns 404 for unknown job."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.get("/api/jobs/nonexistent-id/logs/debug.log")
        assert resp.status == 404


# ---------------------------------------------------------------
# GET / (static dashboard)
# ---------------------------------------------------------------


class TestIndex:
    @pytest.mark.asyncio
    async def test_serves_html(self, aiohttp_client, tmp_path):
        """GET / serves the HTML dashboard."""
        app, queue, _ = create_test_app(tmp_path)
        client = await aiohttp_client(app)

        resp = await client.get("/")
        assert resp.status == 200
        text = await resp.text()
        assert "BTB Dashboard" in text
        assert "xterm" in text
