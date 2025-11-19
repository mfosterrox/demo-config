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

# Try to get ClusterIssuers directly - this is the most reliable check
CLUSTER_ISSUERS=$(oc get clusterissuer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -n "$CLUSTER_ISSUERS" ]; then
    CERT_MANAGER_AVAILABLE=true
    log "✓ cert-manager is available (found ClusterIssuers)"
    
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
    # Fallback: Check if cert-manager API resource exists
    if oc api-resources 2>/dev/null | grep -qiE "clusterissuer|cert-manager"; then
        CERT_MANAGER_AVAILABLE=true
        warning "cert-manager API is available but no ClusterIssuer found"
        error "Please configure a ClusterIssuer (e.g., Let's Encrypt, ZeroSSL) before running this script"
        error "You can create a ClusterIssuer using: oc create -f <clusterissuer-yaml>"
        exit 1
    else
        error "cert-manager is not installed or API is not available"
        error "This script requires cert-manager to automatically obtain trusted certificates"
        error "Please install cert-manager and configure a ClusterIssuer"
        exit 1
    fi
fi

# Get route hostname
ROUTE_HOST=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -z "$ROUTE_HOST" ]; then
    error "Could not determine route hostname"
    exit 1
fi

log "Route hostname: $ROUTE_HOST"

# Check if a valid certificate is already configured
log "Checking if valid certificate is already configured..."
CURRENT_TLS_SECRET=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret.name}' 2>/dev/null || echo "")
CURRENT_TLS_SECRET_ALT=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.defaultTLSSecret}' 2>/dev/null || echo "")

# Use whichever format is set
if [ -n "$CURRENT_TLS_SECRET" ] && [ "$CURRENT_TLS_SECRET" != "null" ]; then
    TLS_SECRET_TO_CHECK="$CURRENT_TLS_SECRET"
elif [ -n "$CURRENT_TLS_SECRET_ALT" ] && [ "$CURRENT_TLS_SECRET_ALT" != "null" ]; then
    TLS_SECRET_TO_CHECK="$CURRENT_TLS_SECRET_ALT"
else
    TLS_SECRET_TO_CHECK=""
fi

if [ -n "$TLS_SECRET_TO_CHECK" ]; then
    log "Found configured TLS secret: $TLS_SECRET_TO_CHECK"
    
    # Check if secret exists
    if oc get secret "$TLS_SECRET_TO_CHECK" -n "$NAMESPACE" &>/dev/null; then
        log "✓ TLS secret exists"
        
        # Check if secret has required keys
        SECRET_KEYS=$(oc get secret "$TLS_SECRET_TO_CHECK" -n "$NAMESPACE" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "")
        HAS_CERT=false
        HAS_KEY=false
        
        if echo "$SECRET_KEYS" | grep -qE "tls-cert\.pem|tls\.crt"; then
            HAS_CERT=true
        fi
        if echo "$SECRET_KEYS" | grep -qE "tls-key\.pem|tls\.key"; then
            HAS_KEY=true
        fi
        
        if [ "$HAS_CERT" = "true" ] && [ "$HAS_KEY" = "true" ]; then
            log "✓ Secret has required certificate and key"
            
            # Try to check certificate validity (if openssl is available)
            CERT_KEY_NAME=$(echo "$SECRET_KEYS" | grep -E "tls-cert\.pem|tls\.crt" | head -1)
            CERT_DATA=$(oc get secret "$TLS_SECRET_TO_CHECK" -n "$NAMESPACE" -o jsonpath="{.data.$CERT_KEY_NAME}" 2>/dev/null | base64 -d 2>/dev/null || echo "")
            
            if [ -n "$CERT_DATA" ] && command -v openssl &>/dev/null; then
                # Check certificate issuer to determine if it's from a trusted CA
                CERT_ISSUER=$(echo "$CERT_DATA" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//' || echo "")
                CERT_SUBJECT=$(echo "$CERT_DATA" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//' || echo "")
                
                # Check if certificate is self-signed (issuer matches subject) or from StackRox internal CA
                IS_SELF_SIGNED=false
                IS_STACKROX_CA=false
                
                if [ -n "$CERT_ISSUER" ] && [ -n "$CERT_SUBJECT" ]; then
                    # Check if issuer contains subject (self-signed)
                    if echo "$CERT_ISSUER" | grep -qiE "StackRox|Stackrox|stackrox"; then
                        IS_STACKROX_CA=true
                    fi
                    # Check if issuer matches subject (self-signed)
                    if [ "$CERT_ISSUER" = "$CERT_SUBJECT" ]; then
                        IS_SELF_SIGNED=true
                    fi
                fi
                
                # If it's a self-signed or StackRox CA certificate, we need to reconfigure
                if [ "$IS_SELF_SIGNED" = "true" ] || [ "$IS_STACKROX_CA" = "true" ]; then
                    warning "Certificate is self-signed or from StackRox internal CA (not trusted by browsers)"
                    warning "Issuer: $CERT_ISSUER"
                    warning "This will cause NET::ERR_CERT_AUTHORITY_INVALID errors"
                    log "Reconfiguring with cert-manager trusted certificate..."
                else
                    # Check certificate expiration only if it's from a trusted CA
                    CERT_EXPIRY=$(echo "$CERT_DATA" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
                    if [ -n "$CERT_EXPIRY" ]; then
                        # Try Linux date format first, then macOS format
                        CERT_EXPIRY_EPOCH=$(date -d "$CERT_EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$CERT_EXPIRY" +%s 2>/dev/null || echo "")
                        CURRENT_EPOCH=$(date +%s)
                        
                        if [ -n "$CERT_EXPIRY_EPOCH" ] && [ "$CERT_EXPIRY_EPOCH" -gt "$CURRENT_EPOCH" ]; then
                            DAYS_UNTIL_EXPIRY=$(( ($CERT_EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
                            log "✓ Certificate is from trusted CA and expires in $DAYS_UNTIL_EXPIRY days ($CERT_EXPIRY)"
                            log "Issuer: $CERT_ISSUER"
                            log ""
                            log "========================================================="
                            log "Valid trusted certificate already configured"
                            log "========================================================="
                            log "TLS Secret: $TLS_SECRET_TO_CHECK"
                            log "Certificate expires: $CERT_EXPIRY ($DAYS_UNTIL_EXPIRY days remaining)"
                            log "Issuer: $CERT_ISSUER"
                            log ""
                            log "No action needed - certificate is already configured and trusted."
                            log "To force reconfiguration, delete the secret first:"
                            log "  oc delete secret $TLS_SECRET_TO_CHECK -n $NAMESPACE"
                            log "========================================================="
                            exit 0
                        elif [ -n "$CERT_EXPIRY_EPOCH" ]; then
                            warning "Certificate has expired ($CERT_EXPIRY) - will reconfigure"
                        else
                            # If we can't parse the date but certificate exists, check if it's not expired using openssl directly
                            CERT_NOT_AFTER=$(echo "$CERT_DATA" | openssl x509 -noout -checkend 0 2>/dev/null && echo "valid" || echo "expired")
                            if [ "$CERT_NOT_AFTER" = "valid" ]; then
                                log "✓ Certificate is from trusted CA and valid (expires: $CERT_EXPIRY)"
                                log "Issuer: $CERT_ISSUER"
                                log ""
                                log "========================================================="
                                log "Valid trusted certificate already configured"
                                log "========================================================="
                                log "TLS Secret: $TLS_SECRET_TO_CHECK"
                                log "Certificate expires: $CERT_EXPIRY"
                                log "Issuer: $CERT_ISSUER"
                                log ""
                                log "No action needed - certificate is already configured and trusted."
                                log "To force reconfiguration, delete the secret first:"
                                log "  oc delete secret $TLS_SECRET_TO_CHECK -n $NAMESPACE"
                                log "========================================================="
                                exit 0
                            else
                                warning "Certificate has expired ($CERT_EXPIRY) - will reconfigure"
                            fi
                        fi
                    else
                        log "Certificate exists but could not parse expiration - continuing with configuration"
                    fi
                fi
            else
                log "Certificate exists but openssl not available - continuing with configuration"
            fi
        else
            warning "Secret exists but missing required keys - will reconfigure"
        fi
    else
        warning "Configured secret '$TLS_SECRET_TO_CHECK' not found - will create new certificate"
    fi
else
    log "No TLS certificate configured - proceeding with certificate setup"
fi

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
    
    # Always delete existing secret to ensure clean rotation
    if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "Deleting existing secret '$SECRET_NAME' for certificate rotation..."
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
    
    # Wait for Operator to reconcile the CR change
    log "Waiting for Operator to reconcile Central CR changes..."
    log "This may take up to 2 minutes for the Operator to process..."
    
    # Wait and verify Operator has processed the change
    for i in {1..24}; do
        sleep 5
        # Check if Central deployment has been updated by Operator (check for new generation or annotations)
        CR_GENERATION=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "")
        CR_OBSERVED_GEN=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
        
        if [ -n "$CR_GENERATION" ] && [ -n "$CR_OBSERVED_GEN" ] && [ "$CR_GENERATION" = "$CR_OBSERVED_GEN" ]; then
            log "✓ Operator has reconciled Central CR changes"
            break
        fi
        
        if [ $((i % 6)) -eq 0 ]; then
            log "Still waiting for Operator reconciliation... ($((i * 5))s elapsed)"
        fi
        
        if [ $i -eq 24 ]; then
            warning "Operator reconciliation timeout - continuing anyway"
            warning "Central may need more time to pick up the certificate"
        fi
    done
    
    # Additional wait to ensure Operator has updated the deployment
    sleep 10
    
    # Restart Central container
    log "Restarting Central deployment to apply certificate changes..."
    CENTRAL_DEPLOYMENT="central"
    
    if ! oc get deployment "$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
        error "Central deployment not found"
        return 1
    fi
    
    # Get current pod name before restart
    OLD_POD=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    # For Operator-managed deployments, delete the pod directly (Operator will recreate it with new config)
    # This is more reliable than rollout restart for Operator-managed resources
    if [ -n "$OLD_POD" ]; then
        log "Deleting Central pod to trigger restart with new certificate..."
        oc delete pod "$OLD_POD" -n "$NAMESPACE" --grace-period=30 2>/dev/null || {
            warning "Could not delete pod gracefully, forcing deletion..."
            oc delete pod "$OLD_POD" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        }
    else
        # Fallback: Try rollout restart
        if oc rollout restart deployment/"$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" 2>/dev/null; then
            log "Triggered deployment rollout restart..."
        else
            # Last resort: Delete all Central pods
            log "Deleting all Central pods..."
            oc delete pod -n "$NAMESPACE" -l app=central --grace-period=30 2>/dev/null || true
        fi
    fi
    
    log "Waiting for Central to restart..."
    sleep 10  # Give it a moment to start restarting
    
    # Wait for new pod to be ready
    RESTART_SUCCESS=false
    for i in {1..120}; do
        NEW_POD=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        POD_STATUS=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        POD_READY=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        
        # Check if pod restarted (new pod name or pod is restarting)
        if [ -n "$NEW_POD" ] && [ "$NEW_POD" != "$OLD_POD" ]; then
            if [ "$POD_READY" = "True" ]; then
                log "✓ Central restarted successfully (new pod: $NEW_POD)"
                RESTART_SUCCESS=true
                break
            fi
        elif [ "$POD_STATUS" = "Running" ] && [ "$POD_READY" = "True" ]; then
            # If pod didn't change name but is ready, check if it's actually a new pod by checking restart count
            RESTART_COUNT=$(oc get pod "$NEW_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
            if [ -n "$OLD_POD" ] && [ "$NEW_POD" = "$OLD_POD" ]; then
                # Same pod - force delete it
                log "Pod did not restart, forcing deletion..."
                oc delete pod "$OLD_POD" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
                sleep 5
                continue
            else
                log "✓ Central is running and ready"
                RESTART_SUCCESS=true
                break
            fi
        fi
        
        if [ $((i % 12)) -eq 0 ]; then
            log "Still waiting for Central restart... ($((i * 5))s elapsed, status: $POD_STATUS, pod: $NEW_POD)"
        fi
        
        sleep 5
        
        if [ $i -eq 120 ]; then
            warning "Central restart did not complete within timeout"
            warning "Current pod status: $POD_STATUS, Ready: $POD_READY"
            warning "Forcing pod deletion..."
            oc delete pod -n "$NAMESPACE" -l app=central --force --grace-period=0 2>/dev/null || true
            warning "Waiting for new pod..."
            sleep 30
        fi
    done
    
    if [ "$RESTART_SUCCESS" = "false" ]; then
        warning "Central restart verification incomplete - certificate may not be active yet"
        warning "Please verify manually: oc get pods -n $NAMESPACE -l app=central"
    fi
    
    # Wait additional time for Central to fully initialize with new certificate
    log "Waiting for Central to initialize with new certificate..."
    log "This ensures the certificate is loaded and active..."
    
    # Wait longer and verify the secret is mounted
    for i in {1..12}; do
        sleep 5
        # Check if the secret is referenced in the pod
        POD_NAME=$(oc get pod -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$POD_NAME" ]; then
            # Check if secret is mounted in the pod
            MOUNTED_SECRETS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.volumes[*].secret.secretName}' 2>/dev/null || echo "")
            if echo "$MOUNTED_SECRETS" | grep -q "$SECRET_NAME"; then
                log "✓ Certificate secret is mounted in Central pod"
                break
            fi
        fi
        
        if [ $i -eq 12 ]; then
            warning "Could not verify secret mount - certificate may still be loading"
        fi
    done
    
    # Final wait for Central to fully start serving the certificate
    sleep 10
}

# Main configuration logic - Use cert-manager to obtain certificate
log ""
log "Using cert-manager to obtain certificate for: $ROUTE_HOST"
log "ClusterIssuer: $CLUSTER_ISSUER"

# Create Certificate resource
CERT_NAME="rhacs-central-tls-cert-manager"
CERT_SECRET_NAME="rhacs-central-tls-cert-manager"

# Always delete existing Certificate resource and secret to ensure clean rotation
if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting existing Certificate resource '$CERT_NAME' for certificate rotation..."
    oc delete certificate "$CERT_NAME" -n "$NAMESPACE" 2>/dev/null || true
    log "✓ Existing Certificate resource deleted"
fi

if oc get secret "$CERT_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting existing cert-manager secret '$CERT_SECRET_NAME' for certificate rotation..."
    oc delete secret "$CERT_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || true
    log "✓ Existing cert-manager secret deleted"
fi

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
log ""
log "Verifying certificate is active..."
sleep 5

# Verify the certificate being served matches what we configured
if command -v openssl &>/dev/null; then
    SERVED_CERT_ISSUER=$(echo | openssl s_client -connect "$ROUTE_HOST:443" -servername "$ROUTE_HOST" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//' || echo "")
    SECRET_CERT_ISSUER=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls-cert\.pem}' 2>/dev/null | base64 -d | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//' || echo "")
    
    if [ -n "$SERVED_CERT_ISSUER" ] && [ -n "$SECRET_CERT_ISSUER" ]; then
        if echo "$SERVED_CERT_ISSUER" | grep -qiE "ZeroSSL|Let's Encrypt|Let''s Encrypt"; then
            log "✓ Certificate verification: Central is serving trusted certificate"
            log "  Served certificate issuer: $SERVED_CERT_ISSUER"
        elif echo "$SERVED_CERT_ISSUER" | grep -qiE "StackRox|Stackrox|stackrox"; then
            warning "⚠️  Certificate verification: Central is still serving StackRox certificate"
            warning "  Served certificate issuer: $SERVED_CERT_ISSUER"
            warning "  Expected issuer: $SECRET_CERT_ISSUER"
            warning ""
            warning "Central may need additional time to pick up the certificate."
            warning "Try manually restarting Central: oc delete pod -n $NAMESPACE -l app=central"
            warning "Then wait 2-3 minutes and refresh your browser."
        else
            log "Certificate issuer: $SERVED_CERT_ISSUER"
        fi
    else
        warning "Could not verify certificate issuer - may need to wait longer"
    fi
fi

log "========================================================="

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS configuration completed successfully!"
fi
