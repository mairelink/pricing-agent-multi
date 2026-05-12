#!/usr/bin/env bash
# ============================================================================
# BigQuery MCP Server (stdio transport)
# A minimal MCP server that reads JSON-RPC from stdin and writes to stdout.
# Provides: bq_query, bq_check_item, bq_list_tables
#
# Requirements: gcloud CLI with bq component, jq
# Auth: uses Application Default Credentials (gcloud auth application-default login)
# ============================================================================

set -euo pipefail

# Load environment variables from .env if it exists
if [ -f "$(dirname "$0")/../../.env" ]; then
    set -a
    source "$(dirname "$0")/../../.env"
    set +a
fi

# Configuration — override via env vars
GCP_PROJECT="${GCP_PROJECT:-your-gcp-project}"
BQ_DATASET="${BQ_DATASET:-pricing}"

# ── Helpers ──────────────────────────────────────────────────────────────────

json_rpc_response() {
    local id="$1"
    local result="$2"
    printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$id" "$result"
}

json_rpc_error() {
    local id="$1"
    local code="$2"
    local message="$3"
    printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%d,"message":"%s"}}\n' "$id" "$code" "$message"
}

# Escape a string for safe JSON embedding
json_escape() {
    python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<< "$1"
}

# ── Tool implementations ────────────────────────────────────────────────────

tool_bq_query() {
    local sql="$1"
    local project="${2:-$GCP_PROJECT}"
    # Safety: only allow SELECT/WITH
    local upper_sql
    upper_sql=$(echo "$sql" | tr '[:lower:]' '[:upper:]' | xargs)
    if [[ ! "$upper_sql" =~ ^(SELECT|WITH) ]]; then
        echo "ERROR: Only SELECT/WITH queries are allowed."
        return 1
    fi

    bq query \
        --project_id="$project" \
        --use_legacy_sql=false \
        --format=prettyjson \
        --max_rows=50 \
        "$sql" 2>&1
}

tool_bq_check_item() {
    local item_number="$1"
    local project="${2:-$GCP_PROJECT}"
    local dataset="${3:-$BQ_DATASET}"
    local sql="SELECT item_number, pricelist, price, currency, valid_from, valid_to, status, last_updated
FROM \`${project}.${dataset}.item_prices\`
WHERE item_number = '${item_number}'
ORDER BY valid_from DESC
LIMIT 20"

    bq query \
        --project_id="$project" \
        --use_legacy_sql=false \
        --format=prettyjson \
        --max_rows=50 \
        "$sql" 2>&1
}

tool_bq_check_errors() {
    local item_number="$1"
    local project="${2:-$GCP_PROJECT}"
    local dataset="${3:-$BQ_DATASET}"
    local sql="SELECT item_number, error_type, error_message, source, created_at
FROM \`${project}.${dataset}.processing_errors\`
WHERE item_number = '${item_number}'
ORDER BY created_at DESC
LIMIT 10"

    bq query \
        --project_id="$project" \
        --use_legacy_sql=false \
        --format=prettyjson \
        --max_rows=50 \
        "$sql" 2>&1
}

tool_bq_check_pricat_files() {
    local item_number="$1"
    local project="${2:-$GCP_PROJECT}"
    local dataset="${3:-$BQ_DATASET}"
    local sql="SELECT customer_id, pricelist, file_name, status, created_at
FROM \`${project}.${dataset}.pricat_files\`
WHERE file_name LIKE '%${item_number}%'
ORDER BY created_at DESC
LIMIT 10"

    bq query \
        --project_id="$project" \
        --use_legacy_sql=false \
        --format=prettyjson \
        --max_rows=50 \
        "$sql" 2>&1
}

tool_bq_list_tables() {
    local dataset="${1:-$BQ_DATASET}"
    local project="${2:-$GCP_PROJECT}"
    bq ls --project_id="$project" --format=prettyjson "${project}:${dataset}" 2>&1
}

# ── MCP Protocol handler ────────────────────────────────────────────────────

handle_request() {
    local request="$1"
    local id method params

    id=$(echo "$request" | jq -r '.id')
    method=$(echo "$request" | jq -r '.method')

    case "$method" in
        "initialize")
            json_rpc_response "$id" '{"protocolVersion": "2024-11-05", "serverInfo": {"name": "bigquery-mcp", "version": "0.1.0"}, "capabilities": {"tools": {"listChanged": false}}}'
            ;;

        "notifications/initialized")
            # No response needed for notifications
            ;;

        "tools/list")
            json_rpc_response "$id" '{"tools": [{"name": "bq_query", "description": "Run a BigQuery SQL query (SELECT/WITH only). Returns results as JSON.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string", "description": "SQL query to execute"}, "project_id": {"type": "string", "description": "Optional GCP project ID"}}, "required": ["sql"]}}, {"name": "bq_check_item", "description": "Look up all pricing records for an item number in the item_prices table.", "inputSchema": {"type": "object", "properties": {"item_number": {"type": "string", "description": "Item/article number to look up"}, "project_id": {"type": "string", "description": "Optional GCP project ID"}, "dataset": {"type": "string", "description": "Optional dataset name"}}, "required": ["item_number"]}}, {"name": "bq_check_errors", "description": "Check for processing errors related to an item number.", "inputSchema": {"type": "object", "properties": {"item_number": {"type": "string", "description": "Item number to check errors for"}, "project_id": {"type": "string", "description": "Optional GCP project ID"}, "dataset": {"type": "string", "description": "Optional dataset name"}}, "required": ["item_number"]}}, {"name": "bq_check_pricat_files", "description": "Check PRICAT files related to an item number.", "inputSchema": {"type": "object", "properties": {"item_number": {"type": "string", "description": "Item number to search for in file names"}, "project_id": {"type": "string", "description": "Optional GCP project ID"}, "dataset": {"type": "string", "description": "Optional dataset name"}}, "required": ["item_number"]}}, {"name": "bq_list_tables", "description": "List all tables in a BigQuery dataset.", "inputSchema": {"type": "object", "properties": {"dataset": {"type": "string", "description": "Optional dataset name"}, "project_id": {"type": "string", "description": "Optional GCP project ID"}}}]}'
            ;;

        "tools/call")
            local tool_name tool_args result
            tool_name=$(echo "$request" | jq -r '.params.name')
            tool_args=$(echo "$request" | jq -r '.params.arguments')

            case "$tool_name" in
                "bq_query")
                    local sql project
                    sql=$(echo "$tool_args" | jq -r '.sql')
                    project=$(echo "$tool_args" | jq -r '.project_id // empty')
                    result=$(tool_bq_query "$sql" "$project" 2>&1) || true
                    ;;
                "bq_check_item")
                    local item project dataset
                    item=$(echo "$tool_args" | jq -r '.item_number')
                    project=$(echo "$tool_args" | jq -r '.project_id // empty')
                    dataset=$(echo "$tool_args" | jq -r '.dataset // empty')
                    result=$(tool_bq_check_item "$item" "$project" "$dataset" 2>&1) || true
                    ;;
                "bq_check_errors")
                    local item project dataset
                    item=$(echo "$tool_args" | jq -r '.item_number')
                    project=$(echo "$tool_args" | jq -r '.project_id // empty')
                    dataset=$(echo "$tool_args" | jq -r '.dataset // empty')
                    result=$(tool_bq_check_errors "$item" "$project" "$dataset" 2>&1) || true
                    ;;
                "bq_check_pricat_files")
                    local item project dataset
                    item=$(echo "$tool_args" | jq -r '.item_number')
                    project=$(echo "$tool_args" | jq -r '.project_id // empty')
                    dataset=$(echo "$tool_args" | jq -r '.dataset // empty')
                    result=$(tool_bq_check_pricat_files "$item" "$project" "$dataset" 2>&1) || true
                    ;;
                "bq_list_tables")
                    local dataset project
                    dataset=$(echo "$tool_args" | jq -r '.dataset // empty')
                    project=$(echo "$tool_args" | jq -r '.project_id // empty')
                    result=$(tool_bq_list_tables "$dataset" "$project" 2>&1) || true
                    ;;
                *)
                    result="Unknown tool: $tool_name"
                    ;;
            esac

            local escaped_result
            escaped_result=$(json_escape "$result")
            json_rpc_response "$id" "$(printf '{"content":[{"type":"text","text":%s}]}' "$escaped_result")"
            ;;

        *)
            json_rpc_error "$id" -32601 "Method not found: $method"
            ;;
    esac
}

# ── Main loop: read JSON-RPC from stdin ──────────────────────────────────────

while IFS= read -r line; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    handle_request "$line"
done
