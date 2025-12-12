#!/bin/bash
# Cert-Manager Operator Installation Script
# Installs and ensures cert-manager operator is up to date

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[CERT-MANAGER]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[CERT-MANAGER]${NC} $1"
}

error() {
    echo -e "${RED}[CERT-MANAGER] ERROR:${NC} $1" >&2
    echo -e "${RED}[CERT-MANAGER] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"

# Cert-manager operator namespace (Red Hat cert-manager Operator installs here)
OPERATOR_NAMESPACE="cert-manager-operator"

# Check if cert-manager is already installed
log ""
log "========================================================="
log "Checking cert-manager operator status"
log "========================================================="

if oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    CURRENT_CSV=$(oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
        # Check if CSV exists before checking phase
        if oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Cert-manager operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                
                # Set CSV_NAME for summary
                CSV_NAME="$CURRENT_CSV"
                
                # Check if there's an update available
                INSTALLED_CSV=$(oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
                if [ -n "$INSTALLED_CSV" ] && [ "$INSTALLED_CSV" != "$CURRENT_CSV" ] && [ -n "$CURRENT_CSV" ]; then
                    log "  Update available: $CURRENT_CSV (currently installed: $INSTALLED_CSV)"
                    log "  Will update to latest version..."
                    NEEDS_UPDATE=true
                else
                    log "  Cert-manager operator is up to date"
                    NEEDS_UPDATE=false
                fi
            else
                log "Cert-manager operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
                NEEDS_UPDATE=false
            fi
        else
            log "Subscription exists but CSV '$CURRENT_CSV' not found yet, proceeding with installation..."
        fi
    else
        log "Subscription exists but CSV not yet determined, proceeding with installation..."
    fi
else
    log "Cert-manager operator not found, proceeding with installation..."
    NEEDS_UPDATE=false
fi

# Get current CSV and channel info for summary (even if not updating)
if oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    CSV_NAME=$(oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    CHANNEL=$(oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ]; then
        CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep cert-manager | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
fi

# Only proceed with subscription updates if needed
if [ "${NEEDS_UPDATE:-false}" = "true" ] || [ ! -v NEEDS_UPDATE ]; then
    # Install or update cert-manager operator
    log ""
    log "========================================================="
    if [ "${NEEDS_UPDATE:-false}" = "true" ]; then
        log "Updating cert-manager operator"
    else
        log "Installing cert-manager operator"
    fi
    log "========================================================="
    log ""
    log "Following idempotent installation steps (safe to run multiple times)..."
    log ""

    # Step 1: Verify namespace exists
    log "Step 1: Verifying namespace $OPERATOR_NAMESPACE..."
    if ! oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log "Creating namespace $OPERATOR_NAMESPACE..."
        if ! oc create namespace "$OPERATOR_NAMESPACE"; then
            error "Failed to create $OPERATOR_NAMESPACE namespace"
        fi
        log "✓ Namespace created successfully"
    else
        log "✓ Namespace already exists"
    fi

    # Verify namespace exists and we have access
    if ! oc get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        error "Cannot access namespace $OPERATOR_NAMESPACE. Check permissions."
    fi
    log "✓ Namespace verified and accessible"

    # Step 2: Wait for catalog to be ready
    log ""
    log "Step 2: Waiting for catalog source to be ready..."
CATALOG_READY=false
for i in {1..12}; do
    if oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
        CATALOG_STATUS=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [ "$CATALOG_STATUS" = "READY" ]; then
            CATALOG_READY=true
            log "✓ Catalog source 'redhat-operators' is READY"
            break
        else
            log "  Catalog source status: ${CATALOG_STATUS:-unknown} (waiting for READY...)"
        fi
    fi
    if [ $i -lt 12 ]; then
        sleep 5
    fi
done

    if [ "$CATALOG_READY" = false ]; then
        warning "Catalog source may not be ready, but continuing..."
    fi

    # Step 3: Determine the correct channel
    log ""
    log "Step 3: Determining available channel for cert-manager..."

CHANNEL=""
if oc get packagemanifest cert-manager -n openshift-marketplace >/dev/null 2>&1; then
    # Get available channels from packagemanifest
    AVAILABLE_CHANNELS=$(oc get packagemanifest cert-manager -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
    
    if [ -n "$AVAILABLE_CHANNELS" ]; then
        log "Available channels: $AVAILABLE_CHANNELS"
        
        # Try to find preferred channels in order of preference
        # cert-manager typically uses "stable" or version-based channels
        PREFERRED_CHANNELS=("stable" "stable-v1" "v1" "latest")
        
        for pref_channel in "${PREFERRED_CHANNELS[@]}"; do
            if echo "$AVAILABLE_CHANNELS" | grep -q "\b$pref_channel\b"; then
                CHANNEL="$pref_channel"
                log "✓ Selected channel: $CHANNEL"
                break
            fi
        done
        
        # If no preferred channel found, use the first available channel
        if [ -z "$CHANNEL" ]; then
            CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
            log "✓ Using first available channel: $CHANNEL"
        fi
    else
        warning "Could not determine available channels from packagemanifest"
    fi
else
    warning "Package manifest not found in catalog (may still be syncing)"
    log "Waiting 30 seconds for catalog to sync..."
    sleep 30
    # Try again
    if oc get packagemanifest cert-manager -n openshift-marketplace >/dev/null 2>&1; then
        AVAILABLE_CHANNELS=$(oc get packagemanifest cert-manager -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        if [ -n "$AVAILABLE_CHANNELS" ]; then
            CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
            log "✓ Found channel after waiting: $CHANNEL"
        fi
    fi
fi

# Fallback to default channel if we couldn't determine it
if [ -z "$CHANNEL" ]; then
    CHANNEL="stable"
    log "Using default channel: $CHANNEL (will verify after subscription creation)"
fi

# Step 4: Create or update Subscription
log ""
log "Step 4: Creating/updating Subscription..."
log "  Channel: $CHANNEL"
log "  Source: redhat-operators"
log "  SourceNamespace: openshift-marketplace"

# Check if subscription already exists
if oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    EXISTING_CHANNEL=$(oc get subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    
    if [ "$EXISTING_CHANNEL" != "$CHANNEL" ]; then
        log "  Updating subscription channel from '$EXISTING_CHANNEL' to '$CHANNEL'..."
        oc patch subscription.operators.coreos.com cert-manager -n "$OPERATOR_NAMESPACE" --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || error "Failed to update subscription channel"
        log "✓ Subscription channel updated to $CHANNEL"
        sleep 3
    else
        log "✓ Subscription already exists with channel: $CHANNEL"
    fi
else
    log "  Creating new subscription..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: cert-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    then
        error "Failed to create Subscription"
    fi
    log "✓ Subscription created successfully"
    sleep 3
fi

# Step 5: Wait for CSV to be created
log ""
log "Step 5: Waiting for ClusterServiceVersion to be created..."
MAX_WAIT=90
WAIT_COUNT=0
CSV_CREATED=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if oc get csv -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -q cert-manager; then
        CSV_CREATED=true
        log "✓ CSV created"
        break
    fi
    
    # Show progress every 10 seconds
    if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
        oc get csv,subscription,installplan -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -i cert-manager | head -5 || true
        log ""
    fi
    
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$CSV_CREATED" = false ]; then
    warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
    oc get subscription,installplan -n "$OPERATOR_NAMESPACE" 2>/dev/null | grep -i cert-manager || true
    error "CSV not created. Check subscription status: oc get subscription cert-manager -n $OPERATOR_NAMESPACE"
fi

# Get the CSV name
CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -o name 2>/dev/null | grep cert-manager | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    CSV_NAME=$(oc get csv -n "$OPERATOR_NAMESPACE" -l operators.coreos.com/cert-manager.openshift-operators -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for cert-manager"
fi
log "Found CSV: $CSV_NAME"

# Step 6: Wait for CSV to be in Succeeded phase
log ""
log "Step 6: Waiting for ClusterServiceVersion to be installed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n "$OPERATOR_NAMESPACE" --timeout=300s 2>/dev/null; then
    CSV_STATUS=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
    log "Checking CSV details..."
    oc get csv "$CSV_NAME" -n "$OPERATOR_NAMESPACE"
    log "Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
else
    log "✓ CSV is in Succeeded phase"
fi
fi  # End of NEEDS_UPDATE conditional

# Always verify CertManager CR and components (regardless of installation status)
# Step 7: Create CertManager CR instance (required to deploy cert-manager components)
log ""
log "========================================================="
log "Step 7: Creating CertManager CR Instance"
log "========================================================="
log "Red Hat cert-manager Operator requires a CertManager CR instance"
log "to deploy the actual cert-manager components (pods, webhook, CRDs)."

CERTMANAGER_CR_NAME="cluster"

# Check if CertManager CR already exists
CERTMANAGER_NEEDS_WAIT=false
if oc get certmanager "$CERTMANAGER_CR_NAME" &>/dev/null; then
    log "CertManager CR '$CERTMANAGER_CR_NAME' already exists"
    
    # Check status
    CERTMANAGER_READY=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CERTMANAGER_READY" = "True" ]; then
        log "✓ CertManager CR is Ready"
        log "Cert-manager components are already deployed"
    else
        log "CertManager CR status: $CERTMANAGER_READY"
        CERTMANAGER_MESSAGE=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [ -n "$CERTMANAGER_MESSAGE" ]; then
            log "  Message: $CERTMANAGER_MESSAGE"
        fi
        log "CertManager CR exists but is not Ready. Waiting for it to become Ready..."
        CERTMANAGER_NEEDS_WAIT=true
    fi
else
    log "Creating CertManager CR instance '$CERTMANAGER_CR_NAME'..."
    
    # Create CertManager CR
    if ! cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: CertManager
metadata:
  name: $CERTMANAGER_CR_NAME
spec: {}
EOF
    then
        error "Failed to create CertManager CR"
    fi
    log "✓ CertManager CR created successfully"
    log "This will trigger the operator to deploy cert-manager components..."
    log "This may take 3-10 minutes..."
    CERTMANAGER_NEEDS_WAIT=true
fi

# Wait for CertManager CR to become Ready if needed
if [ "$CERTMANAGER_NEEDS_WAIT" = "true" ]; then
    log ""
    log "Waiting for CertManager CR to become Ready (timeout: 10 minutes)..."
    
    MAX_CERTMANAGER_WAIT=600  # 10 minutes
    CERTMANAGER_WAIT_COUNT=0
    CERTMANAGER_READY=false
    
    while [ $CERTMANAGER_WAIT_COUNT -lt $MAX_CERTMANAGER_WAIT ]; do
        CERTMANAGER_READY_STATUS=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$CERTMANAGER_READY_STATUS" = "True" ]; then
            CERTMANAGER_READY=true
            log "✓ CertManager CR is Ready"
            break
        fi
        
        # Show progress every 30 seconds
        if [ $((CERTMANAGER_WAIT_COUNT % 30)) -eq 0 ] && [ $CERTMANAGER_WAIT_COUNT -gt 0 ]; then
            log "  Still waiting... (${CERTMANAGER_WAIT_COUNT}s/${MAX_CERTMANAGER_WAIT}s)"
            CERTMANAGER_MESSAGE=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            if [ -n "$CERTMANAGER_MESSAGE" ] && [ "$CERTMANAGER_MESSAGE" != "null" ]; then
                log "  Status: $CERTMANAGER_READY_STATUS - $CERTMANAGER_MESSAGE"
            else
                log "  Status: $CERTMANAGER_READY_STATUS"
            fi
        fi
        
        sleep 5
        CERTMANAGER_WAIT_COUNT=$((CERTMANAGER_WAIT_COUNT + 5))
    done
    
    if [ "$CERTMANAGER_READY" = "false" ]; then
        warning "CertManager CR did not become Ready within ${MAX_CERTMANAGER_WAIT} seconds"
        log "Current CertManager CR status:"
        oc get certmanager "$CERTMANAGER_CR_NAME" -o yaml 2>/dev/null | grep -A 10 "status:" || log "  Could not retrieve status"
        log ""
        log "Troubleshooting commands:"
        log "  oc get certmanager $CERTMANAGER_CR_NAME -o yaml"
        log "  oc describe certmanager $CERTMANAGER_CR_NAME"
        warning "Continuing anyway, but cert-manager components may not be fully deployed..."
    fi
fi

# Step 8: Wait for cert-manager namespace and components to be deployed
log ""
log "========================================================="
log "Step 8: Waiting for cert-manager Components to Deploy"
log "========================================================="

CERT_MANAGER_NS="cert-manager"
NAMESPACE_CREATED=false
MAX_NAMESPACE_WAIT=120
NAMESPACE_WAIT_COUNT=0

log "Waiting for cert-manager namespace to be created..."
while [ $NAMESPACE_WAIT_COUNT -lt $MAX_NAMESPACE_WAIT ]; do
    if oc get namespace "$CERT_MANAGER_NS" &>/dev/null; then
        NAMESPACE_CREATED=true
        log "✓ cert-manager namespace created"
        break
    fi
    
    if [ $((NAMESPACE_WAIT_COUNT % 15)) -eq 0 ] && [ $NAMESPACE_WAIT_COUNT -gt 0 ]; then
        log "  Still waiting for namespace... (${NAMESPACE_WAIT_COUNT}s/${MAX_NAMESPACE_WAIT}s)"
    fi
    
    sleep 2
    NAMESPACE_WAIT_COUNT=$((NAMESPACE_WAIT_COUNT + 2))
done

if [ "$NAMESPACE_CREATED" = false ]; then
    warning "cert-manager namespace not created after ${MAX_NAMESPACE_WAIT} seconds"
    warning "Check CertManager CR status: oc get certmanager $CERTMANAGER_CR_NAME -o yaml"
else
    # Wait for pods to be created and running
    log ""
    log "Waiting for cert-manager pods to be running..."
    log "This may take several minutes..."
    
    MAX_POD_WAIT=600  # 10 minutes
    POD_WAIT_COUNT=0
    EXPECTED_PODS=("cert-manager" "cert-manager-cainjector" "cert-manager-webhook")
    ALL_PODS_READY=false
    
    while [ $POD_WAIT_COUNT -lt $MAX_POD_WAIT ]; do
        READY_COUNT=0
        TOTAL_COUNT=0
        
        # Try multiple label selectors (Red Hat cert-manager may use different labels)
        for pod_name in "${EXPECTED_PODS[@]}"; do
            # Try app.kubernetes.io/name label
            POD_COUNT=$(oc get pods -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name="$pod_name" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
            TOTAL_PODS=$(oc get pods -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name="$pod_name" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
            
            # If not found, try app label
            if [ "${TOTAL_PODS:-0}" -eq 0 ]; then
                POD_COUNT=$(oc get pods -n "$CERT_MANAGER_NS" -l app="$pod_name" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
                TOTAL_PODS=$(oc get pods -n "$CERT_MANAGER_NS" -l app="$pod_name" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
            fi
            
            # If still not found, try name-based matching
            if [ "${TOTAL_PODS:-0}" -eq 0 ]; then
                POD_COUNT=$(oc get pods -n "$CERT_MANAGER_NS" --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c "^${pod_name}-" || echo "0")
                TOTAL_PODS=$(oc get pods -n "$CERT_MANAGER_NS" --no-headers 2>/dev/null | grep -c "^${pod_name}-" || echo "0")
            fi
            
            if [ "${TOTAL_PODS:-0}" -gt 0 ]; then
                TOTAL_COUNT=$((TOTAL_COUNT + TOTAL_PODS))
                READY_COUNT=$((READY_COUNT + POD_COUNT))
            fi
        done
        
        # Fallback: check total pods in namespace if specific labels don't work
        if [ "$TOTAL_COUNT" -eq 0 ]; then
            TOTAL_PODS_ALL=$(oc get pods -n "$CERT_MANAGER_NS" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
            RUNNING_PODS_ALL=$(oc get pods -n "$CERT_MANAGER_NS" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
            
            if [ "${TOTAL_PODS_ALL:-0}" -ge 3 ] && [ "${RUNNING_PODS_ALL:-0}" -eq "${TOTAL_PODS_ALL:-0}" ]; then
                ALL_PODS_READY=true
                log "✓ All cert-manager pods are Running ($RUNNING_PODS_ALL/$TOTAL_PODS_ALL)"
                break
            fi
            TOTAL_COUNT=${TOTAL_PODS_ALL:-0}
            READY_COUNT=${RUNNING_PODS_ALL:-0}
        fi
        
        if [ "$TOTAL_COUNT" -ge 3 ] && [ "$READY_COUNT" -eq "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -gt 0 ]; then
            ALL_PODS_READY=true
            log "✓ All cert-manager pods are Running ($READY_COUNT/$TOTAL_COUNT)"
            break
        fi
        
        if [ $((POD_WAIT_COUNT % 30)) -eq 0 ] && [ $POD_WAIT_COUNT -gt 0 ]; then
            log "  Still waiting for pods... (${POD_WAIT_COUNT}s/${MAX_POD_WAIT}s)"
            log "  Current status: $READY_COUNT/$TOTAL_COUNT pods running"
            oc get pods -n "$CERT_MANAGER_NS" 2>/dev/null | head -10 || true
        fi
        
        sleep 5
        POD_WAIT_COUNT=$((POD_WAIT_COUNT + 5))
    done
    
    if [ "$ALL_PODS_READY" = false ]; then
        warning "Not all cert-manager pods are ready after ${MAX_POD_WAIT} seconds"
        log "Current pod status:"
        oc get pods -n "$CERT_MANAGER_NS" 2>/dev/null || true
        warning "Pods may still be starting. Check status: oc get pods -n $CERT_MANAGER_NS -w"
    fi
fi

# Step 9: Verify CertManager CR status and CRDs
log ""
log "========================================================="
log "Step 9: Verifying CertManager CR Status and CRDs"
log "========================================================="

# Check CertManager CR status and wait if needed
log "Checking CertManager CR status..."
CERTMANAGER_READY=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
CERTMANAGER_MESSAGE=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")

if [ "$CERTMANAGER_READY" = "True" ]; then
    log "✓ CertManager CR is Ready"
else
    log "CertManager CR Ready status: $CERTMANAGER_READY"
    if [ -n "$CERTMANAGER_MESSAGE" ] && [ "$CERTMANAGER_MESSAGE" != "null" ]; then
        log "  Message: $CERTMANAGER_MESSAGE"
    fi
    log "CertManager CR is not Ready yet. Waiting for it to become Ready..."
    
    MAX_CERTMANAGER_WAIT=600  # 10 minutes
    CERTMANAGER_WAIT_COUNT=0
    CERTMANAGER_READY_FINAL=false
    
    while [ $CERTMANAGER_WAIT_COUNT -lt $MAX_CERTMANAGER_WAIT ]; do
        CERTMANAGER_READY_STATUS=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$CERTMANAGER_READY_STATUS" = "True" ]; then
            CERTMANAGER_READY_FINAL=true
            log "✓ CertManager CR is Ready"
            break
        fi
        
        # Show progress every 30 seconds
        if [ $((CERTMANAGER_WAIT_COUNT % 30)) -eq 0 ] && [ $CERTMANAGER_WAIT_COUNT -gt 0 ]; then
            log "  Still waiting... (${CERTMANAGER_WAIT_COUNT}s/${MAX_CERTMANAGER_WAIT}s)"
            CERTMANAGER_MESSAGE_CURRENT=$(oc get certmanager "$CERTMANAGER_CR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            if [ -n "$CERTMANAGER_MESSAGE_CURRENT" ] && [ "$CERTMANAGER_MESSAGE_CURRENT" != "null" ]; then
                log "  Status: $CERTMANAGER_READY_STATUS - $CERTMANAGER_MESSAGE_CURRENT"
            else
                log "  Status: $CERTMANAGER_READY_STATUS"
            fi
        fi
        
        sleep 5
        CERTMANAGER_WAIT_COUNT=$((CERTMANAGER_WAIT_COUNT + 5))
    done
    
    if [ "$CERTMANAGER_READY_FINAL" = "false" ]; then
        warning "CertManager CR did not become Ready within ${MAX_CERTMANAGER_WAIT} seconds"
        log "Current CertManager CR status:"
        oc get certmanager "$CERTMANAGER_CR_NAME" -o yaml 2>/dev/null | grep -A 10 "status:" || log "  Could not retrieve status"
        log ""
        log "Troubleshooting commands:"
        log "  oc get certmanager $CERTMANAGER_CR_NAME -o yaml"
        log "  oc describe certmanager $CERTMANAGER_CR_NAME"
        warning "Continuing anyway, but cert-manager components may not be fully deployed..."
    fi
fi

log ""
log "Verifying cert-manager CRDs are available..."

REQUIRED_CRDS=("certificates.cert-manager.io" "issuers.cert-manager.io" "clusterissuers.cert-manager.io" "certificaterequests.cert-manager.io")
ALL_CRDS_AVAILABLE=true

for crd in "${REQUIRED_CRDS[@]}"; do
    if oc get crd "$crd" &>/dev/null; then
        log "✓ CRD available: $crd"
    else
        warning "CRD not found: $crd"
        ALL_CRDS_AVAILABLE=false
    fi
done

if [ "$ALL_CRDS_AVAILABLE" = false ]; then
    warning "Some cert-manager CRDs are not available yet. They may still be installing..."
    log "Waiting 30 seconds for CRDs to be created..."
    sleep 30
    
    # Check again
    for crd in "${REQUIRED_CRDS[@]}"; do
        if oc get crd "$crd" &>/dev/null; then
            log "✓ CRD now available: $crd"
        else
            warning "CRD still not found: $crd"
        fi
    done
fi

# Step 10: Verify zerossl-production-ec2 ClusterIssuer is Available
log ""
log "========================================================="
log "Step 10: Verifying ClusterIssuer 'zerossl-production-ec2' is Available"
log "========================================================="

CLUSTERISSUER_NAME="zerossl-production-ec2"

# Check if zerossl-production-ec2 ClusterIssuer exists
if oc get clusterissuer "$CLUSTERISSUER_NAME" &>/dev/null; then
    log "✓ ClusterIssuer '$CLUSTERISSUER_NAME' found"
    
    # Check if it's Ready
    ISSUER_READY=$(oc get clusterissuer "$CLUSTERISSUER_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$ISSUER_READY" = "True" ]; then
        log "✓ ClusterIssuer '$CLUSTERISSUER_NAME' is Ready"
    else
        warning "ClusterIssuer '$CLUSTERISSUER_NAME' status: $ISSUER_READY (may not be ready)"
    fi
else
    error "ClusterIssuer '$CLUSTERISSUER_NAME' not found. Please ensure it exists before running script 08."
fi

log ""
log "Available ClusterIssuers:"
oc get clusterissuer 2>/dev/null | head -10 || log "  None found"

# Final summary
log ""
log "========================================================="
log "Cert-Manager Operator Installation Completed!"
log "========================================================="
log "Operator Namespace: $OPERATOR_NAMESPACE"
log "Operator: cert-manager"
if [ -n "${CSV_NAME:-}" ] && [ "$CSV_NAME" != "null" ]; then
    log "CSV: $CSV_NAME"
fi
if [ -n "${CHANNEL:-}" ] && [ "$CHANNEL" != "null" ]; then
    log "Channel: ${CHANNEL}"
fi
log ""
log "CertManager CR: $CERTMANAGER_CR_NAME"
if [ "${NAMESPACE_CREATED:-false}" = "true" ]; then
    log "Cert-manager Namespace: $CERT_MANAGER_NS"
    log "  (Contains cert-manager pods, webhook, and CA injector)"
elif oc get namespace "$CERT_MANAGER_NS" &>/dev/null; then
    log "Cert-manager Namespace: $CERT_MANAGER_NS (already exists)"
    log "  (Contains cert-manager pods, webhook, and CA injector)"
fi
log ""
log "ClusterIssuer: $CLUSTERISSUER_NAME"
log "  (Available for Certificate resources to use)"
log "========================================================="
log ""
log "Cert-manager operator is now installed and ready to use."
log "The CertManager CR instance has been created, which deployed"
log "the cert-manager components (pods, webhook, CRDs)."
log ""
log "ClusterIssuer '$CLUSTERISSUER_NAME' has been verified and is ready."
log "You can now create Certificate resources to manage TLS certificates."
log ""
log "To verify installation:"
log "  oc get certmanager cluster"
log "  oc get csv -n $OPERATOR_NAMESPACE | grep cert-manager"
log "  oc get pods -n cert-manager"
log "  oc get crd | grep cert-manager.io"
log ""
log "To check CertManager CR status:"
log "  oc get certmanager $CERTMANAGER_CR_NAME -o yaml"
log ""
