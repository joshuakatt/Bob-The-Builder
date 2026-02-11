"""Unit tests for credential refresh retry logic.

Tests the ``run_credential_refresh`` function from ``server.main`` which
attempts to refresh AWS SSO credentials with exponential backoff retries.

Validates: Requirements 2.3, 2.4
"""

import logging
from unittest.mock import MagicMock

import pytest

from server.main import run_credential_refresh


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_run_command(results: list[tuple[int, str]]):
    """Create a mock run_command that returns results in sequence.

    Args:
        results: List of (return_code, error_message) tuples.
            Each call to the returned callable pops the next result.

    Returns:
        A callable that takes a profile string and returns the next
        (return_code, error_message) tuple from the list.
    """
    call_log: list[str] = []
    results_iter = iter(results)

    def run_command(profile: str) -> tuple[int, str]:
        call_log.append(profile)
        return next(results_iter)

    run_command.call_log = call_log  # type: ignore[attr-defined]
    return run_command


def _make_sleep_fn():
    """Create a mock sleep function that records sleep durations."""
    sleep_log: list[float] = []

    def sleep_fn(seconds: float) -> None:
        sleep_log.append(seconds)

    sleep_fn.sleep_log = sleep_log  # type: ignore[attr-defined]
    return sleep_fn


# ---------------------------------------------------------------------------
# Tests: Successful refresh on first attempt
# ---------------------------------------------------------------------------


class TestSuccessOnFirstAttempt:
    """Credential refresh succeeds immediately on the first try."""

    def test_returns_true_on_success(self):
        """run_credential_refresh returns True when first attempt succeeds."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        result = run_credential_refresh("my-profile", cmd, sleep_fn=sleep)

        assert result is True

    def test_calls_command_once(self):
        """Only one command invocation when first attempt succeeds."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        run_credential_refresh("my-profile", cmd, sleep_fn=sleep)

        assert len(cmd.call_log) == 1

    def test_no_sleep_on_success(self):
        """No backoff sleep when first attempt succeeds."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        run_credential_refresh("my-profile", cmd, sleep_fn=sleep)

        assert sleep.sleep_log == []

    def test_passes_profile_to_command(self):
        """The profile string is passed to the run_command callable."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        run_credential_refresh("btb-service", cmd, sleep_fn=sleep)

        assert cmd.call_log == ["btb-service"]


# ---------------------------------------------------------------------------
# Tests: Failure triggers exponential backoff retries
# ---------------------------------------------------------------------------


class TestExponentialBackoffRetries:
    """Failures trigger retries with exponential backoff intervals."""

    def test_retries_on_nonzero_return_code(self):
        """Non-zero return code triggers retry."""
        cmd = _make_run_command([
            (1, "auth error"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert result is True
        assert len(cmd.call_log) == 2

    def test_backoff_after_first_failure(self):
        """First failure triggers 1-second backoff (2^0)."""
        cmd = _make_run_command([
            (1, "fail"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert sleep.sleep_log == [1]

    def test_backoff_intervals_follow_2n_pattern(self):
        """Backoff intervals follow 2^n: 1, 2, 4, 8 seconds."""
        cmd = _make_run_command([
            (1, "fail 1"),
            (1, "fail 2"),
            (1, "fail 3"),
            (1, "fail 4"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert sleep.sleep_log == [1, 2, 4, 8]

    def test_success_on_third_attempt(self):
        """Refresh succeeds on the third attempt after two failures."""
        cmd = _make_run_command([
            (1, "fail"),
            (1, "fail"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert result is True
        assert len(cmd.call_log) == 3
        assert sleep.sleep_log == [1, 2]


# ---------------------------------------------------------------------------
# Tests: Gives up after 5 failures
# ---------------------------------------------------------------------------


class TestGivesUpAfterMaxAttempts:
    """After 5 consecutive failures, gives up for the current cycle."""

    def test_returns_false_after_5_failures(self):
        """run_credential_refresh returns False after 5 failed attempts."""
        cmd = _make_run_command([
            (1, "fail 1"),
            (1, "fail 2"),
            (1, "fail 3"),
            (1, "fail 4"),
            (1, "fail 5"),
        ])
        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert result is False

    def test_exactly_5_command_invocations(self):
        """Exactly 5 command invocations when all fail."""
        cmd = _make_run_command([
            (1, "fail")] * 5
        )
        sleep = _make_sleep_fn()

        run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert len(cmd.call_log) == 5

    def test_4_backoff_sleeps_between_5_attempts(self):
        """4 backoff sleeps occur between 5 attempts (no sleep after last)."""
        cmd = _make_run_command([(1, "fail")] * 5)
        sleep = _make_sleep_fn()

        run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert len(sleep.sleep_log) == 4

    def test_full_backoff_sequence(self):
        """Full backoff sequence is 1, 2, 4, 8 seconds (no sleep after 5th)."""
        cmd = _make_run_command([(1, "fail")] * 5)
        sleep = _make_sleep_fn()

        run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert sleep.sleep_log == [1, 2, 4, 8]

    def test_logs_final_give_up(self, caplog):
        """Final give-up message is logged at ERROR level."""
        cmd = _make_run_command([(1, "fail")] * 5)
        sleep = _make_sleep_fn()

        with caplog.at_level(logging.ERROR, logger="server.main"):
            run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert any(
            "failed after 5 attempts" in record.message
            for record in caplog.records
        )


# ---------------------------------------------------------------------------
# Tests: Exception handling during refresh
# ---------------------------------------------------------------------------


class TestExceptionHandling:
    """Exceptions raised by run_command are caught and retried."""

    def test_exception_triggers_retry(self):
        """An exception from run_command triggers a retry."""
        call_count = 0

        def failing_then_ok(profile: str) -> tuple[int, str]:
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise OSError("connection refused")
            return (0, "")

        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", failing_then_ok, sleep_fn=sleep)

        assert result is True
        assert call_count == 2

    def test_all_exceptions_gives_up(self):
        """If all attempts raise exceptions, returns False."""
        def always_fail(profile: str) -> tuple[int, str]:
            raise RuntimeError("broken")

        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", always_fail, sleep_fn=sleep)

        assert result is False

    def test_exception_logged_as_warning(self, caplog):
        """Exceptions are logged as warnings with attempt number."""
        def fail_once(profile: str) -> tuple[int, str]:
            raise TimeoutError("timed out")

        sleep = _make_sleep_fn()

        with caplog.at_level(logging.WARNING, logger="server.main"):
            run_credential_refresh("prof", fail_once, sleep_fn=sleep)

        warning_records = [
            r for r in caplog.records
            if r.levelno == logging.WARNING and "error" in r.message.lower()
        ]
        assert len(warning_records) >= 1

    def test_mixed_exceptions_and_failures(self):
        """Mix of exceptions and non-zero return codes, then success."""
        call_count = 0

        def mixed_failures(profile: str) -> tuple[int, str]:
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise ConnectionError("network down")
            if call_count == 2:
                return (1, "auth failed")
            return (0, "")

        sleep = _make_sleep_fn()

        result = run_credential_refresh("prof", mixed_failures, sleep_fn=sleep)

        assert result is True
        assert call_count == 3


# ---------------------------------------------------------------------------
# Tests: Logging behavior
# ---------------------------------------------------------------------------


class TestLogging:
    """Verify logging of each failure and the final give-up."""

    def test_each_failure_logged(self, caplog):
        """Each failed attempt is logged as a warning."""
        cmd = _make_run_command([
            (1, "error A"),
            (1, "error B"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        with caplog.at_level(logging.WARNING, logger="server.main"):
            run_credential_refresh("prof", cmd, sleep_fn=sleep)

        warning_msgs = [
            r.message for r in caplog.records if r.levelno == logging.WARNING
        ]
        assert any("attempt 1/5" in m for m in warning_msgs)
        assert any("attempt 2/5" in m for m in warning_msgs)

    def test_success_logged_at_info(self, caplog):
        """Successful refresh is logged at INFO level."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        with caplog.at_level(logging.INFO, logger="server.main"):
            run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert any(
            "succeeded" in r.message
            for r in caplog.records
            if r.levelno == logging.INFO
        )

    def test_backoff_logged_at_info(self, caplog):
        """Backoff wait is logged at INFO level with duration."""
        cmd = _make_run_command([
            (1, "fail"),
            (0, ""),
        ])
        sleep = _make_sleep_fn()

        with caplog.at_level(logging.INFO, logger="server.main"):
            run_credential_refresh("prof", cmd, sleep_fn=sleep)

        assert any(
            "Retrying credential refresh in 1 seconds" in r.message
            for r in caplog.records
        )


# ---------------------------------------------------------------------------
# Tests: Custom max_attempts parameter
# ---------------------------------------------------------------------------


class TestCustomMaxAttempts:
    """The max_attempts parameter controls the retry limit."""

    def test_max_attempts_3(self):
        """With max_attempts=3, gives up after 3 failures."""
        cmd = _make_run_command([(1, "fail")] * 3)
        sleep = _make_sleep_fn()

        result = run_credential_refresh(
            "prof", cmd, sleep_fn=sleep, max_attempts=3
        )

        assert result is False
        assert len(cmd.call_log) == 3

    def test_max_attempts_1(self):
        """With max_attempts=1, no retries at all."""
        cmd = _make_run_command([(1, "fail")])
        sleep = _make_sleep_fn()

        result = run_credential_refresh(
            "prof", cmd, sleep_fn=sleep, max_attempts=1
        )

        assert result is False
        assert len(cmd.call_log) == 1
        assert sleep.sleep_log == []

    def test_max_attempts_1_success(self):
        """With max_attempts=1, success on first try still works."""
        cmd = _make_run_command([(0, "")])
        sleep = _make_sleep_fn()

        result = run_credential_refresh(
            "prof", cmd, sleep_fn=sleep, max_attempts=1
        )

        assert result is True


# ---------------------------------------------------------------------------
# Tests: Default sleep_fn behavior
# ---------------------------------------------------------------------------


class TestDefaultSleepFn:
    """When sleep_fn is not provided, time.sleep is used by default."""

    def test_default_sleep_fn_used(self, monkeypatch):
        """Without explicit sleep_fn, time.sleep is called."""
        import time
        sleep_calls: list[float] = []
        monkeypatch.setattr(time, "sleep", lambda s: sleep_calls.append(s))

        cmd = _make_run_command([
            (1, "fail"),
            (0, ""),
        ])

        run_credential_refresh("prof", cmd)

        assert sleep_calls == [1]
