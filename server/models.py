"""Data models for the BTB Service.

Defines the Job and PushResult dataclasses used throughout the service.
Both support JSON serialization for disk persistence.
"""

import json
from dataclasses import dataclass, asdict
from typing import Optional


@dataclass
class PushResult:
    """Result of pushing btb results back to the original repository.

    Returned by the ResultPusher after attempting to push results
    to the btb-results/{branch} branch.
    """
    success: bool
    branch: str               # "btb-results/{original-branch}"
    error: Optional[str]      # Error message if push failed

    def to_json(self) -> str:
        """Serialize this PushResult to a JSON string.

        Returns:
            JSON string representation of this PushResult.
        """
        return json.dumps(asdict(self), indent=2)

    @classmethod
    def from_json(cls, json_str: str) -> "PushResult":
        """Deserialize a PushResult from a JSON string.

        Args:
            json_str: JSON string to parse.

        Returns:
            A PushResult instance.

        Raises:
            json.JSONDecodeError: If the string is not valid JSON.
            KeyError: If required fields are missing.
        """
        data = json.loads(json_str)
        return cls(
            success=data["success"],
            branch=data["branch"],
            error=data.get("error"),
        )


@dataclass
class Job:
    """Represents a single btb execution job.

    A Job is created when a GitHub webhook push event is received for a
    repository containing a .btb file. It tracks the full lifecycle from
    submission through execution, result push-back, and cleanup.

    Job statuses: "pending", "running", "completed", "failed", "timeout"
    """
    id: str                        # UUID
    repo_url: str                  # GitHub clone URL
    branch: str                    # Branch name
    commit_sha: str                # Commit SHA
    pusher: str                    # GitHub username of pusher
    spec_name: str                 # Spec to run (read from .btb file)
    status: str                    # "pending" | "running" | "completed" | "failed" | "timeout"
    submitted_at: str              # ISO 8601 timestamp
    started_at: Optional[str]      # ISO 8601 timestamp
    completed_at: Optional[str]    # ISO 8601 timestamp
    exit_code: Optional[int]       # btb exit code
    error: Optional[str]           # Error message if failed
    results_branch: Optional[str]  # "btb-results/{branch}" after push
    push_success: Optional[bool]   # Whether result push succeeded
    push_error: Optional[str]      # Error message if push failed
    cleanup_success: Optional[bool]  # Whether working dir cleanup succeeded
    retry_of: Optional[str]        # Job ID of the original job if this is a retry

    def to_json(self) -> str:
        """Serialize this Job to a JSON string.

        Returns:
            JSON string representation of this Job.
        """
        return json.dumps(asdict(self), indent=2)

    @classmethod
    def from_json(cls, json_str: str) -> "Job":
        """Deserialize a Job from a JSON string.

        Args:
            json_str: JSON string to parse.

        Returns:
            A Job instance.

        Raises:
            json.JSONDecodeError: If the string is not valid JSON.
            KeyError: If required fields are missing.
        """
        data = json.loads(json_str)
        return cls(
            id=data["id"],
            repo_url=data["repo_url"],
            branch=data["branch"],
            commit_sha=data["commit_sha"],
            pusher=data["pusher"],
            spec_name=data["spec_name"],
            status=data["status"],
            submitted_at=data["submitted_at"],
            started_at=data.get("started_at"),
            completed_at=data.get("completed_at"),
            exit_code=data.get("exit_code"),
            error=data.get("error"),
            results_branch=data.get("results_branch"),
            push_success=data.get("push_success"),
            push_error=data.get("push_error"),
            cleanup_success=data.get("cleanup_success"),
            retry_of=data.get("retry_of"),
        )
