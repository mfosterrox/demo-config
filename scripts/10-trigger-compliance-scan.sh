#!/bin/bash
# Compliance Management Scan Trigger Script
# Triggers a HIPAA 164 compliance scan for the Production cluster in Red Hat Advanced Cluster Security

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[COMPLIANCE-SCAN]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-SCAN]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-SCAN] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-SCAN] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# RHACS operator namespace
RHACS_OPERATOR_NAMESPACE="rhacs-operator"

# Generate ROX_ENDPOINT from Central route
log "Extracting ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$RHACS_OPERATOR_NAMESPACE'. Please ensure RHACS Central is installed."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Extracted ROX_ENDPOINT: $ROX_ENDPOINT"

# Generate ROX_API_TOKEN (same method as script 09)
log "Generating API token..."
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    error "Admin password secret 'central-htpasswd' not found in namespace '$RHACS_OPERATOR_NAMESPACE'"
fi
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)

# Normalize ROX_ENDPOINT for API calls
normalize_rox_endpoint() {
    local input="$1"
    input="${input#https://}"
    input="${input#http://}"
    input="${input%/}"
    if [[ "$input" != *:* ]]; then
        input="${input}:443"
    fi
    echo "$input"
}

ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"

# Download roxctl if not available (Linux bastion host)
ROXCTL_CMD=""
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, downloading..."
    
    RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
    if [ -z "$RHACS_VERSION" ]; then
        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
    fi
    
    ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/Linux/roxctl"
    ROXCTL_TMP="/tmp/roxctl"
    
    log "Downloading roxctl from: $ROXCTL_URL"
    if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
        log "Retrying with latest version: $ROXCTL_URL"
        if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
            error "Failed to download roxctl. Please install it manually."
        fi
    fi
    
    chmod +x "$ROXCTL_TMP"
    ROXCTL_CMD="$ROXCTL_TMP"
    log "✓ roxctl downloaded to $ROXCTL_TMP"
else
    ROXCTL_CMD="roxctl"
    log "✓ roxctl found in PATH"
fi

# Generate token using API directly with basic auth (more reliable than roxctl)
log "Generating API token using Central API..."
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"

set +e
TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
    -u "admin:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
    -d '{"name":"script-generated-token-trigger","roles":["Admin"]}' 2>&1)
TOKEN_CURL_EXIT_CODE=$?
set -e

if [ $TOKEN_CURL_EXIT_CODE -ne 0 ]; then
    log "API token generation via curl failed, trying roxctl..."
    set +e
    TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
        central token generate \
        --password "$ADMIN_PASSWORD" \
        --insecure-skip-tls-verify 2>&1)
    TOKEN_EXIT_CODE=$?
    set -e
    
    if [ $TOKEN_EXIT_CODE -ne 0 ]; then
        error "Failed to generate API token. roxctl output: ${TOKEN_OUTPUT:0:500}"
    fi
    
    ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
    if [ -z "$ROX_API_TOKEN" ]; then
        ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]' || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        error "Failed to extract API token from roxctl output. Output: ${TOKEN_OUTPUT:0:500}"
    fi
else
    # Extract token from API response
    if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        log "Failed to extract token from API response, trying roxctl fallback..."
        set +e
        TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central token generate \
            --password "$ADMIN_PASSWORD" \
            --insecure-skip-tls-verify 2>&1)
        TOKEN_EXIT_CODE=$?
        set -e
        
        if [ $TOKEN_EXIT_CODE -eq 0 ]; then
            ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
            if [ -z "$ROX_API_TOKEN" ]; then
                ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]' || echo "")
            fi
        fi
    fi
    
    if [ -z "$ROX_API_TOKEN" ]; then
        error "Failed to extract API token. API Response: ${TOKEN_RESPONSE:0:500}"
    fi
fi

# Verify token is not empty and has reasonable length
if [ ${#ROX_API_TOKEN} -lt 20 ]; then
    error "Generated token appears to be invalid (too short: ${#ROX_API_TOKEN} chars)"
fi

log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq is required for this script to work correctly. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# API endpoints
CLUSTERS_ENDPOINT="${ROX_ENDPOINT}/v1/clusters"
STANDARDS_ENDPOINT="${ROX_ENDPOINT}/v1/compliance/standards"
SCAN_ENDPOINT="${ROX_ENDPOINT}/v1/compliancemanagement/runs"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
    # Redirect log to stderr so it's not captured in response
    log "Making $description: $method $endpoint" >&2
    
    local temp_file=""
    local curl_cmd="curl -k -s -w \"\n%{http_code}\" -X $method"
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $ROX_API_TOKEN\""
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
    
    if [ -n "$data" ]; then
        # For multi-line JSON, use a temporary file to avoid quoting issues
        if echo "$data" | grep -q $'\n'; then
            temp_file=$(mktemp)
            echo "$data" > "$temp_file"
            curl_cmd="$curl_cmd --data-binary @\"$temp_file\""
        else
            # Single-line data can use -d directly
            curl_cmd="$curl_cmd -d '$data'"
        fi
    fi
    
    curl_cmd="$curl_cmd \"$endpoint\""
    
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # Clean up temp file if used
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -ne 0 ]; then
        error "$description failed (curl exit code: $exit_code). Response: ${body:0:500}"
    fi
    
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        error "$description failed (HTTP $http_code). Response: ${body:0:500}"
    fi
    
    echo "$body"
}

# Fetch cluster ID - look for "Production" cluster (capital P)
log "========================================================="
log "Finding Production cluster..."
log "========================================================="

CLUSTER_RESPONSE=$(make_api_call "GET" "$CLUSTERS_ENDPOINT" "" "Fetch clusters")

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Parse cluster response
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

# Try to find cluster by name "Production" (capital P as it appears in RHACS)
EXPECTED_CLUSTER_NAME="Production"
CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name == \"$EXPECTED_CLUSTER_NAME\") | .id" 2>/dev/null | head -1)

if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
    # Try case-insensitive match as fallback
    log "Cluster 'Production' not found (case-sensitive), trying case-insensitive match..."
    CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name | ascii_downcase == \"production\") | .id" 2>/dev/null | head -1)
    
    if [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" = "null" ]; then
        error "Production cluster not found. Available clusters: $(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | "\(.name): \(.id)"' 2>/dev/null | tr '\n' ' ' || echo "none")"
    else
        CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .name" 2>/dev/null | head -1)
        log "Found cluster with case-insensitive match: $CLUSTER_NAME"
    fi
fi

# Verify cluster exists and get its name for logging
if [ -z "${CLUSTER_NAME:-}" ] || [ "${CLUSTER_NAME:-}" = "null" ]; then
    CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .name" 2>/dev/null | head -1)
fi

CLUSTER_HEALTH=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .healthStatus.overallHealthStatus // \"UNKNOWN\"" 2>/dev/null | head -1)

if [ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "null" ]; then
    log "✓ Found Production cluster: $CLUSTER_NAME (ID: $CLUSTER_ID, Health: ${CLUSTER_HEALTH:-UNKNOWN})"
else
    log "✓ Using cluster ID: $CLUSTER_ID"
fi

# Verify cluster is connected (not disconnected)
CLUSTER_STATUS=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$CLUSTER_ID\") | .status.connectionStatus // \"UNKNOWN\"" 2>/dev/null | head -1)
if [ "$CLUSTER_STATUS" = "DISCONNECTED" ] || [ "$CLUSTER_STATUS" = "UNINITIALIZED" ]; then
    warning "Cluster $CLUSTER_NAME (ID: $CLUSTER_ID) has status: $CLUSTER_STATUS"
    warning "This may cause scan failures. Ensure the cluster is properly connected to RHACS."
fi

# Fetch HIPAA 164 compliance standard ID
log ""
log "========================================================="
log "Finding HIPAA 164 compliance standard..."
log "========================================================="

COMPLIANCE_STANDARD_ID=""
log "Fetching available compliance standards..."

# Try the compliance standards endpoint
set +e
STANDARDS_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X GET \
    -H "Accept: application/json" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    "$STANDARDS_ENDPOINT" 2>&1) || true
set -e

HTTP_CODE=$(echo "$STANDARDS_RESPONSE" | tail -n1)
STANDARDS_BODY=$(echo "$STANDARDS_RESPONSE" | head -n -1)

if [ "$HTTP_CODE" -eq 200 ] && [ -n "$STANDARDS_BODY" ]; then
    if echo "$STANDARDS_BODY" | jq . >/dev/null 2>&1; then
        # List all available standards for debugging
        log "Available compliance standards:"
        echo "$STANDARDS_BODY" | jq -r 'if type == "array" then .[] | "  - \(.name // .id): \(.id)" elif .standards then .standards[]? | "  - \(.name // .id): \(.id)" else .[]? | "  - \(.name // .id): \(.id)" end' 2>/dev/null || \
        log "  Could not parse standards list"
        
        # Look for HIPAA 164 standard - try multiple structures and patterns
        # First try: direct array or .standards array
        HIPAA_164_ID=$(echo "$STANDARDS_BODY" | jq -r 'if type == "array" then .[] | select(.name | test("HIPAA.*164|164.*HIPAA|hipaa.*164|164.*hipaa"; "i")) | .id elif .standards then .standards[]? | select(.name | test("HIPAA.*164|164.*HIPAA|hipaa.*164|164.*hipaa"; "i")) | .id else .[]? | select(.name | test("HIPAA.*164|164.*HIPAA|hipaa.*164|164.*hipaa"; "i")) | .id end' 2>/dev/null | head -1)
        
        # If not found, try broader search for HIPAA or 164
        if [ -z "$HIPAA_164_ID" ] || [ "$HIPAA_164_ID" = "null" ]; then
            HIPAA_164_ID=$(echo "$STANDARDS_BODY" | jq -r 'if type == "array" then .[] | select(.name | test("HIPAA|hipaa|164"; "i")) | .id elif .standards then .standards[]? | select(.name | test("HIPAA|hipaa|164"; "i")) | .id else .[]? | select(.name | test("HIPAA|hipaa|164"; "i")) | .id end' 2>/dev/null | head -1)
        fi
        
        # Try matching by ID if name contains HIPAA or 164
        if [ -z "$HIPAA_164_ID" ] || [ "$HIPAA_164_ID" = "null" ]; then
            HIPAA_164_ID=$(echo "$STANDARDS_BODY" | jq -r 'if type == "array" then .[] | select(.id | test("HIPAA|hipaa|164"; "i")) | .id elif .standards then .standards[]? | select(.id | test("HIPAA|hipaa|164"; "i")) | .id else .[]? | select(.id | test("HIPAA|hipaa|164"; "i")) | .id end' 2>/dev/null | head -1)
        fi
        
        if [ -n "$HIPAA_164_ID" ] && [ "$HIPAA_164_ID" != "null" ]; then
            COMPLIANCE_STANDARD_ID="$HIPAA_164_ID"
            HIPAA_NAME=$(echo "$STANDARDS_BODY" | jq -r "if type == \"array\" then .[] | select(.id == \"$HIPAA_164_ID\") | .name elif .standards then .standards[]? | select(.id == \"$HIPAA_164_ID\") | .name else .[]? | select(.id == \"$HIPAA_164_ID\") | .name end" 2>/dev/null || echo "HIPAA 164")
            log "✓ Found HIPAA 164 standard: $HIPAA_NAME (ID: $COMPLIANCE_STANDARD_ID)"
        else
            warning "HIPAA 164 standard not found in standards list"
            log "Full standards response for debugging:"
            echo "$STANDARDS_BODY" | jq . 2>/dev/null || echo "$STANDARDS_BODY"
        fi
    else
        warning "Invalid JSON response from standards API. Response: ${STANDARDS_BODY:0:300}"
    fi
else
    warning "Failed to fetch standards (HTTP $HTTP_CODE). Response: ${STANDARDS_BODY:0:300}"
fi

# If still no standard ID, try to get it from existing runs
if [ -z "$COMPLIANCE_STANDARD_ID" ] || [ "$COMPLIANCE_STANDARD_ID" = "null" ]; then
    log "Trying to get HIPAA 164 standard ID from existing compliance runs..."
    set +e
    RUNS_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X GET \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$SCAN_ENDPOINT" 2>&1) || true
    set -e
    
    RUNS_HTTP_CODE=$(echo "$RUNS_RESPONSE" | tail -n1)
    RUNS_BODY=$(echo "$RUNS_RESPONSE" | head -n -1)
    
    if [ "$RUNS_HTTP_CODE" -eq 200 ] && [ -n "$RUNS_BODY" ]; then
        if echo "$RUNS_BODY" | jq . >/dev/null 2>&1; then
            # Try to extract standardId from existing runs that might be HIPAA 164
            COMPLIANCE_STANDARD_ID=$(echo "$RUNS_BODY" | jq -r '.runs[]? | select(.selection.standardId? != null) | .selection.standardId' 2>/dev/null | head -1)
            if [ -n "$COMPLIANCE_STANDARD_ID" ] && [ "$COMPLIANCE_STANDARD_ID" != "null" ]; then
                log "✓ Found compliance standard ID from existing runs: $COMPLIANCE_STANDARD_ID"
                warning "Note: Using standard from existing runs. Verify this is HIPAA 164."
            fi
        fi
    fi
fi

# If we still don't have a standard ID, we must error since API requires it
if [ -z "$COMPLIANCE_STANDARD_ID" ] || [ "$COMPLIANCE_STANDARD_ID" = "null" ]; then
    error "Could not find HIPAA 164 compliance standard ID. Please ensure HIPAA 164 standard is configured in RHACS. Check available standards: curl -k -X GET \"$STANDARDS_ENDPOINT\" -H \"Accept: application/json\" -H \"Authorization: Bearer \$ROX_API_TOKEN\" | jq ."
fi

# Trigger compliance management scan with HIPAA 164
log ""
log "========================================================="
log "Triggering HIPAA 164 compliance scan..."
log "========================================================="
log "Endpoint: $SCAN_ENDPOINT"
log "Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "Standard: HIPAA 164 (ID: $COMPLIANCE_STANDARD_ID)"

# Prepare scan request payload with selection object
SCAN_PAYLOAD=$(cat <<EOF
{
  "selection": {
    "clusterId": "$CLUSTER_ID",
    "standardId": "$COMPLIANCE_STANDARD_ID"
  }
}
EOF
)

# Make POST request to trigger the scan
SCAN_RESPONSE=$(make_api_call "POST" "$SCAN_ENDPOINT" "$SCAN_PAYLOAD" "Trigger HIPAA 164 compliance scan")

log "✓ HIPAA 164 compliance scan triggered successfully"

# Parse and display response if available
if [ -n "$SCAN_RESPONSE" ]; then
    if echo "$SCAN_RESPONSE" | jq . >/dev/null 2>&1; then
        log "Scan response:"
        echo "$SCAN_RESPONSE" | jq '.' 2>/dev/null || echo "$SCAN_RESPONSE"
        
        # Try to extract scan ID or status if present
        SCAN_ID=$(echo "$SCAN_RESPONSE" | jq -r '.id // .scanId // .runId // empty' 2>/dev/null || echo "")
        if [ -n "$SCAN_ID" ] && [ "$SCAN_ID" != "null" ]; then
            log "✓ Scan ID: $SCAN_ID"
        fi
        
        SCAN_STATUS=$(echo "$SCAN_RESPONSE" | jq -r '.status // .state // empty' 2>/dev/null || echo "")
        if [ -n "$SCAN_STATUS" ] && [ "$SCAN_STATUS" != "null" ]; then
            log "✓ Scan Status: $SCAN_STATUS"
        fi
    else
        log "Response received: $SCAN_RESPONSE"
    fi
fi

log ""
log "========================================================="
log "HIPAA 164 Compliance Scan Trigger Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - Cluster: $CLUSTER_NAME (ID: $CLUSTER_ID)"
log "  - Standard: HIPAA 164 (ID: $COMPLIANCE_STANDARD_ID)"
log "  - Scan endpoint: $SCAN_ENDPOINT"
log ""
log "The scan is now running. It may take several minutes to complete."
log "You can monitor progress in RHACS UI: Compliance → Coverage tab"
log ""
