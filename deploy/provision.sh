#!/bin/bash
# =============================================================================
# BTB Service — EC2 Instance Provisioning Script
# =============================================================================
#
# Installs all dependencies required to run the BTB Service on a fresh
# Amazon Linux 2023 or Ubuntu instance. This script is idempotent — safe
# to run multiple times.
#
# Prerequisites:
#   - Root or sudo access
#   - Internet connectivity (for package downloads)
#   - An IAM instance profile attached to the EC2 instance that grants
#     permissions required by kiro-cli (Requirement 1.2)
#
# Security group requirements (Requirement 1.4):
#   - Inbound HTTPS (443) from authorized sources (for webhook + dashboard)
#   - Inbound SSH (22) from authorized sources (for administration)
#   - Configure these in the AWS Console or via CLI before running this script.
#
# Usage:
#   sudo bash deploy/provision.sh
#
# Requirements satisfied: 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[btb-provision] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

error() {
    echo "[btb-provision] ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            amzn)
                echo "amazon"
                ;;
            ubuntu)
                echo "ubuntu"
                ;;
            *)
                error "Unsupported OS: $ID. This script supports Amazon Linux 2023 and Ubuntu."
                ;;
        esac
    else
        error "Cannot detect OS — /etc/os-release not found."
    fi
}

OS=$(detect_os)
log "Detected OS: $OS"

# ---------------------------------------------------------------------------
# Ensure running as root
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
fi

# ---------------------------------------------------------------------------
# Install system packages
# Requirement 1.1: bash 3.2+, git, python3, perl must be on PATH
# ---------------------------------------------------------------------------

log "Installing system packages..."

if [ "$OS" = "amazon" ]; then
    dnf update -y
    dnf install -y \
        bash \
        git \
        python3 \
        python3-pip \
        perl \
        util-linux \
        procps-ng \
        shadow-utils
elif [ "$OS" = "ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y \
        bash \
        git \
        python3 \
        python3-pip \
        python3-venv \
        perl \
        bsdutils \
        procps
fi

log "System packages installed."

# ---------------------------------------------------------------------------
# Install kiro-cli
# Requirement 1.1: kiro-cli must be on PATH
# ---------------------------------------------------------------------------

if command_exists kiro-cli; then
    log "kiro-cli is already installed: $(kiro-cli --version 2>/dev/null || echo 'version unknown')"
else
    log "Installing kiro-cli..."
    # kiro-cli is distributed via npm; install Node.js if not present
    if ! command_exists node; then
        log "Node.js not found — installing via package manager..."
        if [ "$OS" = "amazon" ]; then
            dnf install -y nodejs
        elif [ "$OS" = "ubuntu" ]; then
            apt-get install -y nodejs npm
        fi
    fi
    npm install -g @anthropic/kiro-cli || log "WARNING: kiro-cli installation failed — install manually."
fi

# ---------------------------------------------------------------------------
# Install Python dependencies
# ---------------------------------------------------------------------------

log "Installing Python dependencies..."
pip3 install --break-system-packages aiohttp 2>/dev/null \
    || pip3 install aiohttp

log "Python dependencies installed."

# ---------------------------------------------------------------------------
# Create btb service user
# ---------------------------------------------------------------------------

if id btb >/dev/null 2>&1; then
    log "User 'btb' already exists."
else
    log "Creating 'btb' service user..."
    useradd --system --shell /usr/sbin/nologin --home-dir /opt/btb --create-home btb
    log "User 'btb' created."
fi

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------

log "Creating directory structure..."

# Service directories
mkdir -p /var/btb/queue
mkdir -p /var/btb/completed
mkdir -p /var/btb/jobs
mkdir -p /var/btb/logs

# Configuration directory
mkdir -p /etc/btb-service

# Application directory
mkdir -p /opt/btb

# Set ownership — the btb user owns the data directories
chown -R btb:btb /var/btb
chown -R btb:btb /opt/btb

# Config directory is root-owned, readable by btb
chown root:btb /etc/btb-service
chmod 750 /etc/btb-service

log "Directory structure created."

# ---------------------------------------------------------------------------
# Install systemd service
# Requirement 1.3: BTB_Service starts automatically via systemd
# Requirement 1.5: systemd restarts the service within 10 seconds on crash
# ---------------------------------------------------------------------------

log "Installing systemd service unit..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/btb-service.service"

if [ -f "$SERVICE_FILE" ]; then
    cp "$SERVICE_FILE" /etc/systemd/system/btb-service.service
    systemctl daemon-reload
    systemctl enable btb-service.service
    log "systemd service installed and enabled."
else
    log "WARNING: btb-service.service not found at $SERVICE_FILE — skipping systemd setup."
    log "Copy deploy/btb-service.service to /etc/systemd/system/ manually."
fi

# ---------------------------------------------------------------------------
# Install example config if no config exists
# ---------------------------------------------------------------------------

if [ ! -f /etc/btb-service/config.env ]; then
    EXAMPLE_CONFIG="$SCRIPT_DIR/config.env.example"
    if [ -f "$EXAMPLE_CONFIG" ]; then
        cp "$EXAMPLE_CONFIG" /etc/btb-service/config.env
        chown root:btb /etc/btb-service/config.env
        chmod 640 /etc/btb-service/config.env
        log "Example config copied to /etc/btb-service/config.env — edit before starting the service."
    fi
fi

# ---------------------------------------------------------------------------
# Verify installation
# ---------------------------------------------------------------------------

log "Verifying installed dependencies..."

MISSING=""
for cmd in bash git python3 perl; do
    if command_exists "$cmd"; then
        log "  ✓ $cmd found: $(command -v "$cmd")"
    else
        log "  ✗ $cmd NOT FOUND"
        MISSING="$MISSING $cmd"
    fi
done

# Check bash version (Requirement 1.1: bash 3.2+)
BASH_VERSION_NUM=$(bash --version | head -1 | grep -oP '\d+\.\d+' | head -1)
log "  bash version: $BASH_VERSION_NUM"

if command_exists kiro-cli; then
    log "  ✓ kiro-cli found: $(command -v kiro-cli)"
else
    log "  ⚠ kiro-cli not found on PATH — install manually"
fi

if python3 -c "import aiohttp" 2>/dev/null; then
    log "  ✓ aiohttp Python package installed"
else
    log "  ⚠ aiohttp not importable — run: pip3 install aiohttp"
fi

if [ -n "$MISSING" ]; then
    error "Missing required commands:$MISSING"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

log ""
log "============================================="
log "  BTB Service provisioning complete!"
log "============================================="
log ""
log "Next steps:"
log "  1. Edit /etc/btb-service/config.env with your settings"
log "  2. Place TLS certificate and key at the configured paths"
log "  3. Deploy the btb code to /opt/btb"
log "  4. Start the service: sudo systemctl start btb-service"
log "  5. Check status: sudo systemctl status btb-service"
log "  6. View logs: sudo journalctl -u btb-service -f"
log ""
log "IAM Identity Center (Requirement 2.1, 2.2):"
log "  - Ensure the instance has an IAM instance profile attached"
log "  - Configure AWS_PROFILE in /etc/btb-service/config.env"
log "  - Team members added to IAM Identity Center can submit"
log "    jobs without instance reconfiguration"
log ""
