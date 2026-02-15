"""Configuration loader for the BTB Service.

Reads configuration from a single .env-style file (KEY=value per line).
Validates that all required keys are present and converts numeric values.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


class ConfigError(Exception):
    """Raised when configuration is invalid or missing required values."""
    pass


@dataclass
class Config:
    """BTB Service configuration loaded from an env file."""
    webhook_secret: str
    github_token: str
    queue_dir: str
    completed_dir: str
    jobs_dir: str
    logs_dir: str
    btb_path: str
    port: int
    tls_cert: str
    tls_key: str
    job_timeout: int
    log_retention_days: int
    aws_profile: str
    # EC2 worker mode (optional — if set, jobs run on a remote EC2 instance)
    worker_instance_id: Optional[str] = None
    worker_region: Optional[str] = None


# Keys that must be present in the config file
REQUIRED_KEYS = [
    "WEBHOOK_SECRET",
    "GITHUB_TOKEN",
    "QUEUE_DIR",
    "COMPLETED_DIR",
    "JOBS_DIR",
    "LOGS_DIR",
    "BTB_PATH",
    "PORT",
    "TLS_CERT",
    "TLS_KEY",
    "JOB_TIMEOUT",
    "LOG_RETENTION_DAYS",
    "AWS_PROFILE",
]

# Keys whose values should be converted to int
INT_KEYS = {"PORT", "JOB_TIMEOUT", "LOG_RETENTION_DAYS"}


def parse_env_file(path: str) -> dict[str, str]:
    """Parse a .env-style file into a dictionary.

    Format: KEY=value per line. Lines starting with # are comments.
    Empty lines and lines with only whitespace are ignored.
    Values may optionally be quoted with single or double quotes.

    Args:
        path: Path to the env file.

    Returns:
        Dictionary mapping keys to string values.

    Raises:
        ConfigError: If the file cannot be read.
    """
    config_path = Path(path)
    if not config_path.exists():
        raise ConfigError(f"Configuration file not found: {path}")

    result: dict[str, str] = {}
    try:
        text = config_path.read_text()
    except OSError as e:
        raise ConfigError(f"Cannot read configuration file {path}: {e}")

    for line_num, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        # Skip empty lines and comments
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue  # Skip malformed lines silently
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip()
        # Strip optional quotes
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        if key:
            result[key] = value

    return result


def load_config(path: str) -> Config:
    """Load and validate configuration from an env file.

    Reads the file, validates all required keys are present,
    converts numeric values, and returns a Config dataclass.

    Args:
        path: Path to the configuration env file.

    Returns:
        A validated Config object.

    Raises:
        ConfigError: If the file is missing, unreadable, or missing required keys.
    """
    raw = parse_env_file(path)

    # Check for missing required keys
    missing = [key for key in REQUIRED_KEYS if key not in raw or raw[key] == ""]
    if missing:
        missing_list = ", ".join(missing)
        raise ConfigError(
            f"Missing required configuration value(s): {missing_list}"
        )

    # Convert numeric values
    int_values: dict[str, int] = {}
    for key in INT_KEYS:
        try:
            int_values[key] = int(raw[key])
        except ValueError:
            raise ConfigError(
                f"Configuration value for {key} must be an integer, got: {raw[key]!r}"
            )

    return Config(
        webhook_secret=raw["WEBHOOK_SECRET"],
        github_token=raw["GITHUB_TOKEN"],
        queue_dir=raw["QUEUE_DIR"],
        completed_dir=raw["COMPLETED_DIR"],
        jobs_dir=raw["JOBS_DIR"],
        logs_dir=raw["LOGS_DIR"],
        btb_path=raw["BTB_PATH"],
        port=int_values["PORT"],
        tls_cert=raw["TLS_CERT"],
        tls_key=raw["TLS_KEY"],
        job_timeout=int_values["JOB_TIMEOUT"],
        log_retention_days=int_values["LOG_RETENTION_DAYS"],
        aws_profile=raw["AWS_PROFILE"],
        worker_instance_id=raw.get("WORKER_INSTANCE_ID") or None,
        worker_region=raw.get("WORKER_REGION") or None,
    )
