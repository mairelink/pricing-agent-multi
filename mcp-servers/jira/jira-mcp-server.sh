#!/usr/bin/env bash
# ============================================================================
# Jira MCP Server (stdio transport)
# Provides: jira_get_issue, jira_search, jira_comment
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

JIRA_URL="${JIRA_URL:-https://yourcompany.atlassian.net}"
JIRA_USER="${JIRA_USER:-}"
JIRA_TOKEN="${JIRA_TOKEN:-}"
JIRA_PROJECT="${JIRA_PROJECT:-PRICE}"

AUTH_HEADER=$(echo -n "${JIRA_USER}:${JIRA_TOKEN}" | base64)

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

# ── Tool implementations ────────────────────────────────────────────────────

tool_jira_get_issue() {
    local issue_key="$1"

    local response
    response=$(curl -s -X GET \
        "${JIRA_URL}/rest/api/3/issue/${issue_key}?fields=summary,description,status,assignee,priority,comment,created" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Accept: application/json" \
        2>&1) || true

    # Format the response
    python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
fields = data.get('fields', {})
key = data.get('key', 'Unknown')
summary = fields.get('summary', 'No summary')
status = fields.get('status', {}).get('name', 'Unknown')
assignee = (fields.get('assignee') or {}).get('displayName', 'Unassigned')
priority = fields.get('priority', {}).get('name', 'None')
created = (fields.get('created') or '')[:10]

# Description (handle ADF format)
desc = fields.get('description', '')
if isinstance(desc, dict):
    # ADF - extract text content
    parts = []
    for block in desc.get('content', []):
        for item in block.get('content', []):
            if item.get('type') == 'text':
                parts.append(item.get('text', ''))
    desc = ' '.join(parts)
desc = (desc or 'No description')[:800]

# Comments
comments = fields.get('comment', {}).get('comments', [])
comment_text = ''
if comments:
    recent = comments[-3:]
    lines = []
    for c in recent:
        author = c.get('author', {}).get('displayName', 'Unknown')
        body = c.get('body', '')
        if isinstance(body, dict):
            parts = []
            for block in body.get('content', []):
                for item in block.get('content', []):
                    if item.get('type') == 'text':
                        parts.append(item.get('text', ''))
            body = ' '.join(parts)
        lines.append(f'  [{author}]: {str(body)[:300]}')
    comment_text = '\nRecent comments:\n' + '\n'.join(lines)

print(f'''Issue: {key}
Summary: {summary}
Status: {status} | Priority: {priority} | Assignee: {assignee}
Created: {created}
Description: {desc}{comment_text}''')
" <<< "$response" 2>/dev/null || echo "Error parsing issue: $response"
}

tool_jira_search() {
    local jql="$1"

    local response
    response=$(curl -s -X GET \
        "${JIRA_URL}/rest/api/3/search" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Accept: application/json" \
        --data-urlencode "jql=${jql}" \
        --data-urlencode "maxResults=15" \
        --data-urlencode "fields=summary,status" \
        2>&1) || true

    echo "$response" | jq -r '
        .issues // [] | map(
            "\(.key): \(.fields.summary) [\(.fields.status.name)]"
        ) | join("\n") // "No issues found."
    ' 2>/dev/null || echo "Search failed: $response"
}

tool_jira_comment() {
    local issue_key="$1"
    local comment_text="$2"

    # Build ADF format body
    local body
    body=$(python3 -c "
import json
body = {
    'body': {
        'type': 'doc',
        'version': 1,
        'content': [{
            'type': 'paragraph',
            'content': [{'type': 'text', 'text': '''$comment_text'''}]
        }]
    }
}
print(json.dumps(body))
")

    local response
    response=$(curl -s -X POST \
        "${JIRA_URL}/rest/api/3/issue/${issue_key}/comment" \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        2>&1) || true

    if echo "$response" | jq -e '.id' > /dev/null 2>&1; then
        echo "Comment added to ${issue_key} successfully."
    else
        echo "Error adding comment: $response"
    fi
}

# ── MCP Protocol handler ────────────────────────────────────────────────────

handle_request() {
    local request="$1"
    local id method
    id=$(echo "$request" | jq -r '.id')
    method=$(echo "$request" | jq -r '.method')

    case "$method" in
        "initialize")
            json_rpc_response "$id" '{"protocolVersion": "2024-11-05", "serverInfo": {"name": "jira-mcp", "version": "0.1.0"}, "capabilities": {"tools": {"listChanged": false}}}'
            ;;

        "notifications/initialized") ;;

        "tools/list")
            json_rpc_response "$id" '{"tools": [{"name": "jira_get_issue", "description": "Get full details of a Jira issue including description, status, and recent comments.", "inputSchema": {"type": "object", "properties": {"issue_key": {"type": "string", "description": "Jira issue key (e.g. PRICE-123)"}}, "required": ["issue_key"]}}, {"name": "jira_search", "description": "Search Jira issues using JQL query language.", "inputSchema": {"type": "object", "properties": {"jql": {"type": "string", "description": "JQL query (e.g. project=PRICE AND status=Open)"}}, "required": ["jql"]}}, {"name": "jira_comment", "description": "Add a comment to a Jira issue with investigation findings.", "inputSchema": {"type": "object", "properties": {"issue_key": {"type": "string", "description": "Jira issue key"}, "comment": {"type": "string", "description": "Comment text to add"}}, "required": ["issue_key", "comment"]}}]}'
            ;;

        "tools/call")
            local tool_name tool_args result
            tool_name=$(echo "$request" | jq -r '.params.name')
            tool_args=$(echo "$request" | jq -r '.params.arguments')

            case "$tool_name" in
                "jira_get_issue")
                    local key
                    key=$(echo "$tool_args" | jq -r '.issue_key')
                    result=$(tool_jira_get_issue "$key" 2>&1) || true
                    ;;
                "jira_search")
                    local jql
                    jql=$(echo "$tool_args" | jq -r '.jql')
                    result=$(tool_jira_search "$jql" 2>&1) || true
                    ;;
                "jira_comment")
                    local key comment
                    key=$(echo "$tool_args" | jq -r '.issue_key')
                    comment=$(echo "$tool_args" | jq -r '.comment')
                    result=$(tool_jira_comment "$key" "$comment" 2>&1) || true
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
