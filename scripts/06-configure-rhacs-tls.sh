#!/bin/bash
# RHACS TLS/HTTPS Configuration Script
# Configures TLS for Operator-based RHACS Central installation
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

if oc get namespace cert-manager &>/dev/null && oc get pods -n cert-manager &>/dev/null | grep -q Running; then
    CERT_MANAGER_AVAILABLE=true
    log "✓ cert-manager is installed and running"
    
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
    else
        warning "cert-manager is installed but no ClusterIssuer found"
    fi
else
    log "cert-manager not found, will use default router certificate"
fi

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
if [ -n "$CURRENT_TLS" ] && [ "$CURRENT_TLS" != "null" ]; then
    log "Current TLS termination: $(echo "$CURRENT_ROUTE" | jq -r '.spec.tls.termination // "none"')"
else
    log "Current TLS termination: none"
fi

# Function to configure TLS using cert-manager
configure_cert_manager_tls() {
    local cluster_issuer="$1"
    local route_host="$2"
    
    log "Configuring TLS using cert-manager with ClusterIssuer: $cluster_issuer"
    
    # Certificate name and secret name
    CERT_NAME="rhacs-central-tls"
    SECRET_NAME="rhacs-central-tls"
    
    # Check if certificate already exists
    if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "Certificate resource already exists, checking status..."
        CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [ "$CERT_STATUS" = "True" ]; then
            log "✓ Certificate is ready"
        else
            log "Certificate exists but not ready yet, waiting..."
            # Wait for certificate to be ready (max 5 minutes)
            for i in {1..60}; do
                sleep 5
                CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                if [ "$CERT_STATUS" = "True" ]; then
                    log "✓ Certificate is now ready"
                    break
                fi
                if [ $i -eq 60 ]; then
                    warning "Certificate did not become ready within timeout"
                fi
            done
        fi
    else
        # Create Certificate resource
        log "Creating Certificate resource..."
        cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $NAMESPACE
spec:
  secretName: $SECRET_NAME
  issuerRef:
    name: $cluster_issuer
    kind: ClusterIssuer
  dnsNames:
  - $route_host
EOF
        
        if [ $? -eq 0 ]; then
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
                    warning "Certificate did not become ready within 10 minutes"
                    warning "Check certificate status: oc get certificate $CERT_NAME -n $NAMESPACE"
                fi
            done
        else
            error "Failed to create Certificate resource"
            return 1
        fi
    fi
    
    # Wait for secret to be created by cert-manager
    log "Waiting for certificate secret to be created..."
    for i in {1..60}; do
        if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
            log "✓ Certificate secret created"
            break
        fi
        sleep 2
        if [ $i -eq 60 ]; then
            warning "Secret not created yet, but continuing..."
        fi
    done
    
    # Configure route to use the certificate secret
    log "Configuring route to use certificate from secret..."
    
    # Get certificate and key from secret
    if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        CERT_DATA=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d)
        KEY_DATA=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' | base64 -d)
        
        # Patch route with certificate and key using reencrypt termination
        # Reencrypt is needed because RHACS Central backend expects HTTPS
        oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p "{
            \"spec\": {
                \"tls\": {
                    \"termination\": \"reencrypt\",
                    \"insecureEdgeTerminationPolicy\": \"Redirect\",
                    \"certificate\": \"$(echo -n "$CERT_DATA" | base64 -w 0)\",
                    \"key\": \"$(echo -n "$KEY_DATA" | base64 -w 0)\"
                }
            }
        }"
    else
        # If secret doesn't exist yet, configure route structure with reencrypt termination
        oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p '{
            "spec": {
                "tls": {
                    "termination": "reencrypt",
                    "insecureEdgeTerminationPolicy": "Redirect"
                }
            }
        }'
        warning "Certificate secret not ready yet. Route will be updated automatically when certificate is issued."
    fi
    
    # Annotate route to reference the certificate (for cert-manager tracking)
    oc annotate route "$ROUTE_NAME" -n "$NAMESPACE" \
        cert-manager.io/certificate-name="$CERT_NAME" \
        --overwrite 2>/dev/null || true
    
    # Wait a moment for route to update (router picks up changes automatically)
    log "Waiting for router to pick up route changes..."
    sleep 5
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured successfully using cert-manager"
        log "  Termination: reencrypt (TLS terminates at router, re-encrypts to backend)"
        log "  Certificate: Managed by cert-manager"
        log "  ClusterIssuer: $cluster_issuer"
        log "  Secret: $SECRET_NAME"
        log ""
        log "Note: No restart of Central is required - route changes are applied automatically by the router"
    else
        error "Failed to configure route with cert-manager certificate"
        return 1
    fi
}

# Function to configure TLS with reencrypt termination (default router certificate)
# Reencrypt is required because RHACS Central backend service expects HTTPS
configure_edge_tls_default() {
    log "Configuring TLS with reencrypt termination using default router certificate..."
    log "Note: Using reencrypt because RHACS Central backend expects HTTPS connections"
    
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p '{
        "spec": {
            "tls": {
                "termination": "reencrypt",
                "insecureEdgeTerminationPolicy": "Redirect"
            }
        }
    }'
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured successfully with reencrypt termination"
        log "  Termination: reencrypt (TLS terminates at router, re-encrypts to backend)"
        log "  Insecure policy: Redirect (HTTP -> HTTPS)"
        log "  Certificate: Default router certificate"
        log ""
        log "Note: No restart of Central is required - route changes are applied automatically"
        log ""
        warning "⚠️  IMPORTANT: The default router certificate is likely self-signed"
        warning "   Browsers will show a certificate warning (NET::ERR_CERT_AUTHORITY_INVALID)"
        warning "   This is normal for development/testing environments"
        log ""
        log "To resolve the certificate warning, you have these options:"
        log "  1. Accept the certificate in your browser (click 'Advanced' -> 'Proceed')"
        log "  2. Use a custom trusted certificate (run with --custom-cert option)"
        log "  3. Configure Let's Encrypt certificate using cert-manager (automatic)"
        log ""
        log "For production, use option 2 or 3 with a trusted certificate authority."
    else
        error "Failed to configure TLS"
        return 1
    fi
}

# Function to configure TLS using Operator-based method (custom certificate)
# This follows the required steps:
# 1. Create secret with tls-cert.pem and tls-key.pem
# 2. Configure Central CR with spec.central.defaultTLSSecret
# 3. Restart Central container
configure_operator_tls_custom() {
    local cert_file="$1"
    local key_file="$2"
    
    if [ -z "$cert_file" ] || [ -z "$key_file" ]; then
        error "Certificate and key files are required for custom TLS configuration"
        return 1
    fi
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        error "Certificate or key file not found"
        return 1
    fi
    
    log "Configuring TLS using Operator-based method with custom certificate..."
    log "Following Operator-based process:"
    log "  1. Create/update TLS secret 'central-default-tls-cert'"
    log "  2. Configure Central CR with spec.central.defaultTLSSecret"
    log "  3. Restart Central container"
    
    # Check if secret already exists (for update scenario)
    SECRET_EXISTS=false
    if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        SECRET_EXISTS=true
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
    
    log ""
    log "✓ TLS configured successfully using Operator-based method"
    log "  Secret: $SECRET_NAME"
    log "  Certificate: $cert_file"
    log "  Key: $key_file"
    log "  Central CR: $CENTRAL_CR_NAME"
    log "  Central restarted: Yes"
}

# Function to configure TLS with passthrough termination
configure_passthrough_tls() {
    log "Configuring TLS with passthrough termination..."
    
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p '{
        "spec": {
            "tls": {
                "termination": "passthrough"
            }
        }
    }'
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured with passthrough termination"
        log "  Termination: passthrough (TLS terminates at backend)"
    else
        error "Failed to configure passthrough TLS"
        return 1
    fi
}

# Function to configure TLS with reencrypt termination
configure_reencrypt_tls() {
    local dest_ca_file="$1"
    
    log "Configuring TLS with reencrypt termination..."
    
    if [ -n "$dest_ca_file" ] && [ -f "$dest_ca_file" ]; then
        oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p "{
            \"spec\": {
                \"tls\": {
                    \"termination\": \"reencrypt\",
                    \"insecureEdgeTerminationPolicy\": \"Redirect\",
                    \"destinationCACertificate\": \"$(cat $dest_ca_file | base64 -w 0)\"
                }
            }
        }"
    else
        oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p '{
            "spec": {
                "tls": {
                    "termination": "reencrypt",
                    "insecureEdgeTerminationPolicy": "Redirect"
                }
            }
        }'
    fi
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured with reencrypt termination"
        log "  Termination: reencrypt (TLS terminates at router and re-encrypts to backend)"
    else
        error "Failed to configure reencrypt TLS"
        return 1
    fi
}

# Main configuration logic
# For Operator-based installations, use --custom-cert to follow the required process
log ""

# Determine which TLS configuration method to use
if [ "$1" = "--custom-cert" ] && [ -n "$2" ] && [ -n "$3" ]; then
    # Operator-based method (required process)
    configure_operator_tls_custom "$2" "$3"
elif [ "$1" = "--passthrough" ]; then
    warning "Passthrough mode is for Route-based TLS, not Operator-based installations"
    configure_passthrough_tls
elif [ "$1" = "--reencrypt" ]; then
    warning "Reencrypt mode is for Route-based TLS, not Operator-based installations"
    configure_reencrypt_tls "$2"
elif [ "$1" = "--default-cert" ]; then
    warning "Default cert mode is for Route-based TLS, not Operator-based installations"
    configure_edge_tls_default
elif [ "$1" = "--reencrypt-default" ]; then
    warning "Reencrypt-default mode is for Route-based TLS, not Operator-based installations"
    configure_edge_tls_default
elif [ "$1" = "--cert-manager" ]; then
    # Use cert-manager to automatically obtain a certificate
    if [ "$CERT_MANAGER_AVAILABLE" != "true" ] || [ -z "$CLUSTER_ISSUER" ]; then
        error "cert-manager is not available or no ClusterIssuer found"
        error "Install cert-manager and configure a ClusterIssuer, or use --custom-cert option"
        exit 1
    fi
    
    # Get route hostname
    ROUTE_HOST=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -z "$ROUTE_HOST" ]; then
        error "Could not determine route hostname"
        exit 1
    fi
    
    log "Using cert-manager to obtain certificate for: $ROUTE_HOST"
    log "ClusterIssuer: $CLUSTER_ISSUER"
    
    # Create Certificate resource
    CERT_NAME="rhacs-central-tls-cert-manager"
    CERT_SECRET_NAME="rhacs-central-tls-cert-manager"
    
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
    
    # Wait for certificate to be ready
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
    
    # Use the custom cert function to configure TLS
    configure_operator_tls_custom "$TEMP_CERT" "$TEMP_KEY"
    CONFIGURE_EXIT_CODE=$?
    
    # Clean up temp files
    rm -f "$TEMP_CERT" "$TEMP_KEY"
    
    if [ $CONFIGURE_EXIT_CODE -ne 0 ]; then
        error "Failed to configure TLS with cert-manager certificate"
        exit 1
    fi
    
    log ""
    log "✓ TLS configured successfully using cert-manager"
    log "  Certificate: Automatically issued by $CLUSTER_ISSUER"
    log "  Valid for: $ROUTE_HOST"
    log "  Auto-renewal: Managed by cert-manager"
    
elif [ -z "$1" ]; then
    # No arguments provided - show usage
    log "========================================================="
    log "RHACS TLS Configuration Script (Operator-based)"
    log "========================================================="
    log ""
    log "Usage:"
    log "  $0 --custom-cert <cert-file> <key-file>"
    if [ "$CERT_MANAGER_AVAILABLE" = "true" ] && [ -n "$CLUSTER_ISSUER" ]; then
        log "  $0 --cert-manager"
    fi
    log ""
    log "This script follows the Operator-based process:"
    log "  1. Creates secret 'central-default-tls-cert' with tls-cert.pem and tls-key.pem"
    log "  2. Configures Central CR with spec.central.defaultTLSSecret"
    log "  3. Restarts Central container"
    log ""
    log "Options:"
    log "  --custom-cert <cert-file> <key-file>"
    log "    Use your own certificate and key files"
    log "    Example: $0 --custom-cert /path/to/cert.pem /path/to/key.pem"
    log ""
    if [ "$CERT_MANAGER_AVAILABLE" = "true" ] && [ -n "$CLUSTER_ISSUER" ]; then
        log "  --cert-manager"
        log "    Automatically obtain a trusted certificate using cert-manager"
        log "    Uses ClusterIssuer: $CLUSTER_ISSUER"
        log "    Example: $0 --cert-manager"
        log ""
    fi
    log "Note: If updating an existing certificate, the script will:"
    log "  - Delete the existing secret first"
    log "  - Create a new secret with the new certificate"
    log "  - Update the Central CR"
    log "  - Restart Central"
    log ""
    log "To fix NET::ERR_CERT_AUTHORITY_INVALID error:"
    log "  Use --cert-manager for automatic trusted certificate (recommended)"
    log "  Or use --custom-cert with a certificate from a trusted CA"
    log "========================================================="
    exit 0
else
    error "Unknown option: $1"
    error "Use --custom-cert <cert-file> <key-file> for Operator-based TLS configuration"
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

# Get route host for verification
if oc get route "$ROUTE_NAME" -n "$NAMESPACE" &>/dev/null; then
    CURRENT_HOST=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -n "$CURRENT_HOST" ]; then
        log ""
        log "========================================================="
        log "RHACS TLS Configuration Complete (Operator-based)"
        log "========================================================="
        log "HTTPS URL: https://$CURRENT_HOST"
        log "Secret: $SECRET_NAME"
        log "Central CR: $CENTRAL_CR_NAME"
        log ""
        log "The certificate has been configured using the Operator-based method:"
        log "  ✓ Secret created with tls-cert.pem and tls-key.pem"
        log "  ✓ Central CR configured with spec.central.defaultTLSSecret"
        log "  ✓ Central container restarted"
        log ""
        log "Note: It may take a few moments for the new certificate to be active."
        log "========================================================="
    fi
fi

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS configuration completed successfully!"
fi

