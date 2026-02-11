"""Web dashboard API routes and static file serving for the BTB Service.

Provides route handlers for the dashboard UI, job listing/detail APIs,
log file access, job retry, and WebSocket TUI streaming. All handlers
are async aiohttp request handlers that access shared state via
``request.app`` dictionary.

Expected app state keys:
    - ``job_queue``: :class:`server.queue.JobQueue`
    - ``streamer_manager``: :class:`server.streamer.TUIStreamerManager`
    - ``logs_dir``: ``str`` — path to the persistent logs directory
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from aiohttp import web, WSMsgType

from server.models import Job

logger = logging.getLogger(__name__)

# Path to the static directory relative to this file
_STATIC_DIR = Path(__file__).parent / "static"


async def handle_index(request: web.Request) -> web.Response:
    """Serve the single-page HTML dashboard.

    Returns:
        200 with the HTML content, or 404 if the file is missing.
    """
    index_path = _STATIC_DIR / "index.html"
    if not index_path.exists():
        return web.Response(status=404, text="Dashboard not found")
    return web.FileResponse(index_path)


async def handle_jobs_list(request: web.Request) -> web.Response:
    """Return a JSON list of running, pending, and completed jobs.

    Response format::

        {
            "running": <job_json or null>,
            "pending": [<job_json>, ...],
            "completed": [<job_json>, ...]
        }

    Returns:
        200 with JSON body.
    """
    queue = request.app["job_queue"]

    running_job = queue.get_running()
    pending_jobs = queue.get_pending()
    completed_jobs = queue.get_completed(limit=50)

    def job_to_dict(job: Job) -> dict:
        return json.loads(job.to_json())

    result = {
        "running": job_to_dict(running_job) if running_job else None,
        "pending": [job_to_dict(j) for j in pending_jobs],
        "completed": [job_to_dict(j) for j in completed_jobs],
    }

    return web.json_response(result)


async def handle_job_detail(request: web.Request) -> web.Response:
    """Return JSON details for a single job by ID.

    URL parameter:
        ``{id}`` — the job ID.

    Returns:
        200 with job JSON, or 404 if not found.
    """
    job_id = request.match_info["id"]
    queue = request.app["job_queue"]

    job = queue.get_job(job_id)
    if job is None:
        return web.json_response({"error": "Job not found"}, status=404)

    return web.json_response(json.loads(job.to_json()))


async def handle_job_logs_list(request: web.Request) -> web.Response:
    """List log files for a completed job.

    URL parameter:
        ``{id}`` — the job ID.

    Returns:
        200 with JSON list of filenames, or 404 if job or logs not found.
    """
    job_id = request.match_info["id"]
    queue = request.app["job_queue"]
    logs_dir = request.app["logs_dir"]

    job = queue.get_job(job_id)
    if job is None:
        return web.json_response({"error": "Job not found"}, status=404)

    job_logs_dir = Path(logs_dir) / job_id
    if not job_logs_dir.exists() or not job_logs_dir.is_dir():
        return web.json_response({"files": []})

    files = []
    for f in sorted(job_logs_dir.rglob("*")):
        if f.is_file():
            # Return relative path from the job logs dir
            files.append(str(f.relative_to(job_logs_dir)))

    return web.json_response({"files": files})


async def handle_job_log_file(request: web.Request) -> web.Response:
    """Serve a specific log file for a job.

    URL parameters:
        ``{id}`` — the job ID.
        ``{filename}`` — the log filename (may include path separators).

    Returns:
        200 with file content, or 404 if not found.
    """
    job_id = request.match_info["id"]
    filename = request.match_info["filename"]
    queue = request.app["job_queue"]
    logs_dir = request.app["logs_dir"]

    job = queue.get_job(job_id)
    if job is None:
        return web.json_response({"error": "Job not found"}, status=404)

    job_logs_dir = Path(logs_dir) / job_id
    file_path = (job_logs_dir / filename).resolve()

    # Security: ensure the resolved path is within the job logs directory
    try:
        file_path.relative_to(job_logs_dir.resolve())
    except ValueError:
        return web.json_response({"error": "Invalid file path"}, status=404)

    if not file_path.exists() or not file_path.is_file():
        return web.json_response({"error": "Log file not found"}, status=404)

    return web.FileResponse(file_path)


async def handle_job_retry(request: web.Request) -> web.Response:
    """Enqueue a new job as a retry of the specified job.

    URL parameter:
        ``{id}`` — the job ID to retry.

    Returns:
        201 with new job ID on success.
        404 if the original job is not found.
        409 if the original job is not in a terminal state.
    """
    job_id = request.match_info["id"]
    queue = request.app["job_queue"]

    original_job = queue.get_job(job_id)
    if original_job is None:
        return web.json_response({"error": "Job not found"}, status=404)

    # Only allow retry of terminal-state jobs
    terminal_states = {"completed", "failed", "timeout"}
    if original_job.status not in terminal_states:
        return web.json_response(
            {"error": f"Job is in state '{original_job.status}', not a terminal state"},
            status=409,
        )

    # Create a new job with the same parameters
    new_job = Job(
        id=str(uuid.uuid4()),
        repo_url=original_job.repo_url,
        branch=original_job.branch,
        commit_sha=original_job.commit_sha,
        pusher=original_job.pusher,
        spec_name=original_job.spec_name,
        status="pending",
        submitted_at=datetime.now(timezone.utc).isoformat(),
        started_at=None,
        completed_at=None,
        exit_code=None,
        error=None,
        results_branch=None,
        push_success=None,
        push_error=None,
        cleanup_success=None,
        retry_of=original_job.id,
    )

    new_job_id = queue.enqueue(new_job)
    logger.info(
        "Retried job %s as new job %s", job_id, new_job_id,
    )

    return web.json_response({"job_id": new_job_id}, status=201)


async def handle_tui_websocket(request: web.Request) -> web.WebSocketResponse:
    """WebSocket endpoint for live TUI streaming.

    URL parameter:
        ``{id}`` — the job ID to stream.

    Prepares a WebSocket response, registers the client with the
    TUIStreamer for the job, and waits for the client to disconnect.
    """
    job_id = request.match_info["id"]
    queue = request.app["job_queue"]
    streamer_manager = request.app["streamer_manager"]

    # Verify the job exists
    job = queue.get_job(job_id)
    if job is None:
        return web.Response(status=404, text="Job not found")

    ws = web.WebSocketResponse()
    await ws.prepare(request)

    # Get or create a streamer for this job
    # Determine the typescript path from the jobs_dir
    jobs_dir = request.app.get("jobs_dir", "")
    typescript_path = os.path.join(jobs_dir, job_id, "typescript.log")
    streamer = streamer_manager.get_or_create(job_id, typescript_path)

    await streamer.add_client(ws)

    try:
        # Read messages in a loop until the client disconnects
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                logger.warning(
                    "WebSocket error for job %s: %s",
                    job_id,
                    ws.exception(),
                )
                break
            # Ignore all other messages from the client
    finally:
        await streamer.remove_client(ws)

    return ws


def setup_routes(app: web.Application) -> None:
    """Register all dashboard routes on the aiohttp application.

    Args:
        app: The aiohttp Application to register routes on.
    """
    app.router.add_get("/", handle_index)
    app.router.add_get("/api/jobs", handle_jobs_list)
    app.router.add_get("/api/jobs/{id}", handle_job_detail)
    app.router.add_get("/api/jobs/{id}/logs", handle_job_logs_list)
    app.router.add_get("/api/jobs/{id}/logs/{filename:.+}", handle_job_log_file)
    app.router.add_post("/api/jobs/{id}/retry", handle_job_retry)
    app.router.add_get("/ws/jobs/{id}/tui", handle_tui_websocket)
