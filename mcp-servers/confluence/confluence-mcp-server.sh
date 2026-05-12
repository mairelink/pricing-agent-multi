#!/usr/bin/env bash
# ============================================================================
# Confluence MCP Server (stdio transport)
# Provides: confluence_search, confluence_read_page
#
# Requirements: curl, jq, python3
# Auth: Atlassian API token (basic auth)
# ============================================================================

set -euo pipefail

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/../../.env" ]; then
    set -a
    source "$(dirname "$0")/../../.env"
    set +a
fi

CONFLUENCE_URL="${CONFLUENCE_URL:-https://yourcompany.atlassian.net/wiki}"
CONFLUENCE_USER="${CONFLUENCE_USER:-}"
CONFLUENCE_TOKEN="${CONFLUENCE_TOKEN:-}"
CONFLUENCE_SPACE="${CONFLUENCE_SPACE:-PRICING}"

# Base64 auth header
AUTH_HEADER=$(echo -n "${CONFLUENCE_USER}:${CONFLUENCE_TOKEN}" | base64)

json_rpc_response() {
    local id="$1" result="$2"
    printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$result"
}

json_rpc_error() {
    local id="$1" code="$2" message="$3"
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":"%s"}}\n' "$id" "$code" "$message"
}

json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"
}

# Strip HTML tags to get plain text
strip_html() {
    python3 -c "
import re, sys, html
text = sys.stdin.read()
text = re.sub(r'<br\s*/?>', '\n', text)
text = re.sub(r'</(p|div|h[1-6]|li|tr)>', '\n', text)
text = re.sub(r'<[^>]+>', ' ', text)
text = html.unescape(text)
text = re.sub(r' +', ' ', text)
print(text.strip()[:8000])
"
}

# ── Tool implementations ────────────────────────────────────────────────────

tool_confluence_search() {
    local query="$1"
    local cql="type=page AND space=\"${CONFLUENCE_SPACE}\" AND text~\"${query}\""

    local response
    response=$(curl -s -X GET \
        "${CONFLUENCE_URL}/rest/api/content/search" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Accept: application/json" \
        --data-urlencode "cql=${cql}" \
        --data-urlencode "limit=10" \
        2>&1) || true

    # Format results
    echo "$response" | jq -r '
        .results // [] | map(
            "Page: \(.title)\n  ID: \(.id)\n  URL: \(.["_links"].webui // "?")\n"
        ) | join("\n") // "No pages found."
    ' 2>/dev/null || echo "Search failed: $response"
}

tool_confluence_read_page() {
    local page_id="$1"

    local response
    response=$(curl -s -X GET \
        "${CONFLUENCE_URL}/rest/api/content/${page_id}?expand=body.storage" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Accept: application/json" \
        2>&1) || true

    local title body
    title=$(echo "$response" | jq -r '.title // "Unknown"')
    body=$(echo "$response" | jq -r '.body.storage.value // "No content"' | strip_html)

    printf "# %s\n\n%s" "$title" "$body"
}

# ── MCP Protocol handler ────────────────────────────────────────────────────

handle_request() {
    local request="$1"
    local id method
    id=$(echo "$request" | jq -r '.id')
    method=$(echo "$request" | jq -r '.method')

    case "$method" in
        "initialize")
            json_rpc_response "$id" '{"protocolVersion": "2024-11-05", "serverInfo": {"name": "confluence-mcp", "version": "0.1.0"}, "capabilities": {"tools": {"listChanged": false}}}'
            ;;

        "notifications/initialized") ;;

        "tools/list")
            json_rpc_response "$id" '{"tools": [{"name": "confluence_search", "description": "Search Confluence pages by text query. Returns page titles and IDs.", "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "Search text (e.g. pricat process, price missing troubleshooting)"}}, "required": ["query"]}}, {"name": "confluence_read_page", "description": "Read the full text content of a Confluence page by its ID.", "inputSchema": {"type": "object", "properties": {"page_id": {"type": "string", "description": "Confluence page ID (numeric)"}}, "required": ["page_id"]}}]}'
            ;;

        "tools/call")
            local tool_name tool_args result
            tool_name=$(echo "$request" | jq -r '.params.name')
            tool_args=$(echo "$request" | jq -r '.params.arguments')

            case "$tool_name" in
                "confluence_search")
                    local query
                    query=$(echo "$tool_args" | jq -r '.query')
                    result=$(tool_confluence_search "$query" 2>&1) || true
                    ;;
                "confluence_read_page")
                    local page_id
                    page_id=$(echo "$tool_args" | jq -r '.page_id')
                    result=$(tool_confluence_read_page "$page_id" 2>&1) || true
                    ;;
                *)
                    result="Unknown tool: $tool_name"
                    ;;
            esac

            local escaped
            escaped=$(json_escape "$result")
            json_rpc_response "$id" "$(printf '{"content":[{"type":"text","text":%s}]}' "$escaped")"
            ;;

        *)
            json_rpc_error "$id" -32601 "Method not found: $method"
            ;;
    esac
}

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    handle_request "$line"
done
