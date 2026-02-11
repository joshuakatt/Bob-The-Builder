#!/bin/bash
# =============================================================================
# BTB Service — GitHub Webhook Setup Helper
# =============================================================================
#
# Configures a GitHub webhook on a repository to send push events to the
# BTB Service instance.
#
# Prerequisites:
#   - GITHUB_TOKEN environment variable set with a token that has
#     "admin:repo_hook" permission on the target repository
#   - curl installed
#
# Usage:
#   export GITHUB_TOKEN=ghp_your_token_here
#   bash deploy/setup-webhook.sh <owner/repo> <instance-url> <webhook-secret>
#
# Example:
#   export GITHUB_TOKEN=ghp_abc123
#   bash deploy/setup-webhook.sh myorg/myrepo https://ec2-1-2-3-4.compute.amazonaws.com:8443 my-secret
#
# This creates a webhook that:
#   - Sends push events only
#   - Uses application/json content type
#   - Validates payloads with the provided secret (HMAC-SHA256)
#   - Points to https://<instance-url>/webhook
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[setup-webhook] $*"
}

error() {
    echo "[setup-webhook] ERROR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <owner/repo> <instance-url> <webhook-secret>"
    echo ""
    echo "Arguments:"
    echo "  owner/repo       GitHub repository (e.g., myorg/myrepo)"
    echo "  instance-url     BTB Service URL (e.g., https://ec2-1-2-3-4.compute.amazonaws.com:8443)"
    echo "  webhook-secret   Shared secret for webhook signature validation"
    echo ""
    echo "Environment:"
    echo "  GITHUB_TOKEN     Required. GitHub token with admin:repo_hook permission."
    echo ""
    echo "Example:"
    echo "  export GITHUB_TOKEN=ghp_abc123"
    echo "  $0 myorg/myrepo https://my-instance:8443 my-webhook-secret"
    exit 1
}

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------

if [ $# -ne 3 ]; then
    usage
fi

REPO="$1"
INSTANCE_URL="$2"
WEBHOOK_SECRET="$3"

# Validate GITHUB_TOKEN is set
if [ -z "${GITHUB_TOKEN:-}" ]; then
    error "GITHUB_TOKEN environment variable is not set."
fi

# Validate repo format (owner/repo)
if ! echo "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    error "Invalid repository format: '$REPO'. Expected: owner/repo"
fi

# Strip trailing slash from instance URL
INSTANCE_URL="${INSTANCE_URL%/}"

# Build the webhook URL
WEBHOOK_URL="${INSTANCE_URL}/webhook"

log "Repository:  $REPO"
log "Webhook URL: $WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Create the webhook via GitHub API
# ---------------------------------------------------------------------------

log "Creating webhook..."

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/${REPO}/hooks" \
    -d @- <<EOF
{
  "name": "web",
  "active": true,
  "events": ["push"],
  "config": {
    "url": "${WEBHOOK_URL}",
    "content_type": "json",
    "secret": "${WEBHOOK_SECRET}",
    "insecure_ssl": "0"
  }
}
EOF
)

# Extract HTTP status code (last line) and response body
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

# ---------------------------------------------------------------------------
# Handle response
# ---------------------------------------------------------------------------

case "$HTTP_CODE" in
    201)
        HOOK_ID=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "unknown")
        log "✓ Webhook created successfully!"
        log "  Hook ID: $HOOK_ID"
        log "  URL:     $WEBHOOK_URL"
        log "  Events:  push"
        log ""
        log "The webhook is now active. Push events to $REPO will be"
        log "sent to your BTB Service instance."
        ;;
    401)
        error "Authentication failed. Check your GITHUB_TOKEN."
        ;;
    403)
        error "Permission denied. Ensure your token has 'admin:repo_hook' permission on $REPO."
        ;;
    404)
        error "Repository not found: $REPO. Check the repository name and token permissions."
        ;;
    422)
        # 422 often means the webhook already exists
        log "⚠ GitHub returned 422 (Unprocessable Entity)."
        log "  This usually means a webhook with this URL already exists."
        log "  Response: $BODY"
        log ""
        log "To list existing webhooks:"
        log "  curl -H 'Authorization: token \$GITHUB_TOKEN' https://api.github.com/repos/$REPO/hooks"
        ;;
    *)
        error "Unexpected response (HTTP $HTTP_CODE): $BODY"
        ;;
esac
