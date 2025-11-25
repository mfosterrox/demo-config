#!/bin/bash
# RHACS Secured Cluster Setup Script
# Creates RHACS secured cluster services

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[RHACS-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-SETUP]${NC} $1"
    SCRIPT_FAILED=true
}

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

# Check for existing API token in ~/.bashrc
TOKEN_FROM_BASHRC=false
TOKEN_FROM_ENV=false

if [ -f ~/.bashrc ]; then
    # Extract ROX_API_TOKEN from ~/.bashrc if it exists
    # Handle both double quotes and single quotes, and unquoted values
    TOKEN_LINE=$(grep "^export ROX_API_TOKEN=" ~/.bashrc 2>/dev/null | head -1)
    
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
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Load existing environment variables from ~/.bashrc if available
if [ -f ~/.bashrc ]; then
    if grep -q "^source $" ~/.bashrc; then
        warning "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    if source ~/.bashrc 2>/dev/null; then
        log "Loaded environment variables from ~/.bashrc"
    else
        warning "Failed to source ~/.bashrc, continuing with current environment"
    fi
fi

# Normalize ROX endpoint variables if provided in environment
if [ -n "$ROX_ENDPOINT" ]; then
    ROX_ENDPOINT="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
fi

if [ -z "$ROX_ENDPOINT" ]; then
    if [ -n "$ROX_CENTRAL_ADDRESS" ]; then
        ROX_ENDPOINT="$(normalize_rox_endpoint "$ROX_CENTRAL_ADDRESS")"
        log "Using ROX endpoint from ROX_CENTRAL_ADDRESS: $ROX_ENDPOINT"
    fi
fi


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

# Extract admin credentials from secret
log "Extracting admin credentials from secret in namespace $NAMESPACE..."
ADMIN_USERNAME="admin"
ADMIN_PASSWORD=""

# Wait for Central to be ready before trying to get the password
log "Waiting for Central to be ready..."
if ! oc wait --for=condition=Available deployment/central -n $NAMESPACE --timeout=300s 2>/dev/null; then
    warning "Central deployment may not be fully ready, but continuing..."
fi

# Get admin password from secret
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null || true)
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    # Try alternative secret name
    ADMIN_PASSWORD_B64=$(oc get secret central-admin-password -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null || true)
fi

if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || true)
    if [ -n "$ADMIN_PASSWORD" ]; then
        log "✓ Admin password extracted from secret (username: $ADMIN_USERNAME)"
    else
        error "Failed to decode admin password from secret"
    fi
else
    error "Admin password secret not found in namespace $NAMESPACE"
    error "Expected secret: central-htpasswd"
    if [ -z "$ROX_API_TOKEN" ]; then
        error "No existing ROX_API_TOKEN found; cannot proceed without admin credentials"
    else
        warning "Will rely on existing ROX_API_TOKEN for API access"
    fi
fi

# Extract external Central endpoint
ROX_ENDPOINT_HOST=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.host}')
if [ -z "$ROX_ENDPOINT_HOST" ]; then
    error "Failed to extract Central endpoint"
fi
if [ -z "$ROX_ENDPOINT" ]; then
    ROX_ENDPOINT="$(normalize_rox_endpoint "$ROX_ENDPOINT_HOST")"
else
    ROX_ENDPOINT="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
fi

log "Central endpoint: $ROX_ENDPOINT"

# Save ROX_ENDPOINT to ~/.bashrc immediately after extraction
log "Saving ROX_ENDPOINT to ~/.bashrc..."
# Remove existing ROX_ENDPOINT entry if it exists
sed -i '/^export ROX_ENDPOINT=/d' ~/.bashrc 2>/dev/null || true
# Add new entry with just the hostname (no port)
echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT_HOST\"" >> ~/.bashrc
log "✓ ROX_ENDPOINT saved to ~/.bashrc: $ROX_ENDPOINT_HOST"

# Save ROX_API_TOKEN to ~/.bashrc immediately if it already exists
if [ -n "$ROX_API_TOKEN" ] && [ "$TOKEN_FROM_BASHRC" != true ]; then
    log "Saving existing ROX_API_TOKEN to ~/.bashrc..."
    # Remove existing ROX_API_TOKEN entry if it exists
    sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc 2>/dev/null || true
    # Add token entry
    echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
    log "✓ ROX_API_TOKEN saved to ~/.bashrc"
fi

# Test connectivity to Central endpoint
log "Testing connectivity to Central endpoint..."
if ! curl -k -s --connect-timeout 10 "https://$ROX_ENDPOINT" >/dev/null; then
    error "Cannot connect to Central at $ROX_ENDPOINT"
fi

# Create or reuse API token
if [ "$TOKEN_FROM_BASHRC" = true ]; then
    log "Using existing ROX_API_TOKEN from ~/.bashrc"
    # Token already in bashrc, no need to save again
elif [ -n "$ROX_API_TOKEN" ]; then
    log "Using existing ROX_API_TOKEN from environment"
    # Token from environment but not in bashrc, ensure it's saved
    log "Ensuring ROX_API_TOKEN is saved to ~/.bashrc..."
    sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc 2>/dev/null || true
    echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
    log "✓ ROX_API_TOKEN saved to ~/.bashrc"
else
    # No token found, generate a new one using admin credentials
    if [ -n "$ADMIN_PASSWORD" ] && [ -n "$ADMIN_USERNAME" ]; then
        log "No API token found, creating new API token using admin credentials..."
        log "Username: $ADMIN_USERNAME"
        log "Token name: $TOKEN_NAME"
        log "Token role: $TOKEN_ROLE"
        
        # Wait a bit more to ensure Central API is ready
        log "Waiting for Central API to be ready..."
        sleep 5
        
        # Retry logic for token creation
        MAX_RETRIES=3
        RETRY_COUNT=0
        TOKEN_CREATED=false
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$TOKEN_CREATED" = false ]; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -gt 1 ]; then
                log "Retry attempt $RETRY_COUNT of $MAX_RETRIES..."
                sleep 10
            fi
            
            set +e
            TOKEN_RESPONSE=$(curl -k -X POST \
              -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
              -H "Content-Type: application/json" \
              --data "{\"name\":\"$TOKEN_NAME\",\"role\":\"$TOKEN_ROLE\"}" \
              "https://$ROX_ENDPOINT/v1/apitokens/generate" 2>&1)
            TOKEN_EXIT_CODE=$?
            HTTP_CODE=$(echo "$TOKEN_RESPONSE" | grep -oP 'HTTP/\d\.\d \K\d+' | tail -1 || echo "")
            set -e
            
            # Check if we got a valid response
            if [ $TOKEN_EXIT_CODE -eq 0 ] && [ -n "$TOKEN_RESPONSE" ]; then
                # Check for HTTP error codes in response
                if echo "$TOKEN_RESPONSE" | grep -qi "401\|unauthorized\|forbidden"; then
                    error "Authentication failed - check admin username and password"
                    log "Response: ${TOKEN_RESPONSE:0:300}"
                    continue
                fi
                
                # Extract token from JSON response
                NEW_ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('token', ''))" 2>/dev/null || echo "")
                
                if [ -z "$NEW_ROX_API_TOKEN" ]; then
                    # Try alternative extraction method
                    NEW_ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oP '"token"\s*:\s*"\K[^"]+' | head -1 || echo "")
                fi
                
                if [ -n "$NEW_ROX_API_TOKEN" ] && [ "$NEW_ROX_API_TOKEN" != "null" ] && [ ${#NEW_ROX_API_TOKEN} -gt 20 ]; then
                    ROX_API_TOKEN="$NEW_ROX_API_TOKEN"
                    log "✓ API token created successfully"
                    TOKEN_CREATED=true
                    
                    # Save token to ~/.bashrc
                    log "Saving ROX_API_TOKEN to ~/.bashrc..."
                    
                    # Remove existing ROX_API_TOKEN entry if it exists
                    sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc 2>/dev/null || true
                    
                    # Add new token entry
                    echo "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"" >> ~/.bashrc
                    log "✓ ROX_API_TOKEN saved to ~/.bashrc"
                else
                    error "Failed to extract valid token from API response"
                    log "Response preview: ${TOKEN_RESPONSE:0:300}"
                    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                        warning "Will retry token creation..."
                    fi
                fi
            else
                error "Failed to create API token (exit code: $TOKEN_EXIT_CODE)"
                if [ -n "$TOKEN_RESPONSE" ]; then
                    log "Response: ${TOKEN_RESPONSE:0:300}"
                fi
                if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                    warning "Will retry token creation..."
                fi
            fi
        done
        
        if [ "$TOKEN_CREATED" = false ]; then
            error "Failed to create API token after $MAX_RETRIES attempts"
            error "Please check:"
            error "  1. Central is running and accessible at https://$ROX_ENDPOINT"
            error "  2. Admin password is correct in secret central-htpasswd"
            error "  3. Central API is ready (may need to wait longer)"
        fi
    else
        error "Cannot create API token: admin credentials not available"
        error "Username: $ADMIN_USERNAME"
        error "Password available: $([ -n "$ADMIN_PASSWORD" ] && echo "Yes" || echo "No")"
    fi
fi

# Export environment variables for roxctl
export ROX_API_TOKEN
export ROX_ENDPOINT

echo $ROX_API_TOKEN
echo $ROX_ENDPOINT

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
    source ~/.bashrc 2>/dev/null || true
    set -u  # Re-enable unbound variable checking
    # Ensure ADMIN_PASSWORD is loaded
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD_LINE=$(grep "^export ADMIN_PASSWORD=" ~/.bashrc 2>/dev/null | head -1)
        if [ -n "$ADMIN_PASSWORD_LINE" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        fi
    fi
    # Ensure ROX_ENDPOINT is loaded
    if [ -z "$ROX_ENDPOINT" ]; then
        ROX_ENDPOINT_LINE=$(grep "^export ROX_ENDPOINT=" ~/.bashrc 2>/dev/null | head -1)
        if [ -n "$ROX_ENDPOINT_LINE" ]; then
            ROX_ENDPOINT=$(echo "$ROX_ENDPOINT_LINE" | awk -F'=' '{print $2}' | sed 's/^["'\'']//; s/["'\'']$//')
        fi
    fi
fi

# Prepare authentication arguments (token-based by default when available)
# Login to RHACS Central with roxctl (optional - API token will be used)
if [ -n "$ADMIN_PASSWORD" ]; then
    log "Logging into RHACS Central with roxctl (using admin credentials)..."
    log "Endpoint: $ROX_ENDPOINT"
    log "Username: admin"
    
    # Ensure ROX_ENDPOINT has https:// prefix for roxctl
    ROX_ENDPOINT_FOR_ROXCTL="$ROX_ENDPOINT"
    if [[ ! "$ROX_ENDPOINT_FOR_ROXCTL" =~ ^https?:// ]]; then
        ROX_ENDPOINT_FOR_ROXCTL="https://$ROX_ENDPOINT_FOR_ROXCTL"
    fi
    
    if echo "$ADMIN_PASSWORD" | $ROXCTL_CMD central login \
      -e "$ROX_ENDPOINT_FOR_ROXCTL" \
      --username admin \
      --password-stdin \
      --insecure-skip-tls-verify 2>&1 | tee /tmp/roxctl-login.log; then
        log "✓ Successfully logged into RHACS Central"
    else
        warning "Password-based login failed"
        if [ -f /tmp/roxctl-login.log ]; then
            warning "roxctl login error output:"
            cat /tmp/roxctl-login.log | head -10
            rm -f /tmp/roxctl-login.log
        fi
        warning "Will fall back to token authentication if available"
    fi
else
    if [ -n "$ROX_API_TOKEN" ]; then
        log "Preparing token-based authentication for roxctl commands using existing ROX_API_TOKEN"
    else
        warning "No ADMIN_PASSWORD found in environment or ~/.bashrc"
    fi
fi

if [ ${#ROXCTL_AUTH_ARGS[@]} -eq 0 ] && [ -n "$ROX_API_TOKEN" ]; then
    ROXCTL_AUTH_ARGS=(--token "$ROX_API_TOKEN")
fi

# Test roxctl connectivity using available authentication method
if [ -n "$ROX_API_TOKEN" ]; then
    log "Verifying roxctl connectivity using API token..."
    log "Command: $ROXCTL_CMD central whoami -e \"$ROX_ENDPOINT\" --insecure-skip-tls-verify --token \"$ROX_API_TOKEN\""
    if ! $ROXCTL_CMD central whoami -e "$ROX_ENDPOINT" --insecure-skip-tls-verify "${ROXCTL_AUTH_ARGS[@]}" >/dev/null 2>&1; then
        warning "roxctl authentication failed for endpoint: $ROX_ENDPOINT"
        log "Continuing with setup despite roxctl authentication failure. Review the above message for details."
    else
        log "roxctl authentication verified successfully."
    fi
else
    log "ROX_API_TOKEN not set; skipping roxctl whoami connectivity check."
fi

# Clean up any old SecuredCluster resources from previous installations
log "Checking for old SecuredCluster resources..."
OLD_SECURED_CLUSTERS=$(oc get securedcluster -n $NAMESPACE -o name 2>/dev/null | grep -v "secured-cluster-services" || true)
if [ -n "$OLD_SECURED_CLUSTERS" ]; then
    log "Found old SecuredCluster resources, cleaning up..."
    for sc in $OLD_SECURED_CLUSTERS; do
        log "Deleting old resource: $sc"
        oc delete $sc -n $NAMESPACE --wait=false 2>/dev/null || true
    done
    log "Waiting for old resources to be cleaned up..."
    sleep 15
    
    # Clean up any orphaned NetworkPolicies with old Helm release names
    log "Checking for orphaned NetworkPolicies..."
    ORPHANED_NETPOLS=$(oc get networkpolicy -n $NAMESPACE -o json 2>/dev/null | \
        python3 -c "import sys, json; data=json.load(sys.stdin); print('\n'.join([item['metadata']['name'] for item in data.get('items', []) if item['metadata'].get('annotations', {}).get('meta.helm.sh/release-name', '').startswith('stackrox-secured-cluster') or item['metadata'].get('annotations', {}).get('meta.helm.sh/release-name', '') == 'same-cluster-secured-services']))" 2>/dev/null || true)
    
    if [ -n "$ORPHANED_NETPOLS" ]; then
        log "Found orphaned NetworkPolicies, removing Helm annotations..."
        for netpol in $ORPHANED_NETPOLS; do
            log "Cleaning up NetworkPolicy: $netpol"
            oc annotate networkpolicy $netpol -n $NAMESPACE meta.helm.sh/release-name- meta.helm.sh/release-namespace- helm.sh/resource-policy- 2>/dev/null || true
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
    log "Generating init bundle for cluster: $CLUSTER_NAME"
    if $ROXCTL_CMD central init-bundles generate $CLUSTER_NAME \
      -e "$ROX_ENDPOINT" \
      "${ROXCTL_AUTH_ARGS[@]}" \
      --output-secrets cluster_init_bundle.yaml --insecure-skip-tls-verify 2>&1 | grep -q "AlreadyExists"; then
        log "Init bundle already exists in RHACS Central"
        INIT_BUNDLE_EXISTS=true
    else
        if [ ! -f cluster_init_bundle.yaml ]; then
            error "Failed to generate init bundle"
        fi
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

# Save ADMIN_PASSWORD to bashrc (ROX_ENDPOINT already saved above)
# Note: ROX_API_TOKEN is already saved to ~/.bashrc if it was newly created above
if [ -n "$ADMIN_PASSWORD" ]; then
    log "Saving ADMIN_PASSWORD to ~/.bashrc..."
    # Remove existing ADMIN_PASSWORD entry if it exists
    sed -i '/^export ADMIN_PASSWORD=/d' ~/.bashrc 2>/dev/null || true
    # Add new entry
    echo "export ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" >> ~/.bashrc
    log "✓ ADMIN_PASSWORD saved to ~/.bashrc"
fi

# Clean up temporary files
rm -f cluster_init_bundle.yaml
if [ -n "$ROXCTL_TOKEN_FILE" ] && [ -f "$ROXCTL_TOKEN_FILE" ]; then
    rm -f "$ROXCTL_TOKEN_FILE"
fi
# roxctl is now installed permanently to /usr/local/bin/roxctl

if [ "$SCRIPT_FAILED" = true ]; then
    warning "RHACS secured cluster configuration completed with errors. Review the log above for details."
else
    log "RHACS secured cluster configuration completed successfully!"
fi
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
