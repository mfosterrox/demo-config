#!/bin/bash
# RHACS TLS/HTTPS Configuration Script
# Gets certificate from cert-manager and updates central-tls secret
# HARDCODED VERSION FOR DEBUGGING - Run line by line

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

# Verify namespace exists
if ! oc get ns "tssc-acs" &>/dev/null; then
    error "Namespace 'tssc-acs' not found"
    exit 1
fi

log "Using namespace: tssc-acs"

# Check for cert-manager and ClusterIssuer
log "Checking for cert-manager..."

# Try to get ClusterIssuers directly - this is the most reliable check
    CLUSTER_ISSUERS=$(oc get clusterissuer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$CLUSTER_ISSUERS" ]; then
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
ROUTE_HOST=$(oc get route "central" -n "tssc-acs" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -z "$ROUTE_HOST" ]; then
    error "Could not determine route hostname"
    exit 1
fi

log "Route hostname: $ROUTE_HOST"

# Main execution - Get certificate from cert-manager and update central-tls secret
log ""
log "========================================================="
log "Update central-tls Secret with cert-manager Certificate"
log "========================================================="
log ""
log "Using cert-manager to obtain certificate for: $ROUTE_HOST"
log "ClusterIssuer: $CLUSTER_ISSUER"
log ""

# Create Certificate resource
CERT_NAME="rhacs-central-tls-cert-manager"
CERT_SECRET_NAME="rhacs-central-tls-cert-manager"

# Always delete existing Certificate resource and secret to ensure clean rotation
if oc get certificate "$CERT_NAME" -n "tssc-acs" &>/dev/null; then
    log "Deleting existing Certificate resource '$CERT_NAME'..."
    oc delete certificate "$CERT_NAME" -n "tssc-acs" 2>/dev/null || true
    log "✓ Existing Certificate resource deleted"
fi

if oc get secret "$CERT_SECRET_NAME" -n "tssc-acs" &>/dev/null; then
    log "Deleting existing cert-manager secret '$CERT_SECRET_NAME'..."
    oc delete secret "$CERT_SECRET_NAME" -n "tssc-acs" 2>/dev/null || true
    log "✓ Existing cert-manager secret deleted"
fi

log "Creating Certificate resource to obtain certificate from cert-manager..."
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: tssc-acs
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
    CERT_STATUS=$(oc get certificate "$CERT_NAME" -n "tssc-acs" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_STATUS" = "True" ]; then
        log "✓ Certificate issued successfully"
        break
    fi
    if [ $((i % 12)) -eq 0 ]; then
        log "Still waiting for certificate... ($((i * 5))s elapsed)"
    fi
    if [ $i -eq 120 ]; then
        error "Certificate did not become ready within 10 minutes"
        error "Check certificate status: oc get certificate $CERT_NAME -n tssc-acs"
        exit 1
    fi
done

# Wait for secret to be created
log "Waiting for certificate secret to be created..."
for i in {1..60}; do
    if oc get secret "$CERT_SECRET_NAME" -n "tssc-acs" &>/dev/null; then
        log "✓ Certificate secret created"
        break
    fi
    sleep 2
    if [ $i -eq 60 ]; then
        error "Secret not created within timeout"
        exit 1
    fi
done

# Extract certificate and key from cert-manager secret
log "Extracting certificate and key from cert-manager secret..."
CERT_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "tssc-acs" -o jsonpath='{.data.tls\.crt}' | base64 -d)
KEY_DATA=$(oc get secret "$CERT_SECRET_NAME" -n "tssc-acs" -o jsonpath='{.data.tls\.key}' | base64 -d)

if [ -z "$CERT_DATA" ] || [ -z "$KEY_DATA" ]; then
    error "Failed to extract certificate or key from cert-manager secret"
    exit 1
fi

# Create temporary files
TEMP_CERT=$(mktemp)
TEMP_KEY=$(mktemp)
echo "$CERT_DATA" > "$TEMP_CERT"
echo "$KEY_DATA" > "$TEMP_KEY"

log "✓ Certificate and key extracted"

# Patch existing central-tls secret or create if it doesn't exist
if oc get secret "central-tls" -n "tssc-acs" &>/dev/null; then
    log "Patching existing 'central-tls' secret with new certificate from cert-manager..."
    oc -n "tssc-acs" create secret tls "central-tls" \
        --cert="$TEMP_CERT" \
        --key="$TEMP_KEY" \
        --dry-run=client -o yaml | oc apply -f -
    
    if [ $? -ne 0 ]; then
        error "Failed to patch central-tls secret"
        rm -f "$TEMP_CERT" "$TEMP_KEY"
        exit 1
    fi
    log "✓ Secret 'central-tls' patched successfully"
else
log "Creating 'central-tls' secret with certificate from cert-manager..."
oc -n "tssc-acs" create secret tls "central-tls" \
    --cert="$TEMP_CERT" \
    --key="$TEMP_KEY"

if [ $? -ne 0 ]; then
    error "Failed to create central-tls secret"
    rm -f "$TEMP_CERT" "$TEMP_KEY"
    exit 1
fi
log "✓ Secret 'central-tls' created successfully"
fi

# Clean up temp files
rm -f "$TEMP_CERT" "$TEMP_KEY"

# Configure Central CR to use the central-tls secret
log "Configuring Central CR to use 'central-tls' secret..."
log "Patching spec.central.defaultTLSSecret..."

# Try patching as a string first (most common format)
PATCH_SUCCESS=false
if oc patch central "stackrox-central-services" -n "tssc-acs" --type='merge' -p "{
    \"spec\": {
        \"central\": {
            \"defaultTLSSecret\": \"central-tls\"
        }
    }
}" 2>/dev/null; then
    PATCH_SUCCESS=true
else
    # If string format fails, try object format
    log "Trying object format for defaultTLSSecret..."
    if oc patch central "stackrox-central-services" -n "tssc-acs" --type='merge' -p "{
        \"spec\": {
            \"central\": {
                \"defaultTLSSecret\": {
                    \"name\": \"central-tls\"
                }
            }
        }
    }" 2>/dev/null; then
        PATCH_SUCCESS=true
    fi
fi

if [ "$PATCH_SUCCESS" != "true" ]; then
    error "Failed to patch Central CR with defaultTLSSecret"
    exit 1
fi

log "✓ Central CR configured with defaultTLSSecret: central-tls"

# Restart Central to pick up the new certificate
log "Restarting Central to apply certificate changes..."

OLD_POD=$(oc get pod -n "tssc-acs" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$OLD_POD" ]; then
    log "Deleting Central pod to trigger restart..."
    oc delete pod "$OLD_POD" -n "tssc-acs" --grace-period=30 2>/dev/null || {
        warning "Could not delete pod gracefully, forcing deletion..."
        oc delete pod "$OLD_POD" -n "tssc-acs" --force --grace-period=0 2>/dev/null || true
    }
    
    log "Waiting for Central to restart..."
    sleep 10
    
    # Wait for new pod to be ready
    for i in {1..60}; do
        NEW_POD=$(oc get pod -n "tssc-acs" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        POD_STATUS=$(oc get pod -n "tssc-acs" -l app=central -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        POD_READY=$(oc get pod -n "tssc-acs" -l app=central -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        
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

# Regenerate API token after certificate change and restart
log ""
log "Regenerating API token after certificate change..."

# Wait a bit more for Central to be fully ready
log "Waiting for Central API to be ready..."
for i in {1..30}; do
    if curl -k -s --connect-timeout 5 --max-time 10 "https://$ROUTE_HOST" >/dev/null 2>&1; then
        log "✓ Central API is responding"
        break
    fi
    sleep 2
    if [ $i -eq 30 ]; then
        warning "Central API did not become ready within timeout, but continuing..."
    fi
done

# Get admin password from secret
ADMIN_PASSWORD=""
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "tssc-acs" -o jsonpath='{.data.password}' 2>/dev/null || true)
if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || true)
fi

# Get ROX_ENDPOINT from route
ROX_ENDPOINT_HOST=$(oc get route central -n "tssc-acs" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$ROX_ENDPOINT_HOST" ]; then
    warning "Could not get Central route host, skipping token regeneration"
else
    ROX_ENDPOINT="https://$ROX_ENDPOINT_HOST"
    
    if [ -n "$ADMIN_PASSWORD" ]; then
        log "Generating new API token..."
        TOKEN_NAME="demo-config-token-$(date +%s)"
        TOKEN_ROLE="Admin"
        
        set +e
        TOKEN_RESPONSE=$(curl -k -X POST \
          -u "admin:$ADMIN_PASSWORD" \
          -H "Content-Type: application/json" \
          --data "{\"name\":\"$TOKEN_NAME\",\"role\":\"$TOKEN_ROLE\"}" \
          "$ROX_ENDPOINT/v1/apitokens/generate" 2>&1)
        TOKEN_EXIT_CODE=$?
        set -e
        
        if [ $TOKEN_EXIT_CODE -eq 0 ] && [ -n "$TOKEN_RESPONSE" ]; then
            # Extract token from JSON response
            NEW_ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")
            
            if [ -n "$NEW_ROX_API_TOKEN" ] && [ "$NEW_ROX_API_TOKEN" != "null" ] && [ "$NEW_ROX_API_TOKEN" != "" ]; then
                log "✓ API token regenerated successfully"
                
                # Update ~/.bashrc with new token
                if [ -f ~/.bashrc ]; then
                    # Remove existing ROX_API_TOKEN entry if it exists
                    sed -i '' '/^export ROX_API_TOKEN=/d' ~/.bashrc 2>/dev/null || sed -i '/^export ROX_API_TOKEN=/d' ~/.bashrc 2>/dev/null || true
                    
                    # Add new token entry
                    echo "export ROX_API_TOKEN=\"$NEW_ROX_API_TOKEN\"" >> ~/.bashrc
                    log "✓ ROX_API_TOKEN updated in ~/.bashrc"
                    
                    # Also update ROX_ENDPOINT if needed
                    sed -i '' '/^export ROX_ENDPOINT=/d' ~/.bashrc 2>/dev/null || sed -i '/^export ROX_ENDPOINT=/d' ~/.bashrc 2>/dev/null || true
                    echo "export ROX_ENDPOINT=\"$ROX_ENDPOINT\"" >> ~/.bashrc
                    log "✓ ROX_ENDPOINT updated in ~/.bashrc"
                else
                    warning "~/.bashrc not found, cannot update API token"
                fi
            else
                warning "Failed to extract token from API response"
                log "Response preview: ${TOKEN_RESPONSE:0:200}..."
            fi
        else
            warning "Failed to regenerate API token (exit code: $TOKEN_EXIT_CODE)"
            if [ -n "$TOKEN_RESPONSE" ]; then
                log "Response preview: ${TOKEN_RESPONSE:0:200}..."
            fi
        fi
    else
        warning "Admin password not available, cannot regenerate API token"
        log "You may need to manually regenerate the API token or source ~/.bashrc"
    fi
fi

# Note: Certificate resource and secret are kept for auto-renewal by cert-manager
# If you want to clean them up, uncomment the following lines:
# log "Cleaning up Certificate resource and secret..."
# oc delete certificate "$CERT_NAME" -n "tssc-acs" 2>/dev/null || true
# oc delete secret "$CERT_SECRET_NAME" -n "tssc-acs" 2>/dev/null || true

# Verify secret was created
log ""
log "Verifying central-tls secret..."
if oc get secret "central-tls" -n "tssc-acs" &>/dev/null; then
    SECRET_KEYS=$(oc get secret "central-tls" -n "tssc-acs" -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || echo "")
    if echo "$SECRET_KEYS" | grep -q "tls.crt" && echo "$SECRET_KEYS" | grep -q "tls.key"; then
        log "✓ Secret 'central-tls' exists with correct keys (tls.crt, tls.key)"
    else
        warning "Secret exists but may not have correct keys"
    fi
else
    error "Secret 'central-tls' not found"
    exit 1
    fi
    
log ""
log "========================================================="
log "central-tls Secret Updated Successfully"
log "========================================================="
log "Secret: central-tls"
log "Certificate: Automatically issued by $CLUSTER_ISSUER"
log "Certificate for: $ROUTE_HOST"
log ""
log "The central-tls secret has been updated with a certificate from cert-manager."
log "Central CR has been configured to use the secret."
log "Central has been restarted to apply the changes."
log ""
log "Note: It may take 1-2 minutes for Central to fully pick up the new certificate."
log "If you still see the StackRox certificate, wait a bit longer and refresh your browser."
log ""
log "Note: API token has been regenerated and updated in ~/.bashrc."
log "If running scripts manually, source ~/.bashrc to use the new token:"
log "  source ~/.bashrc"
log "========================================================="

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ central-tls secret updated successfully!"
fi
