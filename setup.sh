#!/usr/bin/env bash
# ============================================================================
# Pricing Support Agent — One-command setup for GCP Workstation
#
# Usage:  chmod +x setup.sh && ./setup.sh
# ============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
ask()   { echo -e "${YELLOW}[?]${NC} $1"; }

echo ""
echo "=========================================="
echo "  Pricing Support Agent — Setup"
echo "=========================================="
echo ""

# ── 1. Check / install OpenCode ──────────────────────────────────────────────

if command -v opencode &> /dev/null; then
    info "OpenCode is installed: $(opencode --version 2>/dev/null || echo 'unknown version')"
else
    warn "OpenCode not found. Installing..."
    curl -fsSL https://opencode.ai/install | bash
    info "OpenCode installed"
fi

# ── 2. Check / install Node.js (needed for GitHub MCP) ──────────────────────

if command -v npx &> /dev/null; then
    info "Node.js is installed: $(node --version)"
else
    warn "Node.js not found. Installing..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
    info "Node.js installed: $(node --version)"
fi

# ── 3. Check required CLI tools ─────────────────────────────────────────────

for cmd in bq gcloud curl jq python3; do
    if command -v "$cmd" &> /dev/null; then
        info "$cmd is available"
    else
        echo -e "${RED}[✗]${NC} $cmd is not installed. Please install it."
        exit 1
    fi
done

# ── 4. Configure credentials ────────────────────────────────────────────────

echo ""
echo "── Credentials ──"
echo ""

ENV_FILE=".env"
[ ! -f "$ENV_FILE" ] && touch "$ENV_FILE"

save_env() {
    local key="$1"
    local value="$2"
    # Remove existing entry and append new one
    grep -v "^$key=" "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    echo "$key=\"$value\"" >> "${ENV_FILE}.tmp"
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

# Load existing .env if present
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a || true

# GitHub
if [ -z "${GITHUB_TOKEN:-}" ]; then
    ask "Enter your GitHub Personal Access Token:"
    read -r GITHUB_TOKEN
    save_env "GITHUB_TOKEN" "$GITHUB_TOKEN"
    info "GitHub token saved to $ENV_FILE"
else
    info "GitHub token is set"
fi

# GCP Project
if [ -z "${GCP_PROJECT:-}" ]; then
    ask "Enter your GCP Project ID:"
    read -r GCP_PROJECT
    save_env "GCP_PROJECT" "$GCP_PROJECT"
    info "GCP project saved"
else
    info "GCP project: $GCP_PROJECT"
fi

if [ -z "${BQ_DATASET:-}" ]; then
    BQ_DATASET="pricing"
    save_env "BQ_DATASET" "$BQ_DATASET"
fi
info "BQ dataset: $BQ_DATASET"

# Check GCP auth
if gcloud auth application-default print-access-token &> /dev/null; then
    info "GCP Application Default Credentials are set"
else
    warn "GCP credentials not found. Running gcloud auth..."
    gcloud auth application-default login
fi

# Confluence
if [ -z "${CONFLUENCE_URL:-}" ]; then
    ask "Enter your Confluence URL (e.g. https://yourcompany.atlassian.net/wiki):"
    read -r CONFLUENCE_URL
    save_env "CONFLUENCE_URL" "$CONFLUENCE_URL"

    ask "Enter your Confluence email:"
    read -r CONFLUENCE_USER
    save_env "CONFLUENCE_USER" "$CONFLUENCE_USER"

    ask "Enter your Atlassian API token (from https://id.atlassian.com/manage-profile/security/api-tokens):"
    read -rs CONFLUENCE_TOKEN
    echo ""
    save_env "CONFLUENCE_TOKEN" "$CONFLUENCE_TOKEN"

    CONFLUENCE_SPACE="PRICING"
    ask "Confluence space key [PRICING]:"
    read -r input
    CONFLUENCE_SPACE="${input:-PRICING}"
    save_env "CONFLUENCE_SPACE" "$CONFLUENCE_SPACE"
    info "Confluence credentials saved"
else
    info "Confluence is configured: $CONFLUENCE_URL"
fi

# Jira (uses same Atlassian credentials)
if [ -z "${JIRA_URL:-}" ]; then
    JIRA_URL="${CONFLUENCE_URL%/wiki}"  # Strip /wiki to get base Jira URL
    save_env "JIRA_URL" "$JIRA_URL"
    save_env "JIRA_USER" "$CONFLUENCE_USER"
    save_env "JIRA_TOKEN" "$CONFLUENCE_TOKEN"
    
    JIRA_PROJECT="PRICE"
    ask "Jira project key [PRICE]:"
    read -r input
    JIRA_PROJECT="${input:-PRICE}"
    save_env "JIRA_PROJECT" "$JIRA_PROJECT"
    
    info "Jira configured (same Atlassian credentials): $JIRA_URL"
else
    info "Jira is configured: $JIRA_URL"
fi

# Reload
[ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a || true

# ── 5. Make scripts executable ───────────────────────────────────────────────

chmod +x mcp-servers/*/*.sh
info "MCP server scripts are executable"

# ── 6. Configure OpenCode auth ───────────────────────────────────────────────

echo ""
echo "── LLM Provider ──"
echo ""

if opencode auth list 2>/dev/null | grep -qE "anthropic|Vercel AI Gateway"; then
    info "LLM provider is configured"
else
    warn "No LLM provider configured. Let's set one up."
    opencode auth login
fi

# ── 7. Verify everything works ───────────────────────────────────────────────

echo ""
echo "── Verification ──"
echo ""

# Test BigQuery
if bq query --project_id="$GCP_PROJECT" --use_legacy_sql=false --max_rows=1 \
    "SELECT 1 as test" &> /dev/null; then
    info "BigQuery connection works"
else
    warn "BigQuery connection failed — check your GCP credentials"
fi

# Test Confluence
if curl -sf -u "$CONFLUENCE_USER:$CONFLUENCE_TOKEN" \
    "$CONFLUENCE_URL/rest/api/content/search?cql=type=page&limit=1" > /dev/null 2>&1; then
    info "Confluence connection works"
else
    warn "Confluence connection failed — check your token"
fi

# Test Jira
if curl -sf -u "$JIRA_USER:$JIRA_TOKEN" \
    "$JIRA_URL/rest/api/3/myself" > /dev/null 2>&1; then
    info "Jira connection works"
else
    warn "Jira connection failed — check your token"
fi

# Test GitHub
if curl -sf -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/user" > /dev/null 2>&1; then
    info "GitHub connection works"
else
    warn "GitHub connection failed — check your token"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo -e "  ${GREEN}Setup complete!${NC}"
echo "=========================================="
echo ""
echo "  Test it now:"
echo ""
echo "    opencode run --agent pricing-support \\"
echo "      \"Item 24216B25MMNYB on RRON webshop gives Cannot be priced\""
echo ""
echo "  Or interactive mode:"
echo ""
echo "    opencode"
echo "    (press Tab to switch to pricing-support)"
echo ""
