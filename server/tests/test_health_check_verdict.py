"""Property-based tests for the LLM health check verdict parser.

Tests the inline python3 verdict parsing logic used by btb's
process_health_check_result function. The parser extracts a verdict
(CONTINUE, KILL_AND_RETRY, or KILL_AND_FAIL) and a reasoning string
from an LLM response.
"""

import re
import string

from hypothesis import given, settings, assume
from hypothesis import strategies as st


# ---------------------------------------------------------------------------
# Verdict parser under test — extracted from btb.sh parse_health_verdict
# ---------------------------------------------------------------------------

VERDICTS = ["KILL_AND_FAIL", "KILL_AND_RETRY", "CONTINUE"]


def parse_health_verdict(response: str) -> tuple[str, str]:
    """Parse an LLM health-check response and return (verdict, reason).

    This is a faithful copy of the inline python3 used in btb.sh's
    process_health_check_result function.  The search order is:
      1. KILL_AND_FAIL  (most specific)
      2. KILL_AND_RETRY
      3. CONTINUE
    The first match (scanning line-by-line, keyword-by-keyword) wins.
    If nothing matches, the default is ("CONTINUE", "unparseable response").
    """
    for line in response.split("\n"):
        line_upper = line.strip().upper()
        for v in VERDICTS:
            if v in line_upper:
                # Extract reasoning: strip everything up to and including the verdict keyword
                reason = re.sub(
                    r".*(" + v + r")[:\s]*", "", line, flags=re.IGNORECASE
                ).strip()
                reason = reason[:200]
                # Escape backslashes and double quotes for safe shell eval
                reason = reason.replace("\\", "\\\\").replace('"', '\\"')
                return v, reason

    return "CONTINUE", "unparseable response"


# ---------------------------------------------------------------------------
# Hypothesis strategies
# ---------------------------------------------------------------------------

# Printable text that does NOT contain any verdict keyword (case-insensitive).
# We build it from characters and then reject if any keyword sneaks in.
_SAFE_ALPHABET = st.sampled_from(
    list(string.ascii_letters + string.digits + " \t.,;:!?-_=+@#$%^&*()[]{}<>/|~`'")
)


@st.composite
def safe_text(draw, min_size: int = 0, max_size: int = 200):
    """Generate a string guaranteed to contain none of the verdict keywords (case-insensitive)."""
    text = draw(st.text(alphabet=_SAFE_ALPHABET, min_size=min_size, max_size=max_size))
    upper = text.upper()
    for v in VERDICTS:
        assume(v not in upper)
    return text


@st.composite
def response_with_one_verdict(draw):
    """Generate a multi-line response containing exactly one verdict keyword.

    Returns (full_response, expected_verdict).
    """
    verdict = draw(st.sampled_from(VERDICTS))

    # Generate prefix/suffix text that won't contain any verdict keyword
    prefix = draw(safe_text(max_size=80))
    suffix = draw(safe_text(max_size=80))

    # Optionally vary the case of the verdict keyword
    case_style = draw(st.sampled_from(["upper", "lower", "title"]))
    if case_style == "upper":
        keyword = verdict.upper()
    elif case_style == "lower":
        keyword = verdict.lower()
    else:
        keyword = verdict.title()

    # Build the verdict line — optionally add a colon/space separator
    separator = draw(st.sampled_from(["", ": ", " ", "  "]))
    verdict_line = f"{prefix}{keyword}{separator}{suffix}"

    # Add some safe lines before and after
    lines_before = draw(st.lists(safe_text(max_size=60), min_size=0, max_size=5))
    lines_after = draw(st.lists(safe_text(max_size=60), min_size=0, max_size=5))

    full_response = "\n".join(lines_before + [verdict_line] + lines_after)
    return full_response, verdict


# ---------------------------------------------------------------------------
# Property 3: Verdict parsing extracts the correct verdict
# Feature: llm-health-check, Property 3: Verdict parsing extracts the correct verdict
# **Validates: Requirements 5.1, 5.2, 5.4**
# ---------------------------------------------------------------------------


@given(data=response_with_one_verdict())
@settings(max_examples=200)
def test_property3_verdict_parsing_extracts_correct_verdict(data):
    """For any LLM response containing exactly one verdict keyword
    (possibly surrounded by other text), the parser should extract
    that keyword as the verdict.
    """
    response, expected_verdict = data
    verdict, _reason = parse_health_verdict(response)
    assert verdict == expected_verdict, (
        f"Expected verdict '{expected_verdict}' but got '{verdict}' "
        f"for response: {response!r}"
    )


# ---------------------------------------------------------------------------
# Property 4: Unparseable responses default to CONTINUE
# Feature: llm-health-check, Property 4: Unparseable responses default to CONTINUE
# **Validates: Requirements 5.5**
# ---------------------------------------------------------------------------


@given(response=safe_text(min_size=0, max_size=500))
@settings(max_examples=200)
def test_property4_unparseable_responses_default_to_continue(response):
    """For any string that does not contain any of the verdict keywords
    (case-insensitive), the parser should return CONTINUE with reason
    'unparseable response'.
    """
    verdict, reason = parse_health_verdict(response)
    assert verdict == "CONTINUE", (
        f"Expected 'CONTINUE' for unparseable input but got '{verdict}' "
        f"for response: {response!r}"
    )
    assert reason == "unparseable response", (
        f"Expected reason 'unparseable response' but got '{reason}' "
        f"for response: {response!r}"
    )
