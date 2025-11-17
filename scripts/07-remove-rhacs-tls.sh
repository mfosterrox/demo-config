#!/bin/bash
# RHACS TLS/HTTPS Route Removal Script
# Removes TLS termination from the RHACS Central route in OpenShift

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[TLS-REMOVE]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[TLS-REMOVE]${NC} $1"
}

error() {
    echo -e "${RED}[TLS-REMOVE]${NC} $1"
    SCRIPT_FAILED=true
}

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
    exit 1
fi

log "✓ OpenShift CLI connected"

# Configuration variables
NAMESPACE="tssc-acs"
ROUTE_NAME="central"

# Verify namespace and route exist
if ! oc get ns "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found"
    exit 1
fi

if ! oc -n "$NAMESPACE" get route "$ROUTE_NAME" &>/dev/null; then
    error "RHACS route '$ROUTE_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

log "Using namespace: $NAMESPACE"

# Check current route configuration
log "Checking current route configuration..."
CURRENT_ROUTE=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o json)

if [ -z "$CURRENT_ROUTE" ]; then
    error "Failed to retrieve route configuration"
    exit 1
fi

CURRENT_TLS=$(echo "$CURRENT_ROUTE" | jq -r '.spec.tls // empty' 2>/dev/null)
CURRENT_HOST=$(echo "$CURRENT_ROUTE" | jq -r '.spec.host' 2>/dev/null)

log "Current route host: $CURRENT_HOST"

if [ -z "$CURRENT_TLS" ] || [ "$CURRENT_TLS" = "null" ]; then
    log "Route does not have TLS configured"
    log "No changes needed"
    exit 0
fi

TERMINATION=$(echo "$CURRENT_ROUTE" | jq -r '.spec.tls.termination // "none"')
log "Current TLS termination: $TERMINATION"

# Confirm removal
log ""
log "========================================================="
log "Remove TLS Configuration"
log "========================================================="
log "This will remove TLS/HTTPS configuration from the route."
log "The route will be accessible via HTTP only after this change."
log ""

# Remove TLS configuration
log "Removing TLS configuration from route..."
oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='json' -p '[{"op": "remove", "path": "/spec/tls"}]'

if [ $? -eq 0 ]; then
    log "✓ TLS configuration removed successfully"
else
    error "Failed to remove TLS configuration"
    exit 1
fi

# Verify configuration
log ""
log "Verifying route configuration..."
UPDATED_ROUTE=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o json)
UPDATED_TLS=$(echo "$UPDATED_ROUTE" | jq -r '.spec.tls // empty' 2>/dev/null)

if [ -z "$UPDATED_TLS" ] || [ "$UPDATED_TLS" = "null" ]; then
    log "✓ Route TLS configuration verified - TLS has been removed"
    log ""
    log "========================================================="
    log "RHACS TLS Removal Complete"
    log "========================================================="
    log "HTTP URL: http://$CURRENT_HOST"
    log "HTTPS URL: https://$CURRENT_HOST (no longer configured)"
    log ""
    log "To re-enable TLS, run:"
    log "   ./scripts/06-configure-rhacs-tls.sh"
    log "========================================================="
else
    warning "TLS configuration may not have been removed correctly"
    log "Current TLS config: $UPDATED_TLS"
fi

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS removal completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS removal completed successfully!"
fi

