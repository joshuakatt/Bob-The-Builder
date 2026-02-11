"""Property-based tests for the LLM health check trigger timing logic.

Tests the pure timing decision logic extracted from btb.sh's
maybe_start_health_check function. The function determines whether a
health check should be initiated for a given worker based on:
  - Whether health checks are enabled
  - Worker start time
  - Last health check time (or None/0 for no previous check)
  - Current time
  - Configured health check interval
"""

from hypothesis import given, settings, assume
from hypothesis import strategies as st


# ---------------------------------------------------------------------------
# Pure timing decision logic — extracted from btb.sh maybe_start_health_check
# ---------------------------------------------------------------------------


def should_trigger_health_check(
    started: int | None,
    last_hc: int | None,
    now: int,
    interval: int,
    enabled: bool,
) -> bool:
    """Determine whether a health check should trigger for a worker.

    This is a faithful extraction of the pure timing logic from btb.sh's
    maybe_start_health_check function. The bash function also checks for
    an in-progress health check (hc_pid file), but that is I/O-based state
    and not part of the timing decision.

    Args:
        started: Unix timestamp when the worker started, or None if not started.
        last_hc: Unix timestamp of the last health check, or None/0 if no
                 previous check has been performed.
        now: Current unix timestamp.
        interval: HEALTH_CHECK_INTERVAL in seconds.
        enabled: Whether HEALTH_CHECK_ENABLED is true.

    Returns:
        True if a health check should be triggered, False otherwise.
    """
    # Skip if disabled
    if not enabled:
        return False

    # Skip if worker hasn't started
    if started is None:
        return False

    # Check wall-clock eligibility
    elapsed = now - started
    if elapsed < interval:
        return False

    # Check cooldown from last health check
    # In bash: last_hc defaults to "0" if file is missing/empty
    effective_last_hc = last_hc if last_hc is not None else 0
    since_last = now - effective_last_hc
    if since_last < interval:
        return False

    return True


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

# Reasonable timestamp range: 2020-01-01 to ~2030
MIN_TIMESTAMP = 1_577_836_800  # 2020-01-01 00:00:00 UTC
MAX_TIMESTAMP = 1_893_456_000  # 2030-01-01 00:00:00 UTC

# Intervals: 1 second to 24 hours
reasonable_intervals = st.integers(min_value=1, max_value=86400)

# Timestamps within a reasonable range
reasonable_timestamps = st.integers(min_value=MIN_TIMESTAMP, max_value=MAX_TIMESTAMP)


@st.composite
def trigger_timing_inputs(draw):
    """Generate valid timing inputs where now >= started and now >= last_hc.

    Returns (started, last_hc, now, interval) where:
      - started is a reasonable timestamp
      - last_hc is either None (no previous check) or a timestamp >= started
      - now >= started and now >= last_hc (if set)
      - interval is a positive integer
    """
    interval = draw(reasonable_intervals)
    started = draw(reasonable_timestamps)

    # now must be >= started; allow up to 3x interval beyond started for
    # interesting boundary cases
    max_offset = interval * 3
    offset = draw(st.integers(min_value=0, max_value=max_offset))
    now = started + offset

    # last_hc: None (no previous check) or a timestamp between started and now
    has_last_hc = draw(st.booleans())
    if has_last_hc and now > started:
        last_hc = draw(st.integers(min_value=started, max_value=now))
    else:
        last_hc = None

    return started, last_hc, now, interval


# ---------------------------------------------------------------------------
# Property 5: Health check trigger timing
# Feature: llm-health-check, Property 5: Health check trigger timing
# **Validates: Requirements 4.1, 4.3**
# ---------------------------------------------------------------------------


@given(data=trigger_timing_inputs())
@settings(max_examples=500)
def test_property5_health_check_trigger_timing(data):
    """For any worker with a start timestamp, a last-health-check timestamp
    (or none), a current time, and a configured HEALTH_CHECK_INTERVAL:
    the health check should trigger if and only if (a) elapsed runtime
    exceeds HEALTH_CHECK_INTERVAL AND (b) time since the last health check
    exceeds HEALTH_CHECK_INTERVAL (or no previous check exists).
    """
    started, last_hc, now, interval = data

    result = should_trigger_health_check(
        started=started,
        last_hc=last_hc,
        now=now,
        interval=interval,
        enabled=True,
    )

    # Compute expected result from the specification
    elapsed = now - started
    condition_a = elapsed >= interval

    effective_last_hc = last_hc if last_hc is not None else 0
    since_last = now - effective_last_hc
    condition_b = since_last >= interval

    expected = condition_a and condition_b

    assert result == expected, (
        f"Trigger mismatch: got {result}, expected {expected}. "
        f"started={started}, last_hc={last_hc}, now={now}, interval={interval}, "
        f"elapsed={elapsed}, since_last={since_last}"
    )


@given(data=trigger_timing_inputs())
@settings(max_examples=200)
def test_property5_no_trigger_before_interval_elapsed(data):
    """A health check should never trigger if the worker has been running
    for less than HEALTH_CHECK_INTERVAL seconds.
    """
    started, last_hc, now, interval = data

    # Force elapsed < interval
    elapsed = now - started
    assume(elapsed < interval)

    result = should_trigger_health_check(
        started=started,
        last_hc=last_hc,
        now=now,
        interval=interval,
        enabled=True,
    )

    assert result is False, (
        f"Health check triggered with elapsed={elapsed} < interval={interval}"
    )


@given(data=trigger_timing_inputs())
@settings(max_examples=200)
def test_property5_no_trigger_during_cooldown(data):
    """A health check should never trigger if the time since the last
    health check is less than HEALTH_CHECK_INTERVAL.
    """
    started, last_hc, now, interval = data

    # Only test cases where a previous health check exists
    assume(last_hc is not None)
    since_last = now - last_hc
    assume(since_last < interval)

    result = should_trigger_health_check(
        started=started,
        last_hc=last_hc,
        now=now,
        interval=interval,
        enabled=True,
    )

    assert result is False, (
        f"Health check triggered during cooldown: since_last={since_last} < interval={interval}"
    )


@given(
    interval=reasonable_intervals,
    base_time=reasonable_timestamps,
)
@settings(max_examples=200)
def test_property5_triggers_when_both_conditions_met(interval, base_time):
    """A health check should trigger when both elapsed runtime and time
    since last check exceed the interval.
    """
    started = base_time
    # Ensure now is at least interval seconds after started
    now = started + interval

    # No previous health check — should trigger
    result = should_trigger_health_check(
        started=started,
        last_hc=None,
        now=now,
        interval=interval,
        enabled=True,
    )

    assert result is True, (
        f"Health check did not trigger when elapsed={interval} >= interval={interval} "
        f"and no previous check"
    )


@given(
    interval=reasonable_intervals,
    base_time=reasonable_timestamps,
    extra_elapsed=st.integers(min_value=0, max_value=86400),
)
@settings(max_examples=200)
def test_property5_triggers_after_cooldown_expires(interval, base_time, extra_elapsed):
    """After a previous health check, a new one should trigger once the
    cooldown period (HEALTH_CHECK_INTERVAL) has passed.
    """
    started = base_time
    # Worker has been running long enough (at least 2x interval)
    now = started + interval * 2 + extra_elapsed
    # Last health check was exactly at the interval mark
    last_hc = started + interval

    # Time since last check = now - last_hc = interval + extra_elapsed >= interval
    result = should_trigger_health_check(
        started=started,
        last_hc=last_hc,
        now=now,
        interval=interval,
        enabled=True,
    )

    assert result is True, (
        f"Health check did not trigger after cooldown expired. "
        f"now={now}, last_hc={last_hc}, since_last={now - last_hc}, interval={interval}"
    )


@given(now=reasonable_timestamps, interval=reasonable_intervals)
@settings(max_examples=100)
def test_property5_no_trigger_without_start_time(now, interval):
    """A health check should never trigger if the worker has no start time."""
    result = should_trigger_health_check(
        started=None,
        last_hc=None,
        now=now,
        interval=interval,
        enabled=True,
    )

    assert result is False, "Health check triggered without a start time"


# ---------------------------------------------------------------------------
# Property 6: Disabled flag prevents all health checks
# Feature: llm-health-check, Property 6: Disabled flag prevents all health checks
# **Validates: Requirements 1.5**
# ---------------------------------------------------------------------------


@given(data=trigger_timing_inputs())
@settings(max_examples=500)
def test_property6_disabled_flag_prevents_all_health_checks(data):
    """For any worker state and any elapsed runtime, when
    HEALTH_CHECK_ENABLED is false, should_trigger_health_check should
    return False — no health check should ever be initiated.
    """
    started, last_hc, now, interval = data

    result = should_trigger_health_check(
        started=started,
        last_hc=last_hc,
        now=now,
        interval=interval,
        enabled=False,
    )

    assert result is False, (
        f"Health check triggered when disabled! "
        f"started={started}, last_hc={last_hc}, now={now}, interval={interval}"
    )


@given(
    interval=reasonable_intervals,
    base_time=reasonable_timestamps,
    extra=st.integers(min_value=0, max_value=86400),
)
@settings(max_examples=200)
def test_property6_disabled_even_when_conditions_met(interval, base_time, extra):
    """Even when all timing conditions are met (elapsed > interval,
    cooldown expired), a disabled health check should not trigger.
    """
    started = base_time
    now = started + interval + extra  # elapsed >= interval

    result = should_trigger_health_check(
        started=started,
        last_hc=None,
        now=now,
        interval=interval,
        enabled=False,
    )

    assert result is False, (
        f"Health check triggered when disabled despite conditions being met! "
        f"elapsed={now - started}, interval={interval}"
    )
