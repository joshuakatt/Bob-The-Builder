"""Unit tests for server.pusher module.

Tests use real git repos created in tmp_path:
- A bare repo acts as the remote (simulating GitHub)
- A cloned working repo simulates the job's working directory
"""

import asyncio
import os
import subprocess
from pathlib import Path

import pytest

from server.models import Job, PushResult
from server.pusher import ResultPusher, update_btb_file


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
        status="completed",
        submitted_at="2025-01-15T10:30:00Z",
        started_at="2025-01-15T10:31:00Z",
        completed_at="2025-01-15T10:45:00Z",
        exit_code=0,
        error=None,
        results_branch=None,
        push_success=None,
        push_error=None,
        cleanup_success=None,
        retry_of=None,
    )
    defaults.update(overrides)
    return Job(**defaults)


def run_git(args: list[str], cwd: str) -> str:
    """Run a git command synchronously and return stdout."""
    result = subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def setup_git_env(env_override: dict | None = None) -> dict:
    """Return an env dict with git author/committer set for tests."""
    env = os.environ.copy()
    env["GIT_AUTHOR_NAME"] = "Test"
    env["GIT_AUTHOR_EMAIL"] = "test@test.com"
    env["GIT_COMMITTER_NAME"] = "Test"
    env["GIT_COMMITTER_EMAIL"] = "test@test.com"
    if env_override:
        env.update(env_override)
    return env


@pytest.fixture
def git_repos(tmp_path):
    """Create a bare remote repo and a cloned working repo.

    Returns a tuple of (remote_path, clone_path).
    The clone has one initial commit so push operations work.
    """
    remote_path = str(tmp_path / "remote.git")
    clone_path = str(tmp_path / "repo")
    env = setup_git_env()

    # Create bare remote
    subprocess.run(["git", "init", "--bare", remote_path], check=True, env=env,
                    capture_output=True)

    # Clone it (creates an empty repo with origin set)
    subprocess.run(["git", "clone", remote_path, clone_path], check=True, env=env,
                    capture_output=True)

    # Configure user in the clone
    subprocess.run(["git", "config", "user.email", "test@test.com"],
                    cwd=clone_path, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"],
                    cwd=clone_path, check=True, capture_output=True)

    # Create an initial commit so we have a HEAD
    initial_file = Path(clone_path) / "README.md"
    initial_file.write_text("# Test Project\n")
    subprocess.run(["git", "add", "-A"], cwd=clone_path, check=True, env=env,
                    capture_output=True)
    subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=clone_path,
                    check=True, env=env, capture_output=True)

    # Push initial commit to remote
    subprocess.run(["git", "push", "origin", "HEAD:refs/heads/main"],
                    cwd=clone_path, check=True, env=env, capture_output=True)

    return remote_path, clone_path


@pytest.fixture
def pusher() -> ResultPusher:
    """Create a ResultPusher instance."""
    return ResultPusher()


# --- Results branch name computation ---


class TestComputeResultsBranch:
    def test_simple_branch(self):
        assert ResultPusher.compute_results_branch("main") == "btb-results/main"

    def test_feature_branch_with_slash(self):
        assert (
            ResultPusher.compute_results_branch("feature/auth")
            == "btb-results/feature/auth"
        )

    def test_nested_branch_with_multiple_slashes(self):
        assert (
            ResultPusher.compute_results_branch("feature/auth/login")
            == "btb-results/feature/auth/login"
        )

    def test_branch_with_special_characters(self):
        assert (
            ResultPusher.compute_results_branch("fix/bug-123_hotfix")
            == "btb-results/fix/bug-123_hotfix"
        )

    def test_empty_branch(self):
        assert ResultPusher.compute_results_branch("") == "btb-results/"


# --- Successful push ---


class TestPushResultsSuccess:
    def test_push_with_changes(self, git_repos, pusher):
        """Push succeeds when there are new changes to commit."""
        remote_path, clone_path = git_repos
        job = make_job(branch="main")

        # Create a new file (simulating btb output)
        new_file = Path(clone_path) / "btb-output.txt"
        new_file.write_text("btb did some work\n")

        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is True
        assert result.branch == "btb-results/main"
        assert result.error is None

        # Verify the branch exists on the remote
        branches = run_git(["branch", "--list"], cwd=remote_path)
        assert "btb-results/main" in branches

    def test_push_creates_correct_commit_message(self, git_repos, pusher):
        """The commit message includes spec name and job ID."""
        remote_path, clone_path = git_repos
        job = make_job(job_id="abc-123", spec_name="my-spec", branch="main")

        new_file = Path(clone_path) / "output.txt"
        new_file.write_text("results\n")

        asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        # Check the commit message on the results branch in the remote
        log = run_git(
            ["log", "--format=%s", "-1", "btb-results/main"],
            cwd=remote_path,
        )
        assert "my-spec" in log
        assert "abc-123" in log

    def test_push_with_feature_branch(self, git_repos, pusher):
        """Push works correctly with branch names containing slashes."""
        remote_path, clone_path = git_repos
        job = make_job(branch="feature/auth")

        new_file = Path(clone_path) / "result.txt"
        new_file.write_text("feature work\n")

        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is True
        assert result.branch == "btb-results/feature/auth"
        assert result.error is None


# --- Push with no changes ---


class TestPushNoChanges:
    def test_push_with_no_changes(self, git_repos, pusher):
        """Push succeeds even when there are no new changes to commit."""
        _remote_path, clone_path = git_repos
        job = make_job(branch="main")

        # Don't create any new files — no changes to commit
        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is True
        assert result.branch == "btb-results/main"
        assert result.error is None


# --- Push failure ---


class TestPushFailure:
    def test_push_to_invalid_remote(self, tmp_path, pusher):
        """Push fails gracefully when the remote is unreachable."""
        clone_path = str(tmp_path / "bad-repo")
        env = setup_git_env()

        # Create a repo with a bogus remote
        subprocess.run(["git", "init", clone_path], check=True, env=env,
                        capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@test.com"],
                        cwd=clone_path, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"],
                        cwd=clone_path, check=True, capture_output=True)

        # Create an initial commit
        readme = Path(clone_path) / "README.md"
        readme.write_text("test\n")
        subprocess.run(["git", "add", "-A"], cwd=clone_path, check=True, env=env,
                        capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=clone_path,
                        check=True, env=env, capture_output=True)

        # Set a remote that doesn't exist
        subprocess.run(
            ["git", "remote", "add", "origin", "/nonexistent/path.git"],
            cwd=clone_path, check=True, capture_output=True,
        )

        job = make_job(branch="main")
        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is False
        assert result.branch == "btb-results/main"
        assert result.error is not None
        assert len(result.error) > 0

    def test_push_failure_does_not_raise(self, tmp_path, pusher):
        """Push failure returns PushResult instead of raising."""
        clone_path = str(tmp_path / "no-repo")
        env = setup_git_env()

        # Create a repo with no remote at all
        subprocess.run(["git", "init", clone_path], check=True, env=env,
                        capture_output=True)
        subprocess.run(["git", "config", "user.email", "test@test.com"],
                        cwd=clone_path, check=True, capture_output=True)
        subprocess.run(["git", "config", "user.name", "Test"],
                        cwd=clone_path, check=True, capture_output=True)

        readme = Path(clone_path) / "README.md"
        readme.write_text("test\n")
        subprocess.run(["git", "add", "-A"], cwd=clone_path, check=True, env=env,
                        capture_output=True)
        subprocess.run(["git", "commit", "-m", "init"], cwd=clone_path,
                        check=True, env=env, capture_output=True)

        # No remote configured — push will fail
        subprocess.run(
            ["git", "remote", "add", "origin", "/nonexistent/remote.git"],
            cwd=clone_path, check=True, capture_output=True,
        )

        job = make_job(branch="develop")

        # This should NOT raise — it should return a PushResult
        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert isinstance(result, PushResult)
        assert result.success is False
        assert result.error is not None


# --- Force-push overwrites previous results ---


class TestForcePush:
    def test_force_push_overwrites_previous_results(self, git_repos, pusher):
        """A second push to the same results branch overwrites the first."""
        remote_path, clone_path = git_repos
        job = make_job(branch="main")

        # First push
        file1 = Path(clone_path) / "first-run.txt"
        file1.write_text("first run\n")
        asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        # Modify for second push
        file2 = Path(clone_path) / "second-run.txt"
        file2.write_text("second run\n")
        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is True

        # Verify the results branch has the second file
        files = run_git(
            ["ls-tree", "--name-only", "btb-results/main"],
            cwd=remote_path,
        )
        assert "second-run.txt" in files


# --- update_btb_file tests ---


class TestUpdateBtbFile:
    def test_updates_existing_keys(self, tmp_path):
        """Existing status/last_run/job_id keys are updated in place."""
        btb_file = tmp_path / "run.btb"
        btb_file.write_text(
            "# btb config\n"
            "spec=my-feature\n"
            "status=pending\n"
            "last_run=old\n"
            "job_id=old-id\n"
        )

        result = update_btb_file(
            str(tmp_path), "completed", "new-id", "2025-01-15T10:35:00+00:00"
        )

        assert result is True
        content = btb_file.read_text()
        assert "spec=my-feature" in content
        assert "status=completed" in content
        assert "last_run=2025-01-15T10:35:00+00:00" in content
        assert "job_id=new-id" in content
        assert "status=pending" not in content
        assert "job_id=old-id" not in content

    def test_adds_missing_keys(self, tmp_path):
        """Keys not present in the file are appended."""
        btb_file = tmp_path / "run.btb"
        btb_file.write_text("# btb config\nspec=my-feature\n")

        result = update_btb_file(
            str(tmp_path), "failed", "job-123", "2025-01-15T12:00:00+00:00"
        )

        assert result is True
        content = btb_file.read_text()
        assert "spec=my-feature" in content
        assert "status=failed" in content
        assert "last_run=2025-01-15T12:00:00+00:00" in content
        assert "job_id=job-123" in content

    def test_preserves_comments(self, tmp_path):
        """Comments are preserved in the output."""
        btb_file = tmp_path / "run.btb"
        btb_file.write_text(
            "# btb configuration\n"
            "# this is important\n"
            "spec=my-feature\n"
        )

        update_btb_file(str(tmp_path), "completed", "j1", "ts1")

        content = btb_file.read_text()
        assert "# btb configuration" in content
        assert "# this is important" in content

    def test_preserves_extra_keys(self, tmp_path):
        """Keys not in the update set are preserved."""
        btb_file = tmp_path / "run.btb"
        btb_file.write_text("spec=my-feature\ncustom_key=custom_value\n")

        update_btb_file(str(tmp_path), "timeout", "j2", "ts2")

        content = btb_file.read_text()
        assert "spec=my-feature" in content
        assert "custom_key=custom_value" in content
        assert "status=timeout" in content

    def test_no_btb_file_returns_false(self, tmp_path):
        """Returns False when no .btb file exists."""
        result = update_btb_file(str(tmp_path), "completed", "j1", "ts1")
        assert result is False

    def test_default_timestamp(self, tmp_path):
        """Uses current UTC time when no timestamp is provided."""
        btb_file = tmp_path / "run.btb"
        btb_file.write_text("spec=my-feature\n")

        result = update_btb_file(str(tmp_path), "completed", "j1")
        assert result is True

        content = btb_file.read_text()
        assert "last_run=" in content
        # Should be an ISO format timestamp
        for line in content.splitlines():
            if line.startswith("last_run="):
                ts = line.split("=", 1)[1]
                assert len(ts) > 10  # Reasonable ISO timestamp length


class TestPushResultsWithBtbUpdate:
    """Test that push_results updates the .btb file when status info is provided."""

    def test_push_updates_btb_file(self, git_repos, pusher):
        """When status and job_id are passed, the .btb file is updated before push."""
        remote_path, clone_path = git_repos
        job = make_job(branch="main", job_id="test-job-42")

        # Create a .btb file in the clone
        btb_file = Path(clone_path) / "run.btb"
        btb_file.write_text("# config\nspec=my-feature\n")

        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(
                job, clone_path,
                status="completed",
                job_id="test-job-42",
                timestamp="2025-01-15T10:35:00+00:00",
            )
        )

        assert result.success is True

        # Verify the .btb file on the results branch has the status
        file_content = run_git(
            ["show", "btb-results/main:run.btb"],
            cwd=remote_path,
        )
        assert "spec=my-feature" in file_content
        assert "status=completed" in file_content
        assert "job_id=test-job-42" in file_content
        assert "last_run=2025-01-15T10:35:00+00:00" in file_content

    def test_push_without_status_skips_btb_update(self, git_repos, pusher):
        """When no status is passed, the .btb file is not modified."""
        remote_path, clone_path = git_repos
        job = make_job(branch="main")

        btb_file = Path(clone_path) / "run.btb"
        btb_file.write_text("spec=my-feature\n")

        # Make some other change so there's something to push
        Path(clone_path, "output.txt").write_text("results\n")

        result = asyncio.get_event_loop().run_until_complete(
            pusher.push_results(job, clone_path)
        )

        assert result.success is True

        # The .btb file should be unchanged (no status/job_id added)
        file_content = run_git(
            ["show", "btb-results/main:run.btb"],
            cwd=remote_path,
        )
        assert "spec=my-feature" in file_content
        assert "status=" not in file_content
