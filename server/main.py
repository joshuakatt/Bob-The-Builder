"""BTB Service entry point.

Wires together all components: config loader, job queue, result pusher,
job executor, TUI streamer manager, webhook receiver, and web dashboard.
Starts background tasks for queue polling, log cleanup, and credential
refresh, sets up TLS, and runs the aiohttp application.
"""

import asyncio
import logging
import os
import shutil
import ssl
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Callable, Optional

from aiohttp import web

from server.config import load_config, ConfigError, Config
from server.dashboard import setup_routes
from server.executor import JobExecutor
from server.models import Job
from server.pusher import ResultPusher
from server.queue import JobQueue
from server.streamer import TUIStreamerManager
from server.webhook import handle_webhook

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Background task intervals
# ---------------------------------------------------------------------------
QUEUE_POLL_INTERVAL = 5        # seconds between queue polls
LOG_CLEANUP_INTERVAL = 86400   # seconds between log cleanup runs (daily)
CREDENTIAL_REFRESH_INTERVAL = 3600  # seconds between credential refresh attempts


# ---------------------------------------------------------------------------
# Background tasks
# ---------------------------------------------------------------------------

async def queue_poller(app: web.Application) -> None:
    """Poll the job queue and execute the next pending job.

    Runs every ``QUEUE_POLL_INTERVAL`` seconds.  When the executor is
    idle, dequeues the next pending job, creates a TUI streamer for it,
    runs the job, and removes the streamer on completion.
    """
    executor: JobExecutor = app["executor"]
    queue: JobQueue = app["job_queue"]
    streamer_manager: TUIStreamerManager = app["streamer_manager"]
    jobs_dir: str = app["jobs_dir"]

    while True:
        try:
            if not executor.is_running():
                job = queue.dequeue()
                if job is not None:
                    logger.info("Queue poller picked up job %s", job.id)

                    # Create a TUI streamer for this job
                    typescript_path = os.path.join(
                        jobs_dir, job.id, "typescript.log"
                    )
                    streamer = streamer_manager.get_or_create(
                        job.id, typescript_path
                    )

                    # Start the stream loop as a background task
                    stream_task = asyncio.create_task(streamer.stream_loop())

                    try:
                        await executor.run(job)
                    finally:
                        # Stop and remove the streamer when the job finishes
                        streamer_manager.remove(job.id)
                        # Wait briefly for the stream loop to finish
                        try:
                            await asyncio.wait_for(stream_task, timeout=2.0)
                        except (asyncio.TimeoutError, Exception):
                            stream_task.cancel()
                            try:
                                await stream_task
                            except asyncio.CancelledError:
                                pass
        except asyncio.CancelledError:
            logger.info("Queue poller shutting down")
            return
        except Exception:
            logger.exception("Error in queue poller")

        await asyncio.sleep(QUEUE_POLL_INTERVAL)


def run_log_cleanup(completed_dir: Path, logs_dir: Path, retention_days: int) -> int:
    """Delete completed jobs older than the retention period.

    Scans the completed directory for job JSON files and deletes those
    whose ``completed_at`` timestamp exceeds the configured retention
    period.  For each expired job, both the JSON file and the preserved
    logs directory (``logs_dir / job.id``) are removed.

    Jobs without a ``completed_at`` timestamp or with malformed JSON are
    skipped with a warning — they are never deleted.

    Args:
        completed_dir: Path to the directory containing completed job
            JSON files.
        logs_dir: Path to the directory containing preserved log
            directories (one sub-directory per job ID).
        retention_days: Number of days to retain completed job data.

    Returns:
        The number of expired jobs that were cleaned up.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    logger.info(
        "Running log cleanup — deleting jobs completed before %s",
        cutoff.isoformat(),
    )
    deleted_count = 0

    if not completed_dir.exists():
        return deleted_count

    for filepath in sorted(completed_dir.iterdir()):
        if filepath.suffix != ".json":
            continue
        try:
            job = Job.from_json(filepath.read_text())
            if not job.completed_at:
                continue
            completed_dt = datetime.fromisoformat(job.completed_at)
            if completed_dt < cutoff:
                # Delete the job JSON
                filepath.unlink()
                logger.info("Deleted expired job file: %s", filepath.name)

                # Delete preserved logs
                job_logs = logs_dir / job.id
                if job_logs.exists():
                    shutil.rmtree(str(job_logs), ignore_errors=True)
                    logger.info(
                        "Deleted expired logs for job %s", job.id,
                    )
                deleted_count += 1
        except Exception:
            logger.warning(
                "Failed to process completed job file %s during cleanup",
                filepath.name,
            )

    return deleted_count


async def log_cleanup(app: web.Application) -> None:
    """Periodically delete completed jobs older than the retention period.

    Runs every ``LOG_CLEANUP_INTERVAL`` seconds (daily).  Delegates to
    :func:`run_log_cleanup` for the actual scan-and-delete logic.
    """
    config: Config = app["config"]
    retention_days = config.log_retention_days
    logs_dir = Path(config.logs_dir)
    completed_dir = Path(config.completed_dir)

    while True:
        try:
            run_log_cleanup(completed_dir, logs_dir, retention_days)
        except asyncio.CancelledError:
            logger.info("Log cleanup task shutting down")
            return
        except Exception:
            logger.exception("Error in log cleanup task")

        await asyncio.sleep(LOG_CLEANUP_INTERVAL)


def run_credential_refresh(
    profile: str,
    run_command: "Callable[[str], tuple[int, str]]",
    sleep_fn: "Callable[[float], None] | None" = None,
    max_attempts: int = 5,
) -> bool:
    """Attempt to refresh AWS SSO credentials with exponential backoff.

    Calls ``run_command`` with the AWS profile name to execute the
    credential refresh.  On failure, retries with exponential backoff
    (2^n seconds where n is the zero-based attempt index: 1, 2, 4, 8, 16)
    up to ``max_attempts`` times.  Each failure is logged, and a final
    error is logged when all attempts are exhausted.

    This is a synchronous, standalone function that is easy to unit-test.
    The async background task :func:`credential_refresh` delegates to it.

    Args:
        profile: The AWS SSO profile name to refresh.
        run_command: A callable that takes a profile string and returns
            a ``(return_code, error_message)`` tuple.  Return code 0
            indicates success; any other value indicates failure.
        sleep_fn: Optional callable used to sleep between retries.
            Accepts a float (seconds).  Defaults to :func:`time.sleep`.
        max_attempts: Maximum number of attempts before giving up.
            Defaults to 5.

    Returns:
        ``True`` if the credential refresh succeeded on any attempt,
        ``False`` if all attempts failed.
    """
    import time as _time

    if sleep_fn is None:
        sleep_fn = _time.sleep

    for attempt in range(max_attempts):
        try:
            rc, err_msg = run_command(profile)
        except Exception as exc:
            logger.warning(
                "SSO credential refresh attempt %d/%d error: %s",
                attempt + 1,
                max_attempts,
                exc,
            )
        else:
            if rc == 0:
                logger.info("SSO credential refresh succeeded")
                return True
            else:
                logger.warning(
                    "SSO credential refresh attempt %d/%d failed (rc=%d): %s",
                    attempt + 1,
                    max_attempts,
                    rc,
                    err_msg,
                )

        # Exponential backoff: 2^0=1, 2^1=2, 2^2=4, 2^3=8, 2^4=16
        if attempt < max_attempts - 1:
            backoff = 2 ** attempt
            logger.info(
                "Retrying credential refresh in %d seconds", backoff
            )
            sleep_fn(backoff)

    logger.error(
        "SSO credential refresh failed after %d attempts — "
        "will retry next cycle",
        max_attempts,
    )
    return False


async def credential_refresh(app: web.Application) -> None:
    """Periodically refresh AWS SSO credentials.

    Runs ``aws sso login --profile {profile}`` at regular intervals.
    On failure, retries with exponential backoff (2^n seconds) up to
    5 attempts before giving up until the next scheduled cycle.

    Delegates to :func:`run_credential_refresh` for the core retry logic.
    """
    config: Config = app["config"]
    profile = config.aws_profile

    async def _async_run_command(prof: str) -> tuple[int, str]:
        """Run ``aws sso login`` as an async subprocess."""
        proc = await asyncio.create_subprocess_exec(
            "aws", "sso", "login", "--profile", prof,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        _stdout, stderr = await asyncio.wait_for(
            proc.communicate(), timeout=120
        )
        err_msg = stderr.decode("utf-8", errors="replace").strip()
        return proc.returncode, err_msg

    def _sync_run_command(prof: str) -> tuple[int, str]:
        """Synchronous wrapper around the async command for run_credential_refresh."""
        loop = asyncio.get_event_loop()
        return loop.run_until_complete(_async_run_command(prof))

    while True:
        try:
            # Run the refresh in the event loop using the async subprocess
            # We use run_in_executor to avoid blocking, but since the
            # core function needs sync sleep, we adapt it for async.
            success = False
            max_retries = 5
            for attempt in range(max_retries):
                try:
                    rc, err_msg = await _async_run_command(profile)
                    if rc == 0:
                        logger.info("SSO credential refresh succeeded")
                        success = True
                        break
                    else:
                        logger.warning(
                            "SSO credential refresh attempt %d/%d failed (rc=%d): %s",
                            attempt + 1,
                            max_retries,
                            rc,
                            err_msg,
                        )
                except asyncio.TimeoutError:
                    logger.warning(
                        "SSO credential refresh attempt %d/%d timed out",
                        attempt + 1,
                        max_retries,
                    )
                except Exception as exc:
                    logger.warning(
                        "SSO credential refresh attempt %d/%d error: %s",
                        attempt + 1,
                        max_retries,
                        exc,
                    )

                if attempt < max_retries - 1:
                    backoff = 2 ** attempt
                    logger.info(
                        "Retrying credential refresh in %d seconds", backoff
                    )
                    await asyncio.sleep(backoff)

            if not success:
                logger.error(
                    "SSO credential refresh failed after %d attempts — "
                    "will retry next cycle",
                    max_retries,
                )
        except asyncio.CancelledError:
            logger.info("Credential refresh task shutting down")
            return
        except Exception:
            logger.exception("Error in credential refresh task")

        await asyncio.sleep(CREDENTIAL_REFRESH_INTERVAL)


# ---------------------------------------------------------------------------
# Application lifecycle
# ---------------------------------------------------------------------------

async def start_background_tasks(app: web.Application) -> None:
    """Start all background tasks when the application starts."""
    app["queue_poller_task"] = asyncio.create_task(queue_poller(app))
    app["log_cleanup_task"] = asyncio.create_task(log_cleanup(app))
    app["credential_refresh_task"] = asyncio.create_task(credential_refresh(app))
    logger.info("Background tasks started")


async def cleanup_background_tasks(app: web.Application) -> None:
    """Cancel all background tasks when the application shuts down."""
    for task_name in ("queue_poller_task", "log_cleanup_task", "credential_refresh_task"):
        task = app.get(task_name)
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
    logger.info("Background tasks stopped")


def create_app(config: Config) -> web.Application:
    """Create and configure the aiohttp application.

    Initialises all components, registers routes, and sets up
    background task lifecycle hooks.

    Args:
        config: Validated service configuration.

    Returns:
        A fully configured :class:`aiohttp.web.Application`.
    """
    app = web.Application()

    # Initialise components
    lock_file = str(Path(config.queue_dir).parent / ".queue-lock")
    queue = JobQueue(
        queue_dir=config.queue_dir,
        completed_dir=config.completed_dir,
        jobs_dir=config.jobs_dir,
        lock_file=lock_file,
    )
    pusher = ResultPusher(btb_path=config.btb_path)
    executor = JobExecutor(
        btb_path=config.btb_path,
        jobs_dir=config.jobs_dir,
        logs_dir=config.logs_dir,
        pusher=pusher,
        queue=queue,
        job_timeout=config.job_timeout,
        github_token=config.github_token,
    )
    streamer_manager = TUIStreamerManager()

    # Store shared state on the app for request handlers
    app["config"] = config
    app["job_queue"] = queue
    app["executor"] = executor
    app["streamer_manager"] = streamer_manager
    app["webhook_secret"] = config.webhook_secret
    app["github_token"] = config.github_token
    app["logs_dir"] = config.logs_dir
    app["jobs_dir"] = config.jobs_dir

    # Register routes
    app.router.add_post("/webhook", handle_webhook)
    setup_routes(app)

    # Register background task lifecycle
    app.on_startup.append(start_background_tasks)
    app.on_cleanup.append(cleanup_background_tasks)

    return app


def create_ssl_context(config: Config) -> Optional[ssl.SSLContext]:
    """Create an SSL context from the configured certificate and key.

    Args:
        config: Service configuration with TLS cert/key paths.

    Returns:
        An :class:`ssl.SSLContext` if both cert and key exist, or None
        if TLS files are not found (falls back to plain HTTP).
    """
    cert_path = Path(config.tls_cert)
    key_path = Path(config.tls_key)

    if not cert_path.exists() or not key_path.exists():
        logger.warning(
            "TLS certificate or key not found (cert=%s, key=%s) — "
            "running without TLS",
            config.tls_cert,
            config.tls_key,
        )
        return None

    ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ssl_ctx.load_cert_chain(str(cert_path), str(key_path))
    logger.info("TLS configured with cert=%s", config.tls_cert)
    return ssl_ctx


def main() -> None:
    """Start the BTB Service."""
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    # Load configuration
    config_path = "/etc/btb-service/config.env"
    if len(sys.argv) > 1:
        config_path = sys.argv[1]

    try:
        config = load_config(config_path)
    except ConfigError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    logger.info("BTB Service starting with config from %s", config_path)

    # Create the application
    app = create_app(config)

    # Set up TLS
    ssl_ctx = create_ssl_context(config)

    # Run the server
    web.run_app(
        app,
        host="0.0.0.0",
        port=config.port,
        ssl_context=ssl_ctx,
    )


if __name__ == "__main__":
    main()
