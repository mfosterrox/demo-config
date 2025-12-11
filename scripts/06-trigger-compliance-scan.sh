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

# Function to load variable from ~/.bashrc if it exists
load_from_bashrc() {
    local var_name="$1"
    
    # First check if variable is already set in environment
    local env_value=$(eval "echo \${${var_name}:-}")
    if [ -n "$env_value" ]; then
        export "${var_name}=${env_value}"
        echo "$env_value"
        return 0
    fi
    
    # Otherwise, try to load from ~/.bashrc
    if [ -f ~/.bashrc ] && grep -q "^export ${var_name}=" ~/.bashrc; then
        local var_line=$(grep "^export ${var_name}=" ~/.bashrc | head -1)
        local var_value=$(echo "$var_line" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        export "${var_name}=${var_value}"
        echo "$var_value"
    fi
}

# Load environment variables from ~/.bashrc (set by script 01)
log "Loading environment variables from ~/.bashrc..."

# Ensure ~/.bashrc exists
if [ ! -f ~/.bashrc ]; then
    error "~/.bashrc not found. Please run script 01-rhacs-setup.sh first to initialize environment variables."
fi

# Clean up any malformed source commands in bashrc
if grep -q "^source $" ~/.bashrc; then
    log "Cleaning up malformed source commands in ~/.bashrc..."
    sed -i '/^source $/d' ~/.bashrc
fi

# Load SCRIPT_DIR and PROJECT_ROOT (set by script 01)
SCRIPT_DIR=$(load_from_bashrc "SCRIPT_DIR")
PROJECT_ROOT=$(load_from_bashrc "PROJECT_ROOT")

# Load required variables (set by script 01)
ROX_ENDPOINT=$(load_from_bashrc "ROX_ENDPOINT")
ROX_API_TOKEN=$(load_from_bashrc "ROX_API_TOKEN")

# Validate required environment variables
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi

if [ -z "${ROX_ENDPOINT:-}" ]; then
    error "ROX_ENDPOINT not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi
log "✓ Required environment variables validated: ROX_ENDPOINT=$ROX_ENDPOINT"

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
