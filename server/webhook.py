"""Webhook receiver for GitHub push events.

Validates webhook signatures, extracts push payload data, checks for .btb files
via the GitHub Contents API, and enqueues jobs when appropriate.
"""

import base64
import hashlib
import hmac
import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Optional, Protocol

import aiohttp
from aiohttp import web

from server.models import Job

logger = logging.getLogger(__name__)


class JobEnqueuer(Protocol):
    """Protocol for job queue enqueue capability.

    Any object that implements enqueue(job) -> str can be used.
    """

    def enqueue(self, job: Job) -> str: ...


def verify_signature(payload_body: bytes, secret: str, signature_header: str) -> bool:
    """Verify the GitHub webhook HMAC-SHA256 signature.

    Args:
        payload_body: Raw request body bytes.
        secret: The shared webhook secret.
        signature_header: The X-Hub-Signature-256 header value (e.g. "sha256=abc...").

    Returns:
        True if the signature is valid, False otherwise.
    """
    if not signature_header:
        return False

    if not signature_header.startswith("sha256="):
        return False

    expected_sig = signature_header[len("sha256="):]
    computed = hmac.new(
        secret.encode("utf-8"),
        payload_body,
        hashlib.sha256,
    ).hexdigest()

    return hmac.compare_digest(computed, expected_sig)


def parse_btb_file(content: str) -> dict[str, str]:
    """Parse a .btb file's key-value content into a dictionary.

    Format: KEY=value per line. Lines starting with # are comments.
    Empty lines and lines with only whitespace are ignored.
    Values may optionally be quoted with single or double quotes.

    Args:
        content: The decoded text content of the .btb file.

    Returns:
        Dictionary mapping keys to string values.
    """
    result: dict[str, str] = {}
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip()
        # Strip optional quotes
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        if key:
            result[key] = value
    return result


class BtbFileResult:
    """Result of checking a .btb file."""
    
    def __init__(
        self,
        spec_name: Optional[str] = None,
        status: Optional[str] = None,
        skip_reason: Optional[str] = None,
    ):
        self.spec_name = spec_name
        self.status = status
        self.skip_reason = skip_reason


async def check_btb_file(
    session: aiohttp.ClientSession,
    owner: str,
    repo: str,
    sha: str,
    github_token: str,
) -> BtbFileResult:
    """Check for a .btb file at the repository root and return its spec name.

    Uses the GitHub Contents API to list the repository root at the given commit,
    looks for any file matching *.btb, fetches its contents, and returns the
    spec name and status.

    If the .btb file has status=completed, the spec is considered done and
    should not be re-run.

    Args:
        session: An aiohttp ClientSession for making HTTP requests.
        owner: Repository owner (user or org).
        repo: Repository name.
        sha: Commit SHA to check.
        github_token: GitHub personal access token for API authentication.

    Returns:
        BtbFileResult with spec_name if a .btb file is found and should be run,
        or with skip_reason if the job should be skipped.

    Raises:
        aiohttp.ClientError: If the GitHub API request fails.
    """
    headers = {
        "Authorization": f"token {github_token}",
        "Accept": "application/vnd.github.v3+json",
    }

    # List repository root contents at the given commit
    url = f"https://api.github.com/repos/{owner}/{repo}/contents/?ref={sha}"
    async with session.get(url, headers=headers) as resp:
        if resp.status != 200:
            logger.error(
                "GitHub API error listing repo contents: %d %s",
                resp.status,
                await resp.text(),
            )
            raise aiohttp.ClientError(
                f"GitHub API returned {resp.status} listing repo contents"
            )
        contents = await resp.json()

    # Find a .btb file
    btb_file = None
    for item in contents:
        if item.get("type") == "file" and item.get("name", "").endswith(".btb"):
            btb_file = item
            break

    if btb_file is None:
        return BtbFileResult(skip_reason="no .btb file")

    # Fetch the .btb file contents
    file_url = (
        f"https://api.github.com/repos/{owner}/{repo}"
        f"/contents/{btb_file['name']}?ref={sha}"
    )
    async with session.get(file_url, headers=headers) as resp:
        if resp.status != 200:
            logger.warning(
                "GitHub API error fetching .btb file: %d %s",
                resp.status,
                await resp.text(),
            )
            return BtbFileResult(skip_reason="failed to fetch .btb file")
        file_data = await resp.json()

    # Decode base64 content
    content_b64 = file_data.get("content", "")
    try:
        content = base64.b64decode(content_b64).decode("utf-8")
    except Exception:
        logger.warning("Failed to decode .btb file contents")
        return BtbFileResult(skip_reason="failed to decode .btb file")

    # Parse the .btb file
    parsed = parse_btb_file(content)
    spec_name = parsed.get("spec", "").strip()
    status = parsed.get("status", "").strip()

    if not spec_name:
        logger.warning(".btb file has no 'spec' key or it is empty")
        return BtbFileResult(skip_reason="no spec key in .btb file")

    # Check if spec is already completed
    if status == "completed":
        logger.info(
            "Spec '%s' already completed (status=completed in .btb file)",
            spec_name,
        )
        return BtbFileResult(
            spec_name=spec_name,
            status=status,
            skip_reason=f"spec '{spec_name}' already completed",
        )

    return BtbFileResult(spec_name=spec_name, status=status)


def _extract_payload_fields(payload: dict[str, Any]) -> tuple[str, str, str, str, str, str]:
    """Extract required fields from a GitHub push webhook payload.

    Args:
        payload: Parsed JSON payload from GitHub.

    Returns:
        Tuple of (repo_url, full_name, ref, commit_sha, pusher, branch).

    Raises:
        KeyError: If any required field is missing.
        ValueError: If the ref format is unexpected.
    """
    repo = payload["repository"]
    repo_url = repo["clone_url"]
    full_name = repo["full_name"]
    ref = payload["ref"]
    commit_sha = payload["after"]
    pusher = payload["pusher"]["name"]

    # Extract branch name from ref (strip refs/heads/ prefix)
    if ref.startswith("refs/heads/"):
        branch = ref[len("refs/heads/"):]
    else:
        branch = ref

    return repo_url, full_name, ref, commit_sha, pusher, branch


async def handle_webhook(request: web.Request) -> web.Response:
    """Handle incoming GitHub webhook events.

    Validates the webhook signature, checks event type, extracts push payload data,
    checks for btb-results/ branch prefix (loop prevention),
    checks for .btb file via GitHub API, and enqueues a job if appropriate.

    Expected app state:
        request.app["webhook_secret"]: str - HMAC secret for signature validation
        request.app["github_token"]: str - GitHub API token
        request.app["job_queue"]: JobEnqueuer - Queue to enqueue jobs into

    Returns:
        200 on success or skip, 403 on bad signature, 400 on bad payload.
    """
    # Read raw body for signature verification
    body = await request.read()

    # Validate signature
    webhook_secret = request.app["webhook_secret"]
    signature = request.headers.get("X-Hub-Signature-256", "")

    if not verify_signature(body, webhook_secret, signature):
        logger.warning("Invalid webhook signature from %s", request.remote)
        return web.Response(status=403, text="Invalid signature")

    # Check event type - only process push events
    event_type = request.headers.get("X-GitHub-Event", "")
    
    # Handle ping event (sent when webhook is first created)
    if event_type == "ping":
        logger.info("Received ping event - webhook is configured correctly")
        return web.Response(status=200, text="Pong")
    
    # Skip non-push events
    if event_type != "push":
        logger.debug("Skipping non-push event: %s", event_type)
        return web.Response(status=200, text=f"Skipped: {event_type} event")

    # Parse JSON payload
    try:
        payload = await request.json()
    except Exception:
        logger.error("Failed to parse webhook payload as JSON")
        return web.Response(status=400, text="Invalid JSON payload")

    # Skip branch/tag deletion events (after field is all zeros)
    if payload.get("after") == "0000000000000000000000000000000000000000":
        logger.debug("Skipping branch/tag deletion event")
        return web.Response(status=200, text="Skipped: deletion event")

    # Extract required fields
    try:
        repo_url, full_name, ref, commit_sha, pusher, branch = _extract_payload_fields(payload)
    except (KeyError, TypeError) as e:
        logger.error("Missing required field in webhook payload: %s", e)
        return web.Response(status=400, text=f"Missing required field: {e}")

    # Loop prevention: skip btb-results/ branches
    if branch.startswith("btb-results/"):
        logger.debug("Skipping push to results branch: %s", branch)
        return web.Response(status=200, text="Skipped: results branch")

    # Check for .btb file via GitHub API
    github_token = request.app["github_token"]
    owner, repo = full_name.split("/", 1)

    try:
        async with aiohttp.ClientSession() as session:
            btb_result = await check_btb_file(session, owner, repo, commit_sha, github_token)
    except Exception as e:
        logger.error("GitHub API error checking .btb file: %s", e)
        return web.Response(status=500, text="GitHub API error")

    if btb_result.skip_reason:
        logger.debug("Skipping job for %s: %s", full_name, btb_result.skip_reason)
        return web.Response(status=200, text=f"Skipped: {btb_result.skip_reason}")

    spec_name = btb_result.spec_name

    # Create and enqueue job
    job = Job(
        id=str(uuid.uuid4()),
        repo_url=repo_url,
        branch=branch,
        commit_sha=commit_sha,
        pusher=pusher,
        spec_name=spec_name,
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
        retry_of=None,
    )

    queue = request.app["job_queue"]
    job_id = queue.enqueue(job)
    logger.info(
        "Enqueued job %s for %s branch=%s spec=%s",
        job_id, full_name, branch, spec_name,
    )

    return web.Response(status=200, text=f"Job enqueued: {job_id}")
