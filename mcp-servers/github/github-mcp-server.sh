#!/usr/bin/env bash
# ============================================================================
# GitHub MCP Server (stdio transport)
# Wraps the official @modelcontextprotocol/server-github
# ============================================================================

set -euo pipefail

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/../../.env" ]; then
    set -a
    source "$(dirname "$0")/../../.env"
    set +a
fi

# The official server expects GITHUB_PERSONAL_ACCESS_TOKEN
export GITHUB_PERSONAL_ACCESS_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
    echo "ERROR: GITHUB_TOKEN or GITHUB_PERSONAL_ACCESS_TOKEN not set" >&2
    exit 1
fi

exec npx -y @modelcontextprotocol/server-github "$@"
