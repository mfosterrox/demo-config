#!/bin/bash
# RHACS Secured Cluster Setup Script
# Creates RHACS secured cluster services

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

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

# Function to reload variables from ~/.bashrc
reload_bashrc_vars() {
    if [ -f ~/.bashrc ]; then
        set +u  # Temporarily disable unbound variable checking
        source ~/.bashrc || true
        set -u  # Re-enable unbound variable checking
        
        # Explicitly extract variables to ensure they're loaded
        if grep -q "^export ROX_ENDPOINT=" ~/.bashrc; then
            ROX_ENDPOINT_LINE=$(grep "^export ROX_ENDPOINT=" ~/.bashrc | head -1)
            ROX_ENDPOINT=$(echo "$ROX_ENDPOINT_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
            export ROX_ENDPOINT="$ROX_ENDPOINT"
        fi
        
        if grep -q "^export ROX_API_TOKEN=" ~/.bashrc; then
            ROX_API_TOKEN_LINE=$(grep "^export ROX_API_TOKEN=" ~/.bashrc | head -1)
            ROX_API_TOKEN=$(echo "$ROX_API_TOKEN_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
            export ROX_API_TOKEN="$ROX_API_TOKEN"
        fi
        
        if grep -q "^export ADMIN_PASSWORD=" ~/.bashrc; then
            ADMIN_PASSWORD_LINE=$(grep "^export ADMIN_PASSWORD=" ~/.bashrc | head -1)
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
            export ADMIN_PASSWORD="$ADMIN_PASSWORD"
        fi
        
        if grep -q "^export TUTORIAL_HOME=" ~/.bashrc; then
            TUTORIAL_HOME_LINE=$(grep "^export TUTORIAL_HOME=" ~/.bashrc | head -1)
            TUTORIAL_HOME=$(echo "$TUTORIAL_HOME_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
            export TUTORIAL_HOME="$TUTORIAL_HOME"
        fi
    fi
}

# Check for existing API token in ~/.bashrc
TOKEN_FROM_BASHRC=false
TOKEN_FROM_ENV=false

if [ -f ~/.bashrc ]; then
    # Extract ROX_API_TOKEN from ~/.bashrc if it exists
    # Handle both double quotes and single quotes, and unquoted values
    # grep returns 1 if no match (which is OK), so use || true to prevent script failure
    TOKEN_LINE=$(grep "^export ROX_API_TOKEN=" ~/.bashrc 2>/dev/null | head -1 || true)
    
    if [ -n "$TOKEN_LINE" ]; then
        # Extract token value using awk (more reliable than sed for this)
        # Handles: export ROX_API_TOKEN="value", export ROX_API_TOKEN='value', export ROX_API_TOKEN=value
        EXISTING_TOKEN=$(echo "$TOKEN_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        
        if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "=" ]; then
            ROX_API_TOKEN="$EXISTING_TOKEN"
            TOKEN_FROM_BASHRC=true
            log "Found existing ROX_API_TOKEN in ~/.bashrc"
        fi
    fi
fi

# Note: If bashrc was sourced earlier, ROX_API_TOKEN may already be in environment
# But we've now explicitly checked bashrc, so we'll use that value

# Configuration variables
NAMESPACE="tssc-acs"
CLUSTER_NAME="ads-cluster"
TOKEN_NAME="setup-script-$(date +%d-%m-%Y_%H-%M-%S)"
TOKEN_ROLE="Admin"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Load existing environment variables from ~/.bashrc if available
if [ -f ~/.bashrc ]; then
    if grep -q "^source $" ~/.bashrc; then
        warning "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    set +u  # Temporarily disable unbound variable checking for sourcing
    if source ~/.bashrc; then
        log "Loaded environment variables from ~/.bashrc"
    else
        warning "Failed to source ~/.bashrc, continuing with current environment"
    fi
    set -u  # Re-enable unbound variable checking
    
    # Validate required variables for subsequent scripts
    log "Validating required environment variables for all scripts..."
    MISSING_VARS=()
    
    # Variables required by scripts 03, 04, 05
    if [ -z "${ROX_ENDPOINT:-}" ]; then
        MISSING_VARS+=("ROX_ENDPOINT")
    else
        log "✓ ROX_ENDPOINT is set"
    fi
    
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        MISSING_VARS+=("ROX_API_TOKEN")
    else
        log "✓ ROX_API_TOKEN is set"
    fi
    
    # Optional variables (will be set by this script if missing)
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        log "  ADMIN_PASSWORD not set (will be extracted from secret by this script)"
    else
        log "✓ ADMIN_PASSWORD is set"
    fi
    
    if [ -z "${TUTORIAL_HOME:-}" ]; then
        log "  TUTORIAL_HOME not set (will be set by script 03-deploy-applications.sh)"
    else
        log "✓ TUTORIAL_HOME is set"
    fi
    
    # Report missing required variables and generate them
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        warning "Missing required environment variables: ${MISSING_VARS[*]}"
        warning "These variables are required by:"
        for var in "${MISSING_VARS[@]}"; do
            case "$var" in
                ROX_ENDPOINT)
                    warning "  - $var: Required by scripts 03, 04, 05"
                    ;;
                ROX_API_TOKEN)
                    warning "  - $var: Required by scripts 03, 04, 05"
                    ;;
            esac
        done
        log "Generating missing variables and saving to ~/.bashrc..."
    else
        log "✓ All required environment variables are present"
    fi
else
    warning "~/.bashrc not found, will create it with required variables"
fi

# Generate ROX_ENDPOINT if missing (can be extracted early, doesn't need Central to be ready)
if [ -z "${ROX_ENDPOINT:-}" ]; then
    log "ROX_ENDPOINT not found, will extract from Central route after namespace verification..."
    # Will extract after namespace check below
else
    # Don't normalize ROX_ENDPOINT - keep it as external route hostname (no port, no protocol)
    # Remove any protocol prefix if present, but keep hostname as-is
    ROX_ENDPOINT="${ROX_ENDPOINT#https://}"
    ROX_ENDPOINT="${ROX_ENDPOINT#http://}"
    ROX_ENDPOINT="${ROX_ENDPOINT%/}"
    # Ensure it's saved to bashrc (might have been set but not saved)
    if ! grep -q "^export ROX_ENDPOINT=" ~/.bashrc 2>/dev/null; then
        log "Saving existing ROX_ENDPOINT to ~/.bashrc..."
        sed -i '/^export ROX_ENDPOINT=/d' ~/.bashrc
        echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT\"" >> ~/.bashrc
        log "✓ ROX_ENDPOINT saved to ~/.bashrc"
    fi
fi

log "Note: Missing variables will be generated after Central is ready"


# Verify RHACS namespace exists
if ! oc get ns "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found"
fi

# Ensure RHACS operator subscription is set to stable channel
log "Configuring RHACS operator subscription channel..."
OPERATOR_NAMESPACE="rhacs-operator"
if oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE &>/dev/null; then
    CURRENT_CHANNEL=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.channel}')
    CURRENT_CSV=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
    log "Current channel: $CURRENT_CHANNEL"
    log "Current CSV: $CURRENT_CSV"
    
    if [ "$CURRENT_CHANNEL" != "stable" ]; then
        log "Updating RHACS operator channel from '$CURRENT_CHANNEL' to 'stable'..."
        oc patch subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE --type='merge' -p '{"spec":{"channel":"stable"}}'
        
        # Wait for the subscription to update
        log "Waiting for operator upgrade to begin..."
        sleep 10
        
        # Wait for new CSV to be installed (max 5 minutes)
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            NEW_CSV=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null)
            INSTALL_PLAN_APPROVED=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null)
            
            if [ "$NEW_CSV" != "$CURRENT_CSV" ] && [ -n "$NEW_CSV" ]; then
                log "New CSV detected: $NEW_CSV"
                log "Waiting for CSV to reach Succeeded phase..."
                
                # Wait for CSV to be ready
                if oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/$NEW_CSV -n $OPERATOR_NAMESPACE --timeout=300s 2>/dev/null; then
                    log "✓ RHACS operator upgraded successfully to $NEW_CSV"
                    break
                fi
            fi
            
            sleep 5
            ELAPSED=$((ELAPSED + 5))
            
            if [ $((ELAPSED % 30)) -eq 0 ]; then
                log "Still waiting for operator upgrade... (${ELAPSED}s elapsed)"
            fi
        done
        
        if [ $ELAPSED -ge $TIMEOUT ]; then
            warning "Operator upgrade did not complete within timeout, but continuing..."
        fi
        
        # Confirm final state
        FINAL_CHANNEL=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.channel}')
        FINAL_CSV=$(oc get subscription.operators.coreos.com rhacs-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
        log "✓ Channel confirmed: $FINAL_CHANNEL"
        log "✓ Installed CSV: $FINAL_CSV"
        
        # Wait for Central to be upgraded and ready after operator upgrade
        log "Waiting for Central deployment to be upgraded..."
        sleep 15  # Give operator time to start upgrading Central
        
        log "Waiting for Central to be ready after upgrade..."
        if ! oc wait --for=condition=Available deployment/central -n $NAMESPACE --timeout=600s 2>/dev/null; then
            warning "Central did not become available within timeout, checking status..."
            oc get deployment central -n $NAMESPACE
            oc get pods -n $NAMESPACE -l app=central
        else
            log "✓ Central is ready after operator upgrade"
        fi
    else
        log "✓ RHACS operator already on stable channel"
        log "✓ Installed CSV: $CURRENT_CSV"
    fi
else
    warning "RHACS operator subscription not found in $OPERATOR_NAMESPACE namespace"
fi

# Check if Central is running
if ! oc get deployment central -n $NAMESPACE &>/dev/null; then
    error "RHACS Central deployment not found in namespace $NAMESPACE"
fi

# Wait for Central to be ready
log "Waiting for Central to be ready..."
oc wait --for=condition=Available deployment/central -n $NAMESPACE --timeout=300s
log "✓ Central deployment is ready"

# Now that Central is ready, generate any missing variables
log "Generating missing environment variables now that Central is ready..."

# Generate ROX_ENDPOINT if still missing
if [ -z "${ROX_ENDPOINT:-}" ]; then
    log "ROX_ENDPOINT not found, extracting from Central route..."
    
    # Extract Central route hostname (external route, not internal service)
    ROX_ENDPOINT_HOST=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')
    if [ -z "$ROX_ENDPOINT_HOST" ]; then
        error "Failed to extract Central endpoint from route. Check route exists: oc get route central -n $NAMESPACE"
    fi
    
    # Verify we got the external route, not an internal service name
    if [[ "$ROX_ENDPOINT_HOST" =~ \.svc$ ]] || [[ "$ROX_ENDPOINT_HOST" =~ ^central\. ]]; then
        error "Extracted endpoint appears to be internal service name ($ROX_ENDPOINT_HOST), expected external route hostname. Check route: oc get route central -n $NAMESPACE -o yaml"
    fi
    
    ROX_ENDPOINT="$ROX_ENDPOINT_HOST"
    log "✓ Extracted ROX_ENDPOINT from route: $ROX_ENDPOINT"
    
    # Save to ~/.bashrc (save as-is, external route hostname without port)
    log "Saving ROX_ENDPOINT to ~/.bashrc..."
    sed -i '/^export ROX_ENDPOINT=/d' ~/.bashrc
    echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT\"" >> ~/.bashrc
    export ROX_ENDPOINT="$ROX_ENDPOINT"
    log "✓ ROX_ENDPOINT saved to ~/.bashrc"
fi

# Generate ADMIN_PASSWORD if missing (needed for token generation)
if [ -z "${ADMIN_PASSWORD:-}" ]; then
    log "ADMIN_PASSWORD not found, extracting from secret..."
    
    # Get admin password from secret
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}')
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        # Try alternative secret name
        log "Secret 'central-htpasswd' not found, trying 'central-admin-password'..."
        ADMIN_PASSWORD_B64=$(oc get secret central-admin-password -n "$NAMESPACE" -o jsonpath='{.data.password}')
    fi
    
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        error "Admin password secret not found in namespace $NAMESPACE. Expected one of: central-htpasswd, central-admin-password"
    fi
    
    ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
    if [ -z "$ADMIN_PASSWORD" ]; then
        error "Failed to decode admin password from secret. Base64 value: ${ADMIN_PASSWORD_B64:0:20}..."
    fi
    
    # Save to ~/.bashrc
    log "Saving ADMIN_PASSWORD to ~/.bashrc..."
    sed -i '/^export ADMIN_PASSWORD=/d' ~/.bashrc
    echo "export ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" >> ~/.bashrc
    export ADMIN_PASSWORD="$ADMIN_PASSWORD"
    log "✓ ADMIN_PASSWORD saved to ~/.bashrc"
    # Reload variables from ~/.bashrc to ensure latest values
    reload_bashrc_vars
fi

# Generate ROX_API_TOKEN if missing (needed by scripts 03, 04, 05)
if [ -z "${ROX_API_TOKEN:-}" ]; then
    log "ROX_API_TOKEN not found, generating new API token..."
    
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        error "Cannot generate ROX_API_TOKEN: ADMIN_PASSWORD is required but not available. Check secret: oc get secret central-htpasswd -n $NAMESPACE"
    fi
    
    ADMIN_USERNAME="admin"
    TOKEN_NAME="setup-script-$(date +%d-%m-%Y_%H-%M-%S)"
    TOKEN_ROLE="Admin"
    
    # Normalize ROX_ENDPOINT for API call
    ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
    
    # Retry logic for token generation (Central API might need time to be ready)
    MAX_RETRIES=5
    RETRY_COUNT=0
    TOKEN_CREATED=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$TOKEN_CREATED" = false ]; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        
        if [ $RETRY_COUNT -gt 1 ]; then
            log "Retry attempt $RETRY_COUNT of $MAX_RETRIES for token generation..."
            sleep 10
        else
            log "Waiting for Central API to be ready..."
            sleep 5
        fi
        
        # Generate token
        log "Creating API token: $TOKEN_NAME (attempt $RETRY_COUNT/$MAX_RETRIES)"
        TOKEN_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST \
          -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
          -H "Content-Type: application/json" \
          --data "{\"name\":\"$TOKEN_NAME\",\"role\":\"$TOKEN_ROLE\"}" \
          "https://$ROX_ENDPOINT_NORMALIZED/v1/apitokens/generate" 2>&1)
        
        HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -n1)
        TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | head -n -1)
        
        if [ -z "$TOKEN_BODY" ]; then
            warning "Empty response from token API (HTTP $HTTP_CODE). Retrying..."
            continue
        fi
        
        # Check for HTTP error codes
        if [ "$HTTP_CODE" -eq 401 ] || [ "$HTTP_CODE" -eq 403 ]; then
            error "Authentication failed (HTTP $HTTP_CODE). Check admin username and password. Response: ${TOKEN_BODY:0:300}"
        fi
        
        if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
            warning "Token API returned HTTP $HTTP_CODE. Response: ${TOKEN_BODY:0:200}. Retrying..."
            continue
        fi
        
        # Extract token from JSON response
        ROX_API_TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('token', ''))" 2>/dev/null)
        
        if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
            # Try alternative extraction method
            ROX_API_TOKEN=$(echo "$TOKEN_BODY" | grep -oP '"token"\s*:\s*"\K[^"]+' | head -1)
        fi
        
        if [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && [ ${#ROX_API_TOKEN} -gt 20 ]; then
            TOKEN_CREATED=true
            log "✓ API token created successfully"
            break
        else
            warning "Failed to extract valid token from API response (HTTP $HTTP_CODE). Response: ${TOKEN_BODY:0:300}"
        fi
    done
    
    if [ "$TOKEN_CREATED" = false ]; then
        error "Failed to generate API token after $MAX_RETRIES attempts. Last response (HTTP $HTTP_CODE): ${TOKEN_BODY:0:500}"
    fi
    
    # Save to ~/.bashrc
    log "Saving ROX_API_TOKEN to ~/.bashrc..."
    sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc
    echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
    export ROX_API_TOKEN="$ROX_API_TOKEN"
    log "✓ ROX_API_TOKEN saved to ~/.bashrc"
    # Reload variables from ~/.bashrc to ensure latest values
    reload_bashrc_vars
else
    # Ensure it's saved to bashrc (might have been set but not saved)
    if ! grep -q "^export ROX_API_TOKEN=" ~/.bashrc 2>/dev/null; then
        log "Saving existing ROX_API_TOKEN to ~/.bashrc..."
        sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc
        echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
        log "✓ ROX_API_TOKEN saved to ~/.bashrc"
        # Reload variables from ~/.bashrc to ensure latest values
        reload_bashrc_vars
    fi
fi

log "✓ All required environment variables are now set and saved to ~/.bashrc"

# Verify Central has process baseline auto-lock enabled
log "Verifying process baseline auto-lock configuration in Central..."
CENTRAL_AUTO_LOCK=$(oc get deployment central -n $NAMESPACE -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_AUTO_LOCK_PROCESS_BASELINES")].value}' 2>/dev/null)

if [ -z "$CENTRAL_AUTO_LOCK" ]; then
    # Not explicitly set, using default (which is true/enabled)
    log "Central uses default auto-lock setting (enabled by default)"
elif [ "$CENTRAL_AUTO_LOCK" = "false" ]; then
    # Explicitly disabled, let's enable it
    warning "Central auto-lock is disabled, enabling it..."
    
    # Check if the env var exists in the deployment
    ENV_EXISTS=$(oc get deployment central -n $NAMESPACE -o json | jq '.spec.template.spec.containers[0].env[] | select(.name=="ROX_AUTO_LOCK_PROCESS_BASELINES")' 2>/dev/null)
    
    if [ -n "$ENV_EXISTS" ]; then
        # Update existing env var
        oc set env deployment/central -n $NAMESPACE ROX_AUTO_LOCK_PROCESS_BASELINES=true
    else
        # Add new env var
        oc set env deployment/central -n $NAMESPACE ROX_AUTO_LOCK_PROCESS_BASELINES=true
    fi
    
    if [ $? -eq 0 ]; then
        log "✓ Central auto-lock setting updated to enabled"
        log "Note: Central will restart to apply this change"
        
        # Wait for Central to restart
        log "Waiting for Central to restart..."
        sleep 10
        oc wait --for=condition=Available deployment/central -n $NAMESPACE --timeout=300s
        log "✓ Central restarted successfully"
    else
        warning "Failed to update Central auto-lock setting"
    fi
else
    log "✓ Central auto-lock setting: $CENTRAL_AUTO_LOCK (enabled)"
fi

# Variables should now all be set and saved to ~/.bashrc
# Set ADMIN_USERNAME for use in roxctl login
ADMIN_USERNAME="admin"

# Reload variables from ~/.bashrc to ensure we have latest values before using them
reload_bashrc_vars

# Normalize ROX_ENDPOINT for internal use (add :443 port for API calls)
ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
log "Central endpoint: $ROX_ENDPOINT (normalized for API calls: $ROX_ENDPOINT_NORMALIZED)"

# Test connectivity to Central endpoint
log "Testing connectivity to Central endpoint..."
CONNECT_OUTPUT=$(curl -k -s --connect-timeout 10 -w "\n%{http_code}" "https://$ROX_ENDPOINT_NORMALIZED" 2>&1)
CONNECT_EXIT_CODE=$?
HTTP_CODE=$(echo "$CONNECT_OUTPUT" | tail -n1)

if [ $CONNECT_EXIT_CODE -ne 0 ] || [ -z "$HTTP_CODE" ] || [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 400 ]; then
    error "Cannot connect to Central at https://$ROX_ENDPOINT_NORMALIZED. Exit code: $CONNECT_EXIT_CODE, HTTP code: ${HTTP_CODE:-unknown}. Response: $(echo "$CONNECT_OUTPUT" | head -n -1 | head -c 500)"
fi
log "✓ Successfully connected to Central endpoint (HTTP $HTTP_CODE)"

# Verify all required variables are set (they should have been generated above)
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN is not set after generation. Check token generation above for errors."
fi
if [ -z "${ROX_ENDPOINT:-}" ]; then
    error "ROX_ENDPOINT is not set after generation. Check endpoint extraction above for errors."
fi
log "✓ All required variables verified: ROX_ENDPOINT and ROX_API_TOKEN are set"

# Export environment variables for roxctl
export ROX_API_TOKEN
export ROX_ENDPOINT

# Download roxctl if not available
if ! command -v roxctl &>/dev/null; then
    log "roxctl not found, installing to system location..."
    
    # Download roxctl to temporary location first
    curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl"
    
    if [ $? -eq 0 ]; then
        # Move to system-wide location
        sudo mv /tmp/roxctl /usr/local/bin/roxctl
        sudo chmod +x /usr/local/bin/roxctl
        
        # Verify installation
        if command -v roxctl &>/dev/null; then
            log "✓ roxctl installed successfully to /usr/local/bin/roxctl"
            ROXCTL_CMD="roxctl"
        else
            error "Failed to install roxctl to system location"
        fi
    else
        error "Failed to download roxctl"
    fi
else
    log "roxctl already available in system PATH"
    ROXCTL_CMD="roxctl"
fi

ROXCTL_AUTH_ARGS=()
ROXCTL_TOKEN_FILE=""

# Reload ~/.bashrc to get ADMIN_PASSWORD if it was saved earlier
if [ -f ~/.bashrc ]; then
    set +u  # Temporarily disable unbound variable checking
    source ~/.bashrc || true
    set -u  # Re-enable unbound variable checking
    # Ensure ADMIN_PASSWORD is loaded
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD_LINE=$(grep "^export ADMIN_PASSWORD=" ~/.bashrc | head -1 || echo "")
        if [ -n "$ADMIN_PASSWORD_LINE" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        fi
    fi
    # Ensure ROX_ENDPOINT is loaded
    if [ -z "$ROX_ENDPOINT" ]; then
        ROX_ENDPOINT_LINE=$(grep "^export ROX_ENDPOINT=" ~/.bashrc | head -1 || echo "")
        if [ -n "$ROX_ENDPOINT_LINE" ]; then
            ROX_ENDPOINT=$(echo "$ROX_ENDPOINT_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        fi
    fi
fi

# Prepare authentication arguments (token-based)
# Note: roxctl central login requires interactive browser-based authentication,
# so we use token-based authentication for all roxctl commands
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN is required for roxctl commands but was not generated. Check token generation above for errors."
fi

log "Using token-based authentication for roxctl commands"
ROXCTL_AUTH_ARGS=(--token "$ROX_API_TOKEN")

# Test roxctl connectivity using password authentication
# Note: roxctl central whoami requires password authentication, not token
if [ -z "${ADMIN_PASSWORD:-}" ]; then
    error "ADMIN_PASSWORD is required for roxctl connectivity check but is not set. Check secret: oc get secret central-htpasswd -n $NAMESPACE"
fi

# Ensure endpoint has :443 port specified for whoami check
WHOAMI_ENDPOINT="$ROX_ENDPOINT"
if [[ ! "$WHOAMI_ENDPOINT" =~ :[0-9]+$ ]]; then
    WHOAMI_ENDPOINT="${WHOAMI_ENDPOINT}:443"
fi

log "Verifying roxctl connectivity using password authentication..."
log "Command: $ROXCTL_CMD -e \"$WHOAMI_ENDPOINT\" central whoami --password \"***\" --insecure-skip-tls-verify"
if ! $ROXCTL_CMD -e "$WHOAMI_ENDPOINT" central whoami --password "$ADMIN_PASSWORD" --insecure-skip-tls-verify >/dev/null 2>&1; then
    # Capture the actual error output for better diagnostics
    ROXCTL_ERROR=$($ROXCTL_CMD -e "$WHOAMI_ENDPOINT" central whoami --password "$ADMIN_PASSWORD" --insecure-skip-tls-verify 2>&1 || true)
    error "roxctl authentication failed for endpoint: $WHOAMI_ENDPOINT. Error: $ROXCTL_ERROR"
else
    log "roxctl authentication verified successfully."
fi

# Clean up any old SecuredCluster resources from previous installations
log "Checking for old SecuredCluster resources..."
OLD_SECURED_CLUSTERS=$(oc get securedcluster -n $NAMESPACE -o name 2>/dev/null | grep -v "secured-cluster-services" || true)
if [ -n "$OLD_SECURED_CLUSTERS" ]; then
    log "Found old SecuredCluster resources, cleaning up..."
    for sc in $OLD_SECURED_CLUSTERS; do
        log "Deleting old resource: $sc"
        oc delete $sc -n $NAMESPACE --wait=false || error "Failed to delete old SecuredCluster: $sc"
    done
    log "Waiting for old resources to be cleaned up..."
    sleep 15
    
    # Clean up any orphaned NetworkPolicies with old Helm release names
    log "Checking for orphaned NetworkPolicies..."
    ORPHANED_NETPOLS=$(oc get networkpolicy -n $NAMESPACE -o json | \
        python3 -c "import sys, json; data=json.load(sys.stdin); print('\n'.join([item['metadata']['name'] for item in data.get('items', []) if item['metadata'].get('annotations', {}).get('meta.helm.sh/release-name', '').startswith('stackrox-secured-cluster') or item['metadata'].get('annotations', {}).get('meta.helm.sh/release-name', '') == 'same-cluster-secured-services']))" || true)
    
    if [ -n "$ORPHANED_NETPOLS" ]; then
        log "Found orphaned NetworkPolicies, removing Helm annotations..."
        for netpol in $ORPHANED_NETPOLS; do
            log "Cleaning up NetworkPolicy: $netpol"
            oc annotate networkpolicy $netpol -n $NAMESPACE meta.helm.sh/release-name- meta.helm.sh/release-namespace- helm.sh/resource-policy- || warning "Failed to remove annotations from networkpolicy $netpol"
        done
    fi
fi

SKIP_TO_FINAL_OUTPUT=false
INIT_BUNDLE_EXISTS=false

if oc get securedcluster secured-cluster-services -n $NAMESPACE >/dev/null 2>&1; then
    log "SecuredCluster resource secured-cluster-services already exists; skipping init bundle generation and SecuredCluster installation."
    SKIP_TO_FINAL_OUTPUT=true

    CURRENT_AUTO_LOCK=$(oc get securedcluster secured-cluster-services -n $NAMESPACE -o jsonpath='{.spec.processBaselines.autoLock}' 2>/dev/null)
    if [ "$CURRENT_AUTO_LOCK" != "Enabled" ]; then
        log "Updating SecuredCluster to enable process baseline auto-lock..."
        oc patch securedcluster secured-cluster-services -n $NAMESPACE --type='merge' -p '{"spec":{"processBaselines":{"autoLock":"Enabled"}}}'
        if [ $? -eq 0 ]; then
            log "✓ Process baseline auto-lock enabled on existing SecuredCluster"
        else
            warning "Failed to update auto-lock setting"
        fi
    else
        log "✓ Process baseline auto-lock already enabled"
    fi
else
    # Generate init bundle using external endpoint with -e flag
    # Init bundle generation requires password authentication, not token
    if [ -z "${ADMIN_PASSWORD:-}" ]; then
        error "ADMIN_PASSWORD is required for init bundle generation but is not set. Check secret: oc get secret central-htpasswd -n $NAMESPACE"
    fi
    
    # Ensure endpoint has :443 port specified
    INIT_ENDPOINT="$ROX_ENDPOINT"
    if [[ ! "$INIT_ENDPOINT" =~ :[0-9]+$ ]]; then
        INIT_ENDPOINT="${INIT_ENDPOINT}:443"
    fi
    
    log "Generating init bundle for cluster: $CLUSTER_NAME"
    log "Using endpoint: $INIT_ENDPOINT"
    
    # Capture output to check for errors
    # Note: -e flag must come before 'central' command
    INIT_BUNDLE_OUTPUT=$($ROXCTL_CMD -e "$INIT_ENDPOINT" \
      central init-bundles generate $CLUSTER_NAME \
      --output-secrets cluster_init_bundle.yaml \
      --password "$ADMIN_PASSWORD" \
      --insecure-skip-tls-verify 2>&1) || INIT_BUNDLE_EXIT_CODE=$?
    
    # Check if init bundle already exists
    if echo "$INIT_BUNDLE_OUTPUT" | grep -q "AlreadyExists"; then
        log "Init bundle already exists in RHACS Central"
        INIT_BUNDLE_EXISTS=true
    elif [ ! -f cluster_init_bundle.yaml ]; then
        error "Failed to generate init bundle. roxctl output: ${INIT_BUNDLE_OUTPUT:0:500}"
    else
        log "Init bundle generated successfully"
        INIT_BUNDLE_EXISTS=false
    fi
fi

# Apply init bundle (only if not skipping and bundle was actually generated)
if [ "$SKIP_TO_FINAL_OUTPUT" = "false" ]; then
    if [ "$INIT_BUNDLE_EXISTS" = "false" ]; then
        log "Applying init bundle secrets..."
        oc apply -f cluster_init_bundle.yaml -n $NAMESPACE
    else
        log "Init bundle secrets already exist, skipping application..."
    fi

    # Create SecuredCluster resource with INTERNAL endpoint
    log "Creating SecuredCluster resource with internal endpoint..."
    log "Configuring process baseline auto-lock: Enabled"
cat <<EOF | oc apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: secured-cluster-services
  namespace: $NAMESPACE
spec:
  clusterName: "$CLUSTER_NAME"
  centralEndpoint: "$ROX_ENDPOINT"
  admissionControl:
    listenOnCreates: true
    listenOnEvents: true 
    listenOnUpdates: true
    enforceOnCreates: false
    enforceOnUpdates: false
    scanInline: true
    disableBypass: false
    timeoutSeconds: 20
  auditLogs:
    collection: Auto
  perNode:
    collector:
      collection: EBPF
      imageFlavor: Regular
      resources:
        limits:
          cpu: 750m
          memory: 1Gi
        requests:
          cpu: 50m
          memory: 320Mi
    taintToleration: TolerateTaints
  scanner:
    analyzer:
      scaling:
        autoScaling: Enabled
        maxReplicas: 5
        minReplicas: 1
        replicas: 3
      resources:
        limits:
          cpu: 2000m
          memory: 4Gi
        requests:
          cpu: 1000m
          memory: 1500Mi
    scannerComponent: AutoSense
  processBaselines:
    autoLock: Enabled
EOF

    # Verify auto-lock setting was applied
    sleep 2
    AUTO_LOCK_STATUS=$(oc get securedcluster secured-cluster-services -n $NAMESPACE -o jsonpath='{.spec.processBaselines.autoLock}' 2>/dev/null)
    if [ "$AUTO_LOCK_STATUS" = "Enabled" ]; then
        log "✓ Process baseline auto-lock verified: Enabled"
    else
        warning "Process baseline auto-lock setting not found or not Enabled (current: $AUTO_LOCK_STATUS)"
    fi
fi

# Wait for deployment (only if not skipping)
if [ "$SKIP_TO_FINAL_OUTPUT" = "false" ]; then
    log "Waiting for SecuredCluster components to be ready..."

# Function to wait for resource to exist and then be ready
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local condition=$3
    local timeout=${4:-300}
    
    log "Waiting for $resource_type/$resource_name to be created..."
    local wait_count=0
    while ! oc get $resource_type $resource_name -n $NAMESPACE >/dev/null 2>&1; do
        if [ $wait_count -ge 60 ]; then  # 5 minutes max wait for creation
            warning "$resource_type/$resource_name was not created within 5 minutes"
            return 1
        fi
        sleep 5
        wait_count=$((wait_count + 1))
        echo -n "."
    done
    echo ""
    
    if [ "$resource_type" = "daemonset" ]; then
        # For DaemonSets, check if desired number of pods are scheduled and ready
        log "$resource_type/$resource_name created, waiting for all pods to be ready..."
        local ready_timeout=$((timeout / 5))  # Check every 5 seconds
        local check_count=0
        
        while [ $check_count -lt $ready_timeout ]; do
            local status=$(oc get daemonset $resource_name -n $NAMESPACE -o jsonpath='{.status.desiredNumberScheduled},{.status.numberReady}' 2>/dev/null)
            local desired=$(echo $status | cut -d',' -f1)
            local ready=$(echo $status | cut -d',' -f2)
            
            if [ -n "$desired" ] && [ -n "$ready" ] && [ "$desired" = "$ready" ] && [ "$desired" != "0" ]; then
                log "✓ $resource_type/$resource_name is ready ($ready/$desired pods running)"
                return 0
            fi
            
            if [ -n "$desired" ] && [ -n "$ready" ]; then
                log "DaemonSet $resource_name: $ready/$desired pods ready..."
            fi
            
            sleep 5
            check_count=$((check_count + 1))
        done
        
        warning "$resource_type/$resource_name readiness timeout (not all pods ready within ${timeout}s)"
        return 1
    else
        # For other resources (Deployments), use standard condition waiting
        log "$resource_type/$resource_name created, waiting for $condition condition..."
        if oc wait --for=condition=$condition $resource_type/$resource_name -n $NAMESPACE --timeout=${timeout}s; then
            log "✓ $resource_type/$resource_name is ready"
            return 0
        else
            warning "$resource_type/$resource_name $condition condition timeout"
            return 1
        fi
    fi
}

# Wait for sensor deployment
wait_for_resource "deployment" "sensor" "Available" 300

# Wait for admission-control deployment  
wait_for_resource "deployment" "admission-control" "Available" 300

# Wait for collector daemonset
wait_for_resource "daemonset" "collector" "" 300

# Verification
log "Verifying deployment..."

# Check pod status
FAILED_PODS=$(oc get pods -n $NAMESPACE --field-selector=status.phase!=Running,status.phase!=Succeeded -o name | wc -l)
if [ "$FAILED_PODS" -gt 0 ]; then
    warning "$FAILED_PODS pods are not in Running/Succeeded state"
    oc get pods -n $NAMESPACE
fi
fi

# Verify SecuredCluster auto-lock configuration
log "Verifying SecuredCluster process baseline auto-lock configuration..."
if oc get securedcluster secured-cluster-services -n $NAMESPACE >/dev/null 2>&1; then
    SC_AUTO_LOCK=$(oc get securedcluster secured-cluster-services -n $NAMESPACE -o jsonpath='{.spec.processBaselines.autoLock}' 2>/dev/null)
    
    if [ "$SC_AUTO_LOCK" = "Enabled" ]; then
        log "✓ SecuredCluster process baseline auto-lock: Enabled"
    elif [ -z "$SC_AUTO_LOCK" ]; then
        warning "SecuredCluster auto-lock not configured (disabled by default)"
        log "Enabling auto-lock on SecuredCluster..."
        oc patch securedcluster secured-cluster-services -n $NAMESPACE --type='merge' -p '{"spec":{"processBaselines":{"autoLock":"Enabled"}}}'
        if [ $? -eq 0 ]; then
            log "✓ Process baseline auto-lock enabled on SecuredCluster"
        else
            warning "Failed to enable auto-lock on SecuredCluster"
        fi
    else
        warning "SecuredCluster auto-lock is set to: $SC_AUTO_LOCK (should be Enabled)"
        log "Updating auto-lock to Enabled..."
        oc patch securedcluster secured-cluster-services -n $NAMESPACE --type='merge' -p '{"spec":{"processBaselines":{"autoLock":"Enabled"}}}'
        if [ $? -eq 0 ]; then
            log "✓ Process baseline auto-lock updated to Enabled"
        else
            warning "Failed to update auto-lock setting"
        fi
    fi
else
    warning "SecuredCluster resource not found, auto-lock verification skipped"
fi

# All variables should already be saved to ~/.bashrc above
# Verify they're all present
log "Verifying all variables are saved to ~/.bashrc..."
if ! grep -q "^export ROX_ENDPOINT=" ~/.bashrc; then
    error "ROX_ENDPOINT not found in ~/.bashrc after generation"
fi
if ! grep -q "^export ROX_API_TOKEN=" ~/.bashrc; then
    error "ROX_API_TOKEN not found in ~/.bashrc after generation"
fi
if [ -n "${ADMIN_PASSWORD:-}" ] && ! grep -q "^export ADMIN_PASSWORD=" ~/.bashrc; then
    log "Saving ADMIN_PASSWORD to ~/.bashrc..."
    sed -i '/^export ADMIN_PASSWORD=/d' ~/.bashrc
    echo "export ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" >> ~/.bashrc
    log "✓ ADMIN_PASSWORD saved to ~/.bashrc"
    # Reload variables from ~/.bashrc to ensure latest values
    reload_bashrc_vars
fi
log "✓ All required variables verified in ~/.bashrc"

# Clean up temporary files
rm -f cluster_init_bundle.yaml
if [ -n "$ROXCTL_TOKEN_FILE" ] && [ -f "$ROXCTL_TOKEN_FILE" ]; then
    rm -f "$ROXCTL_TOKEN_FILE"
fi
# roxctl is now installed permanently to /usr/local/bin/roxctl

# Script will exit automatically on error due to set -e at the top
log "RHACS secured cluster configuration completed successfully!"
log "========================================================="
log "RHACS UI:     https://$ROX_ENDPOINT"
log "---------------------------------------------------------"
log "User:         admin"
if [ -n "$ADMIN_PASSWORD" ]; then
    log "Password:     $ADMIN_PASSWORD"
else
    log "Password:     (not available - using existing credentials)"
fi
log "---------------------------------------------------------"
