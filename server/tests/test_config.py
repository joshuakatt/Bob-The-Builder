"""Unit tests for server.config module."""

import os
import pytest

from server.config import Config, ConfigError, load_config, parse_env_file


# --- Fixtures ---

VALID_CONFIG = """\
WEBHOOK_SECRET=test-secret-123
GITHUB_TOKEN=ghp_testtoken123
QUEUE_DIR=/var/btb/queue
COMPLETED_DIR=/var/btb/completed
JOBS_DIR=/var/btb/jobs
LOGS_DIR=/var/btb/logs
BTB_PATH=/opt/btb
PORT=8443
TLS_CERT=/etc/btb-service/cert.pem
TLS_KEY=/etc/btb-service/key.pem
JOB_TIMEOUT=7200
LOG_RETENTION_DAYS=7
AWS_PROFILE=btb-service
"""


@pytest.fixture
def config_file(tmp_path):
    """Create a valid config file and return its path."""
    path = tmp_path / "config.env"
    path.write_text(VALID_CONFIG)
    return str(path)


@pytest.fixture
def make_config_file(tmp_path):
    """Factory fixture to create config files with custom content."""
    def _make(content: str) -> str:
        path = tmp_path / "config.env"
        path.write_text(content)
        return str(path)
    return _make


# --- parse_env_file tests ---

class TestParseEnvFile:
    def test_parses_key_value_pairs(self, make_config_file):
        path = make_config_file("FOO=bar\nBAZ=qux\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar", "BAZ": "qux"}

    def test_ignores_comments(self, make_config_file):
        path = make_config_file("# This is a comment\nFOO=bar\n# Another\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar"}

    def test_ignores_empty_lines(self, make_config_file):
        path = make_config_file("\nFOO=bar\n\n\nBAZ=qux\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar", "BAZ": "qux"}

    def test_strips_double_quotes(self, make_config_file):
        path = make_config_file('FOO="bar baz"\n')
        result = parse_env_file(path)
        assert result == {"FOO": "bar baz"}

    def test_strips_single_quotes(self, make_config_file):
        path = make_config_file("FOO='bar baz'\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar baz"}

    def test_value_with_equals_sign(self, make_config_file):
        path = make_config_file("FOO=bar=baz\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar=baz"}

    def test_file_not_found(self, tmp_path):
        with pytest.raises(ConfigError, match="Configuration file not found"):
            parse_env_file(str(tmp_path / "nonexistent.env"))

    def test_whitespace_around_key_and_value(self, make_config_file):
        path = make_config_file("  FOO  =  bar  \n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar"}

    def test_empty_file(self, make_config_file):
        path = make_config_file("")
        result = parse_env_file(path)
        assert result == {}

    def test_skips_lines_without_equals(self, make_config_file):
        path = make_config_file("no-equals-here\nFOO=bar\n")
        result = parse_env_file(path)
        assert result == {"FOO": "bar"}


# --- load_config tests ---

class TestLoadConfig:
    def test_loads_valid_config(self, config_file):
        config = load_config(config_file)
        assert isinstance(config, Config)
        assert config.webhook_secret == "test-secret-123"
        assert config.github_token == "ghp_testtoken123"
        assert config.queue_dir == "/var/btb/queue"
        assert config.completed_dir == "/var/btb/completed"
        assert config.jobs_dir == "/var/btb/jobs"
        assert config.logs_dir == "/var/btb/logs"
        assert config.btb_path == "/opt/btb"
        assert config.port == 8443
        assert config.tls_cert == "/etc/btb-service/cert.pem"
        assert config.tls_key == "/etc/btb-service/key.pem"
        assert config.job_timeout == 7200
        assert config.log_retention_days == 7
        assert config.aws_profile == "btb-service"

    def test_numeric_values_are_ints(self, config_file):
        config = load_config(config_file)
        assert isinstance(config.port, int)
        assert isinstance(config.job_timeout, int)
        assert isinstance(config.log_retention_days, int)

    def test_missing_single_key_names_it(self, make_config_file):
        # Remove WEBHOOK_SECRET
        lines = VALID_CONFIG.strip().splitlines()
        content = "\n".join(l for l in lines if not l.startswith("WEBHOOK_SECRET"))
        path = make_config_file(content)
        with pytest.raises(ConfigError, match="WEBHOOK_SECRET"):
            load_config(path)

    def test_missing_multiple_keys_names_all(self, make_config_file):
        # Remove WEBHOOK_SECRET and GITHUB_TOKEN
        lines = VALID_CONFIG.strip().splitlines()
        content = "\n".join(
            l for l in lines
            if not l.startswith("WEBHOOK_SECRET") and not l.startswith("GITHUB_TOKEN")
        )
        path = make_config_file(content)
        with pytest.raises(ConfigError) as exc_info:
            load_config(path)
        assert "WEBHOOK_SECRET" in str(exc_info.value)
        assert "GITHUB_TOKEN" in str(exc_info.value)

    def test_empty_value_treated_as_missing(self, make_config_file):
        content = VALID_CONFIG.replace(
            "WEBHOOK_SECRET=test-secret-123", "WEBHOOK_SECRET="
        )
        path = make_config_file(content)
        with pytest.raises(ConfigError, match="WEBHOOK_SECRET"):
            load_config(path)

    def test_invalid_int_value_raises_error(self, make_config_file):
        content = VALID_CONFIG.replace("PORT=8443", "PORT=not-a-number")
        path = make_config_file(content)
        with pytest.raises(ConfigError, match="PORT.*integer"):
            load_config(path)

    def test_file_not_found_raises_config_error(self, tmp_path):
        with pytest.raises(ConfigError, match="Configuration file not found"):
            load_config(str(tmp_path / "missing.env"))

    def test_config_with_comments_and_blank_lines(self, make_config_file):
        content = "# BTB Service Config\n\n" + VALID_CONFIG + "\n# End\n"
        path = make_config_file(content)
        config = load_config(path)
        assert config.webhook_secret == "test-secret-123"

    def test_config_with_quoted_values(self, make_config_file):
        content = VALID_CONFIG.replace(
            "WEBHOOK_SECRET=test-secret-123",
            'WEBHOOK_SECRET="my secret with spaces"'
        )
        path = make_config_file(content)
        config = load_config(path)
        assert config.webhook_secret == "my secret with spaces"

    def test_extra_keys_are_ignored(self, make_config_file):
        content = VALID_CONFIG + "EXTRA_KEY=extra_value\n"
        path = make_config_file(content)
        config = load_config(path)
        assert config.webhook_secret == "test-secret-123"
