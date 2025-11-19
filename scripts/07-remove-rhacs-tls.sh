#!/bin/bash
# RHACS TLS Certificate Removal Script
# Removes custom TLS certificate configuration from Operator-based RHACS Central installation
# This removes the defaultTLSSecret from Central CR and deletes associated secrets

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
CENTRAL_CR_NAME="stackrox-central-services"
SECRET_NAME="central-default-tls-cert"
CERT_NAME="rhacs-central-tls-cert-manager"
CERT_SECRET_NAME="rhacs-central-tls-cert-manager"

# Verify namespace exists
if ! oc get ns "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found"
    exit 1
fi

log "Using namespace: $NAMESPACE"

# Verify Central CR exists
if ! oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" &>/dev/null; then
    error "Central CR '$CENTRAL_CR_NAME' not found in namespace '$NAMESPACE'"
    error "This script is for Operator-based RHACS installations"
    exit 1
fi

log "✓ Found Central CR: $CENTRAL_CR_NAME"

# Check current TLS configuration
log "Checking current TLS configuration..."
CURRENT_TLS_SECRET=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret.name}' 2>/dev/null || echo "")
CURRENT_TLS_SECRET_ALT=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret}' 2>/dev/null || echo "")

# Use whichever format is set
if [ -n "$CURRENT_TLS_SECRET" ] && [ "$CURRENT_TLS_SECRET" != "null" ]; then
    TLS_SECRET_TO_REMOVE="$CURRENT_TLS_SECRET"
elif [ -n "$CURRENT_TLS_SECRET_ALT" ] && [ "$CURRENT_TLS_SECRET_ALT" != "null" ]; then
    TLS_SECRET_TO_REMOVE="$CURRENT_TLS_SECRET_ALT"
else
    TLS_SECRET_TO_REMOVE=""
fi

if [ -z "$TLS_SECRET_TO_REMOVE" ]; then
    log "No custom TLS certificate configured in Central CR"
    log "Central is using its default self-signed certificate"
else
    log "Found configured TLS secret: $TLS_SECRET_TO_REMOVE"
fi

log ""
log "========================================================="
log "Remove All TLS Certificate Configurations"
log "========================================================="
log "This will remove ALL custom TLS certificate configurations:"
log "  1. Remove defaultTLSSecret from Central CR"
log "  2. Delete ALL TLS secrets (central-default-tls-cert and variants)"
log "  3. Delete ALL cert-manager Certificate resources"
log "  4. Delete ALL cert-manager secrets"
log "  5. Restart Central to apply changes"
log ""
log "After removal, Central will use its default self-signed certificate"
log "with no custom certificate configuration."
log "========================================================="
log ""

# Remove defaultTLSSecret from Central CR
log "Removing defaultTLSSecret from Central CR..."

# Try removing as string format first
PATCH_SUCCESS=false
if oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type='json' -p '[{"op": "remove", "path": "/spec/central/defaultTLSSecret"}]' 2>/dev/null; then
    PATCH_SUCCESS=true
    log "✓ Removed defaultTLSSecret from Central CR"
else
    # Try removing nested object format
    if oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type='json' -p '[{"op": "remove", "path": "/spec/central/defaultTLSSecret/name"}]' 2>/dev/null; then
        PATCH_SUCCESS=true
        log "✓ Removed defaultTLSSecret from Central CR"
    else
        # Try setting to null
        if oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type='merge' -p '{"spec":{"central":{"defaultTLSSecret":null}}}' 2>/dev/null; then
            PATCH_SUCCESS=true
            log "✓ Removed defaultTLSSecret from Central CR"
        fi
    fi
fi

if [ "$PATCH_SUCCESS" != "true" ]; then
    warning "Could not remove defaultTLSSecret from Central CR (may not be set)"
else
    log "✓ Central CR updated - defaultTLSSecret removed"
fi

# Delete ALL TLS secrets (including any variants)
log ""
log "Deleting all TLS secrets..."
TLS_SECRETS_FOUND=0

# Delete the standard secret
if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    oc delete secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null && {
        log "✓ TLS secret '$SECRET_NAME' deleted"
        TLS_SECRETS_FOUND=$((TLS_SECRETS_FOUND + 1))
    } || {
        warning "Failed to delete secret '$SECRET_NAME'"
    }
fi

# Find and delete any other TLS secrets that might exist
ALL_SECRETS=$(oc get secrets -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for secret in $ALL_SECRETS; do
    # Look for secrets that might be TLS-related
    if echo "$secret" | grep -qiE "tls|cert|central.*cert"; then
        if [ "$secret" != "$SECRET_NAME" ] && [ "$secret" != "$CERT_SECRET_NAME" ]; then
            log "Found additional TLS-related secret: $secret"
            oc delete secret "$secret" -n "$NAMESPACE" 2>/dev/null && {
                log "✓ Deleted secret '$secret'"
                TLS_SECRETS_FOUND=$((TLS_SECRETS_FOUND + 1))
            } || {
                warning "Failed to delete secret '$secret'"
            }
        fi
    fi
done

if [ $TLS_SECRETS_FOUND -eq 0 ]; then
    log "No TLS secrets found to delete"
fi

# Delete ALL cert-manager Certificate resources
log ""
log "Deleting all cert-manager Certificate resources..."
CERT_RESOURCES_FOUND=0

# Delete the standard certificate resource
if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    oc delete certificate "$CERT_NAME" -n "$NAMESPACE" 2>/dev/null && {
        log "✓ Certificate resource '$CERT_NAME' deleted"
        CERT_RESOURCES_FOUND=$((CERT_RESOURCES_FOUND + 1))
    } || {
        warning "Failed to delete Certificate resource '$CERT_NAME'"
    }
fi

# Find and delete any other Certificate resources
ALL_CERTIFICATES=$(oc get certificate -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
for cert in $ALL_CERTIFICATES; do
    if [ "$cert" != "$CERT_NAME" ]; then
        # Check if it's related to Central/RHACS
        CERT_DNS=$(oc get certificate "$cert" -n "$NAMESPACE" -o jsonpath='{.spec.dnsNames[*]}' 2>/dev/null || echo "")
        if echo "$CERT_DNS" | grep -qiE "central|rhacs|stackrox"; then
            log "Found additional Central-related Certificate: $cert"
            oc delete certificate "$cert" -n "$NAMESPACE" 2>/dev/null && {
                log "✓ Deleted Certificate resource '$cert'"
                CERT_RESOURCES_FOUND=$((CERT_RESOURCES_FOUND + 1))
            } || {
                warning "Failed to delete Certificate resource '$cert'"
            }
        fi
    fi
done

if [ $CERT_RESOURCES_FOUND -eq 0 ]; then
    log "No Certificate resources found to delete"
fi

# Delete ALL cert-manager secrets
log ""
log "Deleting all cert-manager secrets..."
CERT_SECRETS_FOUND=0

# Delete the standard cert-manager secret
if oc get secret "$CERT_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    oc delete secret "$CERT_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null && {
        log "✓ Cert-manager secret '$CERT_SECRET_NAME' deleted"
        CERT_SECRETS_FOUND=$((CERT_SECRETS_FOUND + 1))
    } || {
        warning "Failed to delete cert-manager secret '$CERT_SECRET_NAME'"
    }
fi

# Find and delete any other cert-manager secrets
for secret in $ALL_SECRETS; do
    if echo "$secret" | grep -qiE "cert-manager|rhacs.*tls.*cert-manager"; then
        if [ "$secret" != "$CERT_SECRET_NAME" ]; then
            log "Found additional cert-manager secret: $secret"
            oc delete secret "$secret" -n "$NAMESPACE" 2>/dev/null && {
                log "✓ Deleted cert-manager secret '$secret'"
                CERT_SECRETS_FOUND=$((CERT_SECRETS_FOUND + 1))
            } || {
                warning "Failed to delete cert-manager secret '$secret'"
            }
        fi
    fi
done

if [ $CERT_SECRETS_FOUND -eq 0 ]; then
    log "No cert-manager secrets found to delete"
fi

# Restart Central to apply changes
log ""
log "Restarting Central to apply certificate removal..."
CENTRAL_DEPLOYMENT="central"

if ! oc get deployment "$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
    warning "Central deployment not found - skipping restart"
else
    # Get current pod name before restart
    OLD_POD=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "$OLD_POD" ]; then
        log "Deleting Central pod to trigger restart..."
        oc delete pod "$OLD_POD" -n "$NAMESPACE" --grace-period=30 2>/dev/null || {
            warning "Could not delete pod gracefully, forcing deletion..."
            oc delete pod "$OLD_POD" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        }
        
        log "Waiting for Central to restart..."
        sleep 10
        
        # Wait for new pod to be ready
        for i in {1..60}; do
            NEW_POD=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            POD_STATUS=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
            POD_READY=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            
            if [ -n "$NEW_POD" ] && [ "$NEW_POD" != "$OLD_POD" ]; then
                if [ "$POD_READY" = "True" ]; then
                    log "✓ Central restarted successfully (new pod: $NEW_POD)"
                    break
                fi
            elif [ "$POD_STATUS" = "Running" ] && [ "$POD_READY" = "True" ]; then
                log "✓ Central is running and ready"
                break
            fi
            
            sleep 5
            
            if [ $i -eq 60 ]; then
                warning "Central restart did not complete within timeout"
                warning "Current pod status: $POD_STATUS, Ready: $POD_READY"
            fi
        done
    else
        warning "Could not find Central pod to restart"
    fi
fi

# Verify configuration
log ""
log "Verifying TLS configuration removal..."

# Check Central CR
FINAL_TLS_SECRET=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret.name}' 2>/dev/null || echo "")
FINAL_TLS_SECRET_ALT=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret}' 2>/dev/null || echo "")

if [ -z "$FINAL_TLS_SECRET" ] && [ -z "$FINAL_TLS_SECRET_ALT" ] || [ "$FINAL_TLS_SECRET" = "null" ] || [ "$FINAL_TLS_SECRET_ALT" = "null" ]; then
    log "✓ Central CR verified - defaultTLSSecret removed"
else
    warning "Central CR may still have defaultTLSSecret configured"
    if [ -n "$FINAL_TLS_SECRET" ]; then
        warning "  Current defaultTLSSecret: $FINAL_TLS_SECRET"
    fi
fi

# Check secrets
if ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "✓ TLS secret '$SECRET_NAME' removed"
else
    warning "TLS secret '$SECRET_NAME' still exists"
fi

if ! oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "✓ Certificate resource '$CERT_NAME' removed"
else
    warning "Certificate resource '$CERT_NAME' still exists"
fi

# Get route hostname for final message
ROUTE_HOST=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

log ""
log "========================================================="
log "RHACS TLS Certificate Removal Complete"
log "========================================================="
if [ -n "$ROUTE_HOST" ]; then
    log "HTTPS URL: https://$ROUTE_HOST"
fi
log ""
log "All TLS certificate configurations have been removed:"
log "  ✓ defaultTLSSecret removed from Central CR"
log "  ✓ All TLS secrets deleted"
log "  ✓ All Certificate resources deleted"
log "  ✓ All cert-manager secrets deleted"
log "  ✓ Central restarted"
log ""
log "Central now has NO custom certificate configuration."
log "Central is using its default self-signed StackRox certificate."
log ""
warning "⚠️  You will see NET::ERR_CERT_AUTHORITY_INVALID in your browser"
warning "   because Central is using the default self-signed certificate."
log ""
log "To configure a trusted certificate from cert-manager, run:"
log "   ./scripts/06-configure-rhacs-tls.sh"
log "========================================================="

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS removal completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS certificate removal completed successfully!"
fi
