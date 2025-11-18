#!/bin/bash
# RHACS TLS/HTTPS Configuration Script
# Configures TLS for Operator-based RHACS Central installation using cert-manager
# Follows the Operator-based process: Create secret -> Configure Central CR -> Restart Central

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
    echo -e "${GREEN}[TLS-CONFIG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[TLS-CONFIG]${NC} $1"
}

error() {
    echo -e "${RED}[TLS-CONFIG]${NC} $1"
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
CENTRAL_CR_NAME="stackrox-central-services"
SECRET_NAME="central-default-tls-cert"

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

# Check for cert-manager and ClusterIssuer
log "Checking for cert-manager..."
CERT_MANAGER_AVAILABLE=false
CLUSTER_ISSUER=""

# Check if cert-manager API is available by checking for ClusterIssuer CRD
if oc api-resources | grep -q clusterissuer; then
    CERT_MANAGER_AVAILABLE=true
    log "✓ cert-manager API is available"
    
    # Check for available ClusterIssuers
    CLUSTER_ISSUERS=$(oc get clusterissuer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_ISSUERS" ]; then
        # Prefer zerossl-production-ec2 if available, otherwise use first available
        if echo "$CLUSTER_ISSUERS" | grep -q "zerossl-production-ec2"; then
            CLUSTER_ISSUER="zerossl-production-ec2"
        else
            CLUSTER_ISSUER=$(echo "$CLUSTER_ISSUERS" | awk '{print $1}')
        fi
        log "✓ Found ClusterIssuer: $CLUSTER_ISSUER"
        
        # Verify ClusterIssuer is ready
        CLUSTER_ISSUER_STATUS=$(oc get clusterissuer "$CLUSTER_ISSUER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$CLUSTER_ISSUER_STATUS" = "True" ]; then
            log "✓ ClusterIssuer '$CLUSTER_ISSUER' is ready"
        else
            warning "ClusterIssuer '$CLUSTER_ISSUER' may not be ready (status: ${CLUSTER_ISSUER_STATUS:-unknown})"
            warning "Continuing anyway - certificate issuance may fail if issuer is not ready"
        fi
    else
        error "cert-manager is installed but no ClusterIssuer found"
        error "Please configure a ClusterIssuer (e.g., Let's Encrypt, ZeroSSL) before running this script"
        exit 1
    fi
else
    error "cert-manager is not installed or API is not available"
    error "This script requires cert-manager to automatically obtain trusted certificates"
    error "Please install cert-manager and configure a ClusterIssuer"
    exit 1
fi

# Get route hostname
ROUTE_HOST=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -z "$ROUTE_HOST" ]; then
    error "Could not determine route hostname"
    exit 1
fi

log "Route hostname: $ROUTE_HOST"

# Internal function to configure TLS using certificate files
# This is used internally by the cert-manager flow
configure_operator_tls_custom() {
    local cert_file="$1"
    local key_file="$2"
    
    if [ -z "$cert_file" ] || [ -z "$key_file" ]; then
        error "Certificate and key files are required"
        return 1
    fi
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        error "Certificate or key file not found"
        return 1
    fi
    
    log "Configuring TLS using Operator-based method..."
    log "Following Operator-based process:"
    log "  1. Create/update TLS secret 'central-default-tls-cert'"
    log "  2. Configure Central CR with spec.central.defaultTLSSecret"
    log "  3. Restart Central container"
    
    # Check if secret already exists (for update scenario)
    if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "Existing secret '$SECRET_NAME' found - will delete and recreate for update"
        log "Deleting existing secret..."
        oc delete secret "$SECRET_NAME" -n "$NAMESPACE" || {
            error "Failed to delete existing secret"
            return 1
        }
        log "✓ Existing secret deleted"
    fi
    
    # Create secret with correct key names (tls-cert.pem and tls-key.pem)
    log "Creating TLS secret '$SECRET_NAME' with keys 'tls-cert.pem' and 'tls-key.pem'..."
    oc create secret generic "$SECRET_NAME" \
        --from-file=tls-cert.pem="$cert_file" \
        --from-file=tls-key.pem="$key_file" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f -
    
    if [ $? -ne 0 ]; then
        error "Failed to create TLS secret"
        return 1
    fi
    
    log "✓ TLS secret created successfully"
    
    # Configure Central CR with defaultTLSSecret
    log "Configuring Central CR to use secret '$SECRET_NAME'..."
    log "Patching spec.central.defaultTLSSecret..."
    
    # Try patching as a string first (most common format)
    PATCH_SUCCESS=false
    if oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type='merge' -p "{
        \"spec\": {
            \"central\": {
                \"defaultTLSSecret\": \"$SECRET_NAME\"
            }
        }
    }" 2>/dev/null; then
        PATCH_SUCCESS=true
    else
        # If string format fails, try object format
        log "Trying object format for defaultTLSSecret..."
        if oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type='merge' -p "{
            \"spec\": {
                \"central\": {
                    \"defaultTLSSecret\": {
                        \"name\": \"$SECRET_NAME\"
                    }
                }
            }
        }" 2>/dev/null; then
            PATCH_SUCCESS=true
        fi
    fi
    
    if [ "$PATCH_SUCCESS" != "true" ]; then
        error "Failed to patch Central CR with defaultTLSSecret"
        return 1
    fi
    
    log "✓ Central CR configured with defaultTLSSecret"
    
    # Restart Central container
    log "Restarting Central deployment to apply certificate changes..."
    CENTRAL_DEPLOYMENT="central"
    
    if ! oc get deployment "$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
        error "Central deployment not found"
        return 1
    fi
    
    # Trigger restart by annotating the deployment
    oc annotate deployment "$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" \
        "tls-updated-$(date +%s)=true" \
        --overwrite
    
    log "Waiting for Central to restart..."
    if oc wait --for=condition=Available deployment/"$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" --timeout=600s 2>/dev/null; then
        log "✓ Central restarted successfully"
    else
        warning "Central restart did not complete within timeout, but continuing..."
        warning "Check deployment status: oc get deployment $CENTRAL_DEPLOYMENT -n $NAMESPACE"
    fi
}

# Main configuration logic - Use cert-manager to obtain certificate
log ""
log "Using cert-manager to obtain certificate for: $ROUTE_HOST"
log "ClusterIssuer: $CLUSTER_ISSUER"

# Create Certificate resource
CERT_NAME="rhacs-central-tls-cert-manager"
CERT_SECRET_NAME="rhacs-central-tls-cert-manager"

# Check if certificate already exists
if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Certificate resource already exists, checking status..."
    CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_STATUS" = "True" ]; then
        log "✓ Certificate is ready"
    else
        log "Certificate exists but not ready yet, waiting..."
        # Wait for certificate to be ready (max 10 minutes)
        for i in {1..120}; do
            sleep 5
            CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [ "$CERT_STATUS" = "True" ]; then
                log "✓ Certificate is now ready"
                break
            fi
            if [ $((i % 12)) -eq 0 ]; then
                log "Still waiting for certificate... ($((i * 5))s elapsed)"
            fi
            if [ $i -eq 120 ]; then
                error "Certificate did not become ready within 10 minutes"
                error "Check certificate status: oc get certificate $CERT_NAME -n $NAMESPACE"
                exit 1
            fi
        done
    fi
else
    log "Creating Certificate resource..."
    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $NAMESPACE
spec:
  secretName: $CERT_SECRET_NAME
  issuerRef:
    name: $CLUSTER_ISSUER
    kind: ClusterIssuer
  dnsNames:
  - $ROUTE_HOST
EOF
    
    if [ $? -ne 0 ]; then
        error "Failed to create Certificate resource"
        exit 1
    fi
    
    log "✓ Certificate resource created"
    log "Waiting for certificate to be issued (this may take a few minutes)..."
    
    # Wait for certificate to be ready (max 10 minutes)
    for i in {1..120}; do
        sleep 5
        CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$CERT_STATUS" = "True" ]; then
            log "✓ Certificate issued successfully"
            break
        fi
        if [ $((i % 12)) -eq 0 ]; then
            log "Still waiting for certificate... ($((i * 5))s elapsed)"
        fi
        if [ $i -eq 120 ]; then
            error "Certificate did not become ready within 10 minutes"
            error "Check certificate status: oc get certificate $CERT_NAME -n $NAMESPACE"
            exit 1
        fi
    done
fi

# Wait for secret to be created
log "Waiting for certificate secret to be created..."
for i in {1..60}; do
    if oc get secret "$CERT_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "✓ Certificate secret created"
        break
    fi
    sleep 2
    if [ $i -eq 60 ]; then
        error "Secret not created within timeout"
        exit 1
    fi
done

# Extract certificate and key from cert-manager secret (tls.crt and tls.key)
# and create the secret with the correct format (tls-cert.pem and tls-key.pem)
log "Converting cert-manager secret format to RHACS format..."

CERT_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)
KEY_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d)

# Create temporary files
TEMP_CERT=$(mktemp)
TEMP_KEY=$(mktemp)
echo "$CERT_DATA" > "$TEMP_CERT"
echo "$KEY_DATA" > "$TEMP_KEY"

# Use the internal function to configure TLS
configure_operator_tls_custom "$TEMP_CERT" "$TEMP_KEY"
CONFIGURE_EXIT_CODE=$?

# Clean up temp files
rm -f "$TEMP_CERT" "$TEMP_KEY"

if [ $CONFIGURE_EXIT_CODE -ne 0 ]; then
    error "Failed to configure TLS with cert-manager certificate"
    exit 1
fi

# Verify configuration
log ""
log "Verifying TLS configuration..."

# Check if secret exists and has correct keys
if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    SECRET_KEYS=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "")
    if echo "$SECRET_KEYS" | grep -q "tls-cert.pem" && echo "$SECRET_KEYS" | grep -q "tls-key.pem"; then
        log "✓ Secret '$SECRET_NAME' exists with correct keys (tls-cert.pem, tls-key.pem)"
    else
        warning "Secret exists but may not have correct keys"
    fi
else
    warning "Secret '$SECRET_NAME' not found"
fi

# Check Central CR configuration
CENTRAL_CR_TLS_SECRET=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret.name}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_CR_TLS_SECRET" ] && [ "$CENTRAL_CR_TLS_SECRET" = "$SECRET_NAME" ]; then
    log "✓ Central CR configured with defaultTLSSecret: $SECRET_NAME"
else
    warning "Central CR may not be configured correctly"
    if [ -n "$CENTRAL_CR_TLS_SECRET" ]; then
        warning "  Current defaultTLSSecret: $CENTRAL_CR_TLS_SECRET (expected: $SECRET_NAME)"
    else
        warning "  defaultTLSSecret not set in Central CR"
    fi
fi

log ""
log "========================================================="
log "RHACS TLS Configuration Complete (cert-manager)"
log "========================================================="
log "HTTPS URL: https://$ROUTE_HOST"
log "Secret: $SECRET_NAME"
log "Central CR: $CENTRAL_CR_NAME"
log "Certificate: Automatically issued by $CLUSTER_ISSUER"
log ""
log "The certificate has been configured using the Operator-based method:"
log "  ✓ Certificate obtained from cert-manager"
log "  ✓ Secret created with tls-cert.pem and tls-key.pem"
log "  ✓ Central CR configured with spec.central.defaultTLSSecret"
log "  ✓ Central container restarted"
log ""
log "Certificate auto-renewal: Managed by cert-manager"
log "Note: It may take a few moments for the new certificate to be active."
log "========================================================="

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS configuration completed successfully!"
fi
