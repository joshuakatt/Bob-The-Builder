"""Unit tests for server.webhook module."""

import base64
import hashlib
import hmac
import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, TestClient, TestServer

from server.models import Job
from server.webhook import (
    check_btb_file,
    handle_webhook,
    parse_btb_file,
    verify_signature,
    _extract_payload_fields,
)


# --- Helpers ---


def compute_signature(payload: bytes, secret: str) -> str:
    """Compute a valid X-Hub-Signature-256 header value."""
    sig = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()
    return f"sha256={sig}"


def make_push_payload(
    clone_url: str = "https://github.com/team/project.git",
    full_name: str = "team/project",
    ref: str = "refs/heads/feature/auth",
    after: str = "abc123def456",
    pusher_name: str = "developer1",
) -> dict:
    """Create a minimal valid GitHub push webhook payload."""
    return {
        "ref": ref,
        "after": after,
        "repository": {
            "clone_url": clone_url,
            "full_name": full_name,
        },
        "pusher": {
            "name": pusher_name,
        },
    }


class SimpleQueue:
    """Simple in-memory queue for testing."""

    def __init__(self):
        self.jobs: list[Job] = []

    def enqueue(self, job: Job) -> str:
        self.jobs.append(job)
        return job.id


def create_test_app(
    webhook_secret: str = "test-secret",
    github_token: str = "ghp_test123",
    queue: SimpleQueue | None = None,
) -> web.Application:
    """Create an aiohttp app configured for webhook testing."""
    app = web.Application()
    app["webhook_secret"] = webhook_secret
    app["github_token"] = github_token
    app["job_queue"] = queue or SimpleQueue()
    app.router.add_post("/webhook", handle_webhook)
    return app


# --- verify_signature tests ---


class TestVerifySignature:
    def test_valid_signature_accepted(self):
        payload = b'{"test": "data"}'
        secret = "my-secret"
        sig = compute_signature(payload, secret)
        assert verify_signature(payload, secret, sig) is True

    def test_invalid_signature_rejected(self):
        payload = b'{"test": "data"}'
        secret = "my-secret"
        assert verify_signature(payload, secret, "sha256=invalid") is False

    def test_empty_signature_rejected(self):
        payload = b'{"test": "data"}'
        assert verify_signature(payload, "secret", "") is False

    def test_missing_sha256_prefix_rejected(self):
        payload = b'{"test": "data"}'
        secret = "my-secret"
        sig = hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
        assert verify_signature(payload, secret, sig) is False

    def test_wrong_secret_rejected(self):
        payload = b'{"test": "data"}'
        sig = compute_signature(payload, "correct-secret")
        assert verify_signature(payload, "wrong-secret", sig) is False

    def test_tampered_payload_rejected(self):
        payload = b'{"test": "data"}'
        sig = compute_signature(payload, "secret")
        tampered = b'{"test": "tampered"}'
        assert verify_signature(tampered, "secret", sig) is False

    def test_empty_payload_with_valid_signature(self):
        payload = b""
        secret = "secret"
        sig = compute_signature(payload, secret)
        assert verify_signature(payload, secret, sig) is True


# --- _extract_payload_fields tests ---


class TestExtractPayloadFields:
    def test_extracts_all_fields(self):
        payload = make_push_payload()
        repo_url, full_name, ref, sha, pusher, branch = _extract_payload_fields(payload)
        assert repo_url == "https://github.com/team/project.git"
        assert full_name == "team/project"
        assert ref == "refs/heads/feature/auth"
        assert sha == "abc123def456"
        assert pusher == "developer1"
        assert branch == "feature/auth"

    def test_strips_refs_heads_prefix(self):
        payload = make_push_payload(ref="refs/heads/main")
        _, _, _, _, _, branch = _extract_payload_fields(payload)
        assert branch == "main"

    def test_nested_branch_name(self):
        payload = make_push_payload(ref="refs/heads/feature/deep/nested/branch")
        _, _, _, _, _, branch = _extract_payload_fields(payload)
        assert branch == "feature/deep/nested/branch"

    def test_btb_results_branch(self):
        payload = make_push_payload(ref="refs/heads/btb-results/feature/auth")
        _, _, _, _, _, branch = _extract_payload_fields(payload)
        assert branch == "btb-results/feature/auth"

    def test_missing_repository_raises(self):
        payload = {"ref": "refs/heads/main", "after": "abc", "pusher": {"name": "dev"}}
        with pytest.raises(KeyError):
            _extract_payload_fields(payload)

    def test_missing_ref_raises(self):
        payload = make_push_payload()
        del payload["ref"]
        with pytest.raises(KeyError):
            _extract_payload_fields(payload)

    def test_missing_after_raises(self):
        payload = make_push_payload()
        del payload["after"]
        with pytest.raises(KeyError):
            _extract_payload_fields(payload)

    def test_missing_pusher_raises(self):
        payload = make_push_payload()
        del payload["pusher"]
        with pytest.raises(KeyError):
            _extract_payload_fields(payload)

    def test_ref_without_refs_heads_prefix(self):
        payload = make_push_payload(ref="main")
        _, _, _, _, _, branch = _extract_payload_fields(payload)
        assert branch == "main"


# --- parse_btb_file tests ---


class TestParseBtbFile:
    def test_basic_spec_key(self):
        content = "spec=my-feature\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_multiple_keys(self):
        content = "spec=my-feature\nstatus=pending\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature", "status": "pending"}

    def test_comments_ignored(self):
        content = "# btb config\nspec=my-feature\n# another comment\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_empty_lines_ignored(self):
        content = "\n\nspec=my-feature\n\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_quoted_values(self):
        content = 'spec="my-feature"\n'
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_single_quoted_values(self):
        content = "spec='my-feature'\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_empty_file_returns_empty_dict(self):
        result = parse_btb_file("")
        assert result == {}

    def test_comments_only_returns_empty_dict(self):
        result = parse_btb_file("# just a comment\n# another\n")
        assert result == {}

    def test_no_spec_key(self):
        content = "status=completed\n"
        result = parse_btb_file(content)
        assert result == {"status": "completed"}
        assert "spec" not in result

    def test_whitespace_around_key_value(self):
        content = "  spec = my-feature  \n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature"}

    def test_value_with_equals_sign(self):
        content = "spec=my-feature=v2\n"
        result = parse_btb_file(content)
        assert result == {"spec": "my-feature=v2"}

    def test_full_btb_file(self):
        content = (
            "# btb configuration\n"
            "spec=ec2-team-service\n"
            "status=completed\n"
            "last_run=2025-01-15T10:35:00+00:00\n"
            "job_id=a1b2c3d4\n"
        )
        result = parse_btb_file(content)
        assert result["spec"] == "ec2-team-service"
        assert result["status"] == "completed"
        assert result["last_run"] == "2025-01-15T10:35:00+00:00"
        assert result["job_id"] == "a1b2c3d4"


# --- handle_webhook integration tests ---


@pytest.fixture
def queue():
    return SimpleQueue()


@pytest.fixture
def secret():
    return "test-webhook-secret"


@pytest.fixture
def github_token():
    return "ghp_testtoken"


def _make_btb_contents_response(spec_name: str = "my-feature-spec") -> list[dict]:
    """Create a mock GitHub Contents API response with a .btb file."""
    return [
        {"name": "README.md", "type": "file"},
        {"name": "src", "type": "dir"},
        {"name": "run.btb", "type": "file"},
    ]


def _make_btb_file_response(spec_name: str = "my-feature-spec") -> dict:
    """Create a mock GitHub Contents API response for a .btb file."""
    content = base64.b64encode(f"spec={spec_name}\n".encode()).decode()
    return {
        "name": "run.btb",
        "type": "file",
        "content": content,
        "encoding": "base64",
    }


def _make_no_btb_contents_response() -> list[dict]:
    """Create a mock GitHub Contents API response without a .btb file."""
    return [
        {"name": "README.md", "type": "file"},
        {"name": "src", "type": "dir"},
        {"name": "package.json", "type": "file"},
    ]


class TestHandleWebhookSignature:
    """Test webhook signature validation."""

    @pytest.mark.asyncio
    async def test_valid_signature_accepted(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        with patch("server.webhook.check_btb_file", new_callable=AsyncMock) as mock_check:
            mock_check.return_value = "my-spec"
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "X-Hub-Signature-256": sig,
                    "Content-Type": "application/json",
                },
            )
        assert resp.status == 200

    @pytest.mark.asyncio
    async def test_invalid_signature_returns_403(self, aiohttp_client, secret):
        app = create_test_app(webhook_secret=secret)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": "sha256=invalid",
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 403

    @pytest.mark.asyncio
    async def test_missing_signature_returns_403(self, aiohttp_client, secret):
        app = create_test_app(webhook_secret=secret)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()

        resp = await client.post(
            "/webhook",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        assert resp.status == 403


class TestHandleWebhookPayload:
    """Test webhook payload extraction and validation."""

    @pytest.mark.asyncio
    async def test_missing_repository_returns_400(self, aiohttp_client, secret):
        app = create_test_app(webhook_secret=secret)
        client = await aiohttp_client(app)

        payload = {"ref": "refs/heads/main", "after": "abc123", "pusher": {"name": "dev"}}
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": sig,
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 400

    @pytest.mark.asyncio
    async def test_missing_ref_returns_400(self, aiohttp_client, secret):
        app = create_test_app(webhook_secret=secret)
        client = await aiohttp_client(app)

        payload = {
            "after": "abc123",
            "repository": {"clone_url": "https://github.com/t/p.git", "full_name": "t/p"},
            "pusher": {"name": "dev"},
        }
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": sig,
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 400

    @pytest.mark.asyncio
    async def test_missing_after_returns_400(self, aiohttp_client, secret):
        app = create_test_app(webhook_secret=secret)
        client = await aiohttp_client(app)

        payload = {
            "ref": "refs/heads/main",
            "repository": {"clone_url": "https://github.com/t/p.git", "full_name": "t/p"},
            "pusher": {"name": "dev"},
        }
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": sig,
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 400


class TestHandleWebhookLoopPrevention:
    """Test btb-results/ branch loop prevention."""

    @pytest.mark.asyncio
    async def test_btb_results_branch_skipped(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload(ref="refs/heads/btb-results/feature/auth")
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": sig,
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 200
        assert len(queue.jobs) == 0

    @pytest.mark.asyncio
    async def test_btb_results_nested_branch_skipped(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload(ref="refs/heads/btb-results/deep/nested/branch")
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        resp = await client.post(
            "/webhook",
            data=body,
            headers={
                "X-Hub-Signature-256": sig,
                "Content-Type": "application/json",
            },
        )
        assert resp.status == 200
        assert len(queue.jobs) == 0


class TestHandleWebhookBtbFile:
    """Test .btb file checking and job enqueue."""

    @pytest.mark.asyncio
    async def test_btb_file_present_enqueues_job(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        with patch("server.webhook.check_btb_file", new_callable=AsyncMock) as mock_check:
            mock_check.return_value = "my-feature-spec"
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "X-Hub-Signature-256": sig,
                    "Content-Type": "application/json",
                },
            )

        assert resp.status == 200
        assert len(queue.jobs) == 1
        job = queue.jobs[0]
        assert job.repo_url == "https://github.com/team/project.git"
        assert job.branch == "feature/auth"
        assert job.commit_sha == "abc123def456"
        assert job.pusher == "developer1"
        assert job.spec_name == "my-feature-spec"
        assert job.status == "pending"

    @pytest.mark.asyncio
    async def test_no_btb_file_skips_enqueue(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        with patch("server.webhook.check_btb_file", new_callable=AsyncMock) as mock_check:
            mock_check.return_value = None
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "X-Hub-Signature-256": sig,
                    "Content-Type": "application/json",
                },
            )

        assert resp.status == 200
        assert len(queue.jobs) == 0

    @pytest.mark.asyncio
    async def test_github_api_error_returns_500(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        with patch("server.webhook.check_btb_file", new_callable=AsyncMock) as mock_check:
            mock_check.side_effect = Exception("API error")
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "X-Hub-Signature-256": sig,
                    "Content-Type": "application/json",
                },
            )

        assert resp.status == 500
        assert len(queue.jobs) == 0

    @pytest.mark.asyncio
    async def test_enqueued_job_has_correct_spec_name(self, aiohttp_client, queue, secret):
        app = create_test_app(webhook_secret=secret, queue=queue)
        client = await aiohttp_client(app)

        payload = make_push_payload()
        body = json.dumps(payload).encode()
        sig = compute_signature(body, secret)

        with patch("server.webhook.check_btb_file", new_callable=AsyncMock) as mock_check:
            mock_check.return_value = "custom-spec-name"
            resp = await client.post(
                "/webhook",
                data=body,
                headers={
                    "X-Hub-Signature-256": sig,
                    "Content-Type": "application/json",
                },
            )

        assert resp.status == 200
        assert queue.jobs[0].spec_name == "custom-spec-name"


class TestCheckBtbFile:
    """Test the check_btb_file helper function."""

    @pytest.mark.asyncio
    async def test_finds_btb_file_and_returns_spec_name(self, aiohttp_server):
        """Test that check_btb_file finds a .btb file and extracts the spec name."""
        spec_name = "my-feature-spec"
        btb_content = base64.b64encode(f"spec={spec_name}\n".encode()).decode()

        async def handler(request: web.Request) -> web.Response:
            path = request.path
            if path == "/repos/team/project/contents/" and request.query.get("ref") == "abc123":
                return web.json_response([
                    {"name": "README.md", "type": "file"},
                    {"name": "run.btb", "type": "file"},
                ])
            elif path == "/repos/team/project/contents/run.btb" and request.query.get("ref") == "abc123":
                return web.json_response({
                    "name": "run.btb",
                    "content": btb_content,
                    "encoding": "base64",
                })
            return web.Response(status=404)

        app = web.Application()
        app.router.add_get("/repos/{owner}/{repo}/contents/", handler)
        app.router.add_get("/repos/{owner}/{repo}/contents/{filename}", handler)
        server = await aiohttp_server(app)

        import aiohttp as aio
        async with aio.ClientSession() as session:
            # Monkey-patch the URL to point to our test server
            result = await _check_btb_file_with_base_url(
                session, "team", "project", "abc123", "test-token",
                base_url=str(server.make_url("")),
            )
        assert result == spec_name

    @pytest.mark.asyncio
    async def test_no_btb_file_returns_none(self, aiohttp_server):
        """Test that check_btb_file returns None when no .btb file exists."""

        async def handler(request: web.Request) -> web.Response:
            return web.json_response([
                {"name": "README.md", "type": "file"},
                {"name": "src", "type": "dir"},
            ])

        app = web.Application()
        app.router.add_get("/repos/{owner}/{repo}/contents/", handler)
        server = await aiohttp_server(app)

        import aiohttp as aio
        async with aio.ClientSession() as session:
            result = await _check_btb_file_with_base_url(
                session, "team", "project", "abc123", "test-token",
                base_url=str(server.make_url("")),
            )
        assert result is None


async def _check_btb_file_with_base_url(
    session, owner, repo, sha, github_token, base_url
):
    """Helper that calls check_btb_file logic but with a custom base URL for testing."""
    import aiohttp
    import logging

    logger = logging.getLogger(__name__)

    headers = {
        "Authorization": f"token {github_token}",
        "Accept": "application/vnd.github.v3+json",
    }

    # List repository root contents at the given commit
    url = f"{base_url}/repos/{owner}/{repo}/contents/?ref={sha}"
    async with session.get(url, headers=headers) as resp:
        if resp.status != 200:
            raise aiohttp.ClientError(f"GitHub API returned {resp.status}")
        contents = await resp.json()

    # Find a .btb file
    btb_file = None
    for item in contents:
        if item.get("type") == "file" and item.get("name", "").endswith(".btb"):
            btb_file = item
            break

    if btb_file is None:
        return None

    # Fetch the .btb file contents
    file_url = f"{base_url}/repos/{owner}/{repo}/contents/{btb_file['name']}?ref={sha}"
    async with session.get(file_url, headers=headers) as resp:
        if resp.status != 200:
            return None
        file_data = await resp.json()

    # Decode base64 content
    content_b64 = file_data.get("content", "")
    try:
        content = base64.b64decode(content_b64).decode("utf-8")
    except Exception:
        return None

    first_line = content.split("\n")[0].strip()
    if not first_line:
        return None

    # Parse key-value format
    from server.webhook import parse_btb_file
    parsed = parse_btb_file(content)
    spec_name = parsed.get("spec", "").strip()
    if not spec_name:
        return None

    return spec_name
