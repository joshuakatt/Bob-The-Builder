"""Unit tests for server.models module."""

import json
import pytest

from server.models import Job, PushResult


# --- Fixtures ---

def make_job(**overrides) -> Job:
    """Create a Job with sensible defaults, allowing field overrides."""
    defaults = dict(
        id="a1b2c3d4-e5f6-7890-abcd-ef1234567890",
        repo_url="https://github.com/team/project.git",
        branch="feature/auth",
        commit_sha="abc123def456789012345678901234567890abcd",
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


def make_push_result(**overrides) -> PushResult:
    """Create a PushResult with sensible defaults, allowing field overrides."""
    defaults = dict(
        success=True,
        branch="btb-results/feature/auth",
        error=None,
    )
    defaults.update(overrides)
    return PushResult(**defaults)


# --- Job tests ---

class TestJob:
    def test_create_pending_job(self):
        job = make_job()
        assert job.id == "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        assert job.status == "pending"
        assert job.started_at is None
        assert job.completed_at is None
        assert job.exit_code is None

    def test_to_json_returns_valid_json(self):
        job = make_job()
        json_str = job.to_json()
        data = json.loads(json_str)
        assert data["id"] == job.id
        assert data["repo_url"] == job.repo_url
        assert data["status"] == "pending"

    def test_from_json_creates_job(self):
        job = make_job()
        json_str = job.to_json()
        restored = Job.from_json(json_str)
        assert restored.id == job.id
        assert restored.repo_url == job.repo_url
        assert restored.branch == job.branch
        assert restored.status == job.status

    def test_round_trip_pending_job(self):
        job = make_job()
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_round_trip_completed_job(self):
        job = make_job(
            status="completed",
            started_at="2025-01-15T10:31:00Z",
            completed_at="2025-01-15T11:30:00Z",
            exit_code=0,
            results_branch="btb-results/feature/auth",
            push_success=True,
            cleanup_success=True,
        )
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_round_trip_failed_job(self):
        job = make_job(
            status="failed",
            started_at="2025-01-15T10:31:00Z",
            completed_at="2025-01-15T10:35:00Z",
            exit_code=1,
            error="btb process crashed with signal 11",
            results_branch="btb-results/feature/auth",
            push_success=True,
            cleanup_success=True,
        )
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_round_trip_timeout_job(self):
        job = make_job(
            status="timeout",
            started_at="2025-01-15T10:31:00Z",
            completed_at="2025-01-15T12:31:00Z",
            exit_code=-9,
            error="Job exceeded 7200s timeout",
            results_branch="btb-results/feature/auth",
            push_success=False,
            push_error="remote: Permission denied",
            cleanup_success=True,
        )
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_round_trip_with_retry_of(self):
        job = make_job(
            status="pending",
            retry_of="original-job-id-1234",
        )
        restored = Job.from_json(job.to_json())
        assert restored == job
        assert restored.retry_of == "original-job-id-1234"

    def test_round_trip_all_none_optional_fields(self):
        job = make_job()
        restored = Job.from_json(job.to_json())
        assert restored.started_at is None
        assert restored.completed_at is None
        assert restored.exit_code is None
        assert restored.error is None
        assert restored.results_branch is None
        assert restored.push_success is None
        assert restored.push_error is None
        assert restored.cleanup_success is None
        assert restored.retry_of is None

    def test_round_trip_all_fields_populated(self):
        job = make_job(
            status="completed",
            started_at="2025-01-15T10:31:00Z",
            completed_at="2025-01-15T11:30:00Z",
            exit_code=0,
            error="some warning",
            results_branch="btb-results/feature/auth",
            push_success=True,
            push_error=None,
            cleanup_success=True,
            retry_of="prev-job-id",
        )
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_special_characters_in_fields(self):
        job = make_job(
            repo_url="https://github.com/team/project-with-dashes.git",
            branch="feature/auth-with-special-chars/and-slashes",
            pusher="user.name+tag@example.com",
            spec_name="spec-with-émojis-🚀",
            error='Error: "quoted" message with\nnewlines\tand\ttabs',
        )
        restored = Job.from_json(job.to_json())
        assert restored == job

    def test_to_json_contains_all_fields(self):
        job = make_job()
        data = json.loads(job.to_json())
        expected_keys = {
            "id", "repo_url", "branch", "commit_sha", "pusher", "spec_name",
            "status", "submitted_at", "started_at", "completed_at", "exit_code",
            "error", "results_branch", "push_success", "push_error",
            "cleanup_success", "retry_of",
        }
        assert set(data.keys()) == expected_keys

    def test_from_json_invalid_json_raises(self):
        with pytest.raises(json.JSONDecodeError):
            Job.from_json("not valid json")

    def test_from_json_missing_required_field_raises(self):
        data = {"id": "test"}  # Missing most required fields
        with pytest.raises(KeyError):
            Job.from_json(json.dumps(data))

    def test_all_valid_statuses(self):
        for status in ["pending", "running", "completed", "failed", "timeout"]:
            job = make_job(status=status)
            restored = Job.from_json(job.to_json())
            assert restored.status == status

    def test_exit_code_zero_preserved(self):
        """Ensure exit_code=0 is not confused with None."""
        job = make_job(exit_code=0)
        restored = Job.from_json(job.to_json())
        assert restored.exit_code == 0
        assert restored.exit_code is not None

    def test_push_success_false_preserved(self):
        """Ensure push_success=False is not confused with None."""
        job = make_job(push_success=False)
        restored = Job.from_json(job.to_json())
        assert restored.push_success is False
        assert restored.push_success is not None

    def test_cleanup_success_false_preserved(self):
        """Ensure cleanup_success=False is not confused with None."""
        job = make_job(cleanup_success=False)
        restored = Job.from_json(job.to_json())
        assert restored.cleanup_success is False
        assert restored.cleanup_success is not None


# --- PushResult tests ---

class TestPushResult:
    def test_create_success_result(self):
        result = make_push_result()
        assert result.success is True
        assert result.branch == "btb-results/feature/auth"
        assert result.error is None

    def test_create_failure_result(self):
        result = make_push_result(
            success=False,
            error="remote: Permission denied",
        )
        assert result.success is False
        assert result.error == "remote: Permission denied"

    def test_to_json_returns_valid_json(self):
        result = make_push_result()
        json_str = result.to_json()
        data = json.loads(json_str)
        assert data["success"] is True
        assert data["branch"] == "btb-results/feature/auth"

    def test_round_trip_success(self):
        result = make_push_result()
        restored = PushResult.from_json(result.to_json())
        assert restored == result

    def test_round_trip_failure(self):
        result = make_push_result(
            success=False,
            branch="btb-results/main",
            error="fatal: could not read remote",
        )
        restored = PushResult.from_json(result.to_json())
        assert restored == result

    def test_from_json_invalid_json_raises(self):
        with pytest.raises(json.JSONDecodeError):
            PushResult.from_json("{bad json")

    def test_from_json_missing_required_field_raises(self):
        with pytest.raises(KeyError):
            PushResult.from_json(json.dumps({"success": True}))

    def test_to_json_contains_all_fields(self):
        result = make_push_result()
        data = json.loads(result.to_json())
        assert set(data.keys()) == {"success", "branch", "error"}

    def test_special_characters_in_branch(self):
        result = make_push_result(branch="btb-results/feature/auth-with-special/chars")
        restored = PushResult.from_json(result.to_json())
        assert restored == result

    def test_special_characters_in_error(self):
        result = make_push_result(
            success=False,
            error='Error: "quoted" with\nnewlines',
        )
        restored = PushResult.from_json(result.to_json())
        assert restored == result
