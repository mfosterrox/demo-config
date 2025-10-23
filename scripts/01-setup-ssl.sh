#!/bin/bash
set -eo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[SSL-SETUP]${NC} $1"
}

success() {
    echo -e "${GREEN}[SSL-SETUP]${NC} ✓ $1"
}

error() {
    echo -e "${RED}[SSL-SETUP]${NC} ✗ $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[SSL-SETUP]${NC} ⚠ $1"
}

log "Starting SSL Certificate Setup..."
log "========================================================="

# Define namespace
NAMESPACE="tssc-acs"

# Check if OpenShift CLI is available
if ! command -v oc &>/dev/null; then
    error "OpenShift CLI (oc) is not installed"
fi

# Check if logged in to OpenShift
if ! oc whoami &>/dev/null; then
    error "Not logged in to OpenShift. Please login first using 'oc login'"
fi

# Check if the ClusterIssuer exists
log "Checking for ClusterIssuer 'zerossl-production-ec2'..."
if ! oc get clusterissuer zerossl-production-ec2 &>/dev/null; then
    warning "ClusterIssuer 'zerossl-production-ec2' not found"
    warning "Please create the ClusterIssuer before running this script"
    warning "Skipping SSL certificate setup..."
    exit 0
fi

# Wait for RHACS Central route to be available
log "Waiting for RHACS Central route to be available..."
MAX_RETRIES=30
RETRY_COUNT=0
while ! oc get route central -n $NAMESPACE &>/dev/null; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        error "RHACS Central route not found in namespace $NAMESPACE after ${MAX_RETRIES} attempts"
    fi
    log "Waiting for Central route to be created... (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)"
    sleep 10
    RETRY_COUNT=$((RETRY_COUNT+1))
done

# Get the RHACS Central DNS name from the route
log "Retrieving RHACS Central DNS name..."
CENTRAL_DNS=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.host}')

if [ -z "$CENTRAL_DNS" ]; then
    error "Failed to retrieve RHACS Central DNS name from route"
fi

log "RHACS Central DNS: $CENTRAL_DNS"

# Create Certificate resource
log "Creating Certificate resource for RHACS Central..."
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rhacs-central-tls
  namespace: $NAMESPACE
spec:
  secretName: rhacs-central-tls-secret
  dnsNames:
    - $CENTRAL_DNS
  issuerRef:
    name: zerossl-production-ec2
    kind: ClusterIssuer
  duration: 2160h  # 90 days
  renewBefore: 360h  # Renew 15 days before expiry
EOF

if [ $? -eq 0 ]; then
    success "Certificate resource created successfully"
else
    error "Failed to create Certificate resource"
fi

# Wait for certificate to be ready (READY = True)
log "Waiting for certificate to be issued and reach READY status..."
log "This may take a few minutes while ZeroSSL processes the request..."

if ! oc wait --for=condition=Ready certificate/rhacs-central-tls -n $NAMESPACE --timeout=600s; then
    error "Certificate creation timed out or failed. Check certificate status with: oc describe certificate rhacs-central-tls -n $NAMESPACE"
fi

success "Certificate reached READY=True status"

# Wait for the TLS secret to be created with correct type
log "Waiting for TLS secret to be created..."
MAX_SECRET_WAIT=60
SECRET_WAIT_COUNT=0
while true; do
    if [ $SECRET_WAIT_COUNT -ge $MAX_SECRET_WAIT ]; then
        error "TLS secret not created after ${MAX_SECRET_WAIT} seconds"
    fi
    
    # Check if secret exists and has correct type
    if oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.type}' 2>/dev/null | grep -q "kubernetes.io/tls"; then
        # Verify it has data
        DATA_COUNT=$(oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.data}' 2>/dev/null | grep -o "tls.crt\|tls.key" | wc -l)
        if [ "$DATA_COUNT" -ge 2 ]; then
            success "TLS secret created successfully with certificate data"
            break
        fi
    fi
    
    log "Waiting for TLS secret... ($((SECRET_WAIT_COUNT+1))/${MAX_SECRET_WAIT}s)"
    sleep 1
    SECRET_WAIT_COUNT=$((SECRET_WAIT_COUNT+1))
done

# Display certificate details
log "Certificate details:"
oc describe certificate rhacs-central-tls -n $NAMESPACE | grep -A 10 "Status:"

log ""
log "========================================================="
log "VERIFICATION"
log "========================================================="

# Verify Certificate resource
log "Verifying Certificate resource in $NAMESPACE namespace..."
if oc get certificate rhacs-central-tls -n $NAMESPACE &>/dev/null; then
    success "Certificate CR exists in $NAMESPACE"
    oc get certificate rhacs-central-tls -n $NAMESPACE
else
    error "Certificate CR not found in $NAMESPACE"
fi

log ""

# Verify Secret resource
log "Verifying TLS Secret in $NAMESPACE namespace..."
if oc get secret rhacs-central-tls-secret -n $NAMESPACE &>/dev/null; then
    success "TLS Secret exists in $NAMESPACE"
    oc get secret rhacs-central-tls-secret -n $NAMESPACE
else
    error "TLS Secret not found in $NAMESPACE"
fi

log ""
log "========================================================="
log "PATCHING RHACS CENTRAL TLS CERTIFICATE"
log "========================================================="

# Wait for central-tls secret to exist
log "Waiting for central-tls secret to be created by RHACS..."
MAX_CENTRAL_WAIT=120
CENTRAL_WAIT_COUNT=0
while ! oc get secret central-tls -n $NAMESPACE &>/dev/null; do
    if [ $CENTRAL_WAIT_COUNT -ge $MAX_CENTRAL_WAIT ]; then
        error "central-tls secret not found in $NAMESPACE after ${MAX_CENTRAL_WAIT} seconds"
    fi
    log "Waiting for central-tls... ($((CENTRAL_WAIT_COUNT+1))/${MAX_CENTRAL_WAIT}s)"
    sleep 1
    CENTRAL_WAIT_COUNT=$((CENTRAL_WAIT_COUNT+1))
done

success "central-tls secret found"

# Extract the certificate and key from our new secret
log "Extracting certificate and key from rhacs-central-tls-secret..."
TLS_CERT=$(oc get secret rhacs-central-tls-secret -o jsonpath='{.data.tls\.crt}' -n $NAMESPACE)
TLS_KEY=$(oc get secret rhacs-central-tls-secret -o jsonpath='{.data.tls\.key}' -n $NAMESPACE)

if [ -z "$TLS_CERT" ] || [ -z "$TLS_KEY" ]; then
    error "Failed to extract certificate or key from rhacs-central-tls-secret"
fi

# Patch the central-tls secret
log "Patching central-tls with new TLS certificate..."
if oc patch secret central-tls -p "{\"data\":{\"tls.crt\":\"$TLS_CERT\",\"tls.key\":\"$TLS_KEY\"}}" -n $NAMESPACE; then
    success "Successfully patched central-tls with new certificate"
else
    error "Failed to patch central-tls secret"
fi

# Verify the patch
log "Verifying patched certificate..."
PATCHED_CERT=$(oc get secret central-tls -o jsonpath='{.data.tls\.crt}' -n $NAMESPACE)
if [ "$PATCHED_CERT" = "$TLS_CERT" ]; then
    success "Certificate patch verified successfully"
else
    warning "Certificate patch verification failed - certificates don't match"
fi

# Patch the route to use our certificate secret
log "Configuring route to use rhacs-central-tls-secret..."
if oc patch route central -n $NAMESPACE -p '{"spec":{"tls":{"termination":"edge","insecureEdgeTerminationPolicy":"Redirect"}}}'; then
    success "Route configured for edge TLS termination"
else
    error "Failed to configure route for TLS"
fi

# Extract certificate and key from our secret (base64 encoded)
ROUTE_CERT=$(oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.crt}')
ROUTE_KEY=$(oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.key}')

# Decode certificate and key
log "Decoding certificate and key..."
DECODED_CERT=$(echo "$ROUTE_CERT" | base64 -d)
DECODED_KEY=$(echo "$ROUTE_KEY" | base64 -d)

# Create a temporary YAML file for the route update
ROUTE_YAML=$(mktemp)
cat > "$ROUTE_YAML" << EOF
spec:
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(echo "$DECODED_CERT" | sed 's/^/      /')
    key: |
$(echo "$DECODED_KEY" | sed 's/^/      /')
EOF

# Apply the route update
log "Patching route with ZeroSSL certificate..."
if oc patch route central -n $NAMESPACE --patch-file="$ROUTE_YAML"; then
    success "Route patched with ZeroSSL certificate"
else
    error "Failed to patch route with certificate"
fi

# Clean up temporary file
rm -f "$ROUTE_YAML"

# Wait for route to be ready
log "Waiting for route to be ready..."
sleep 10

# Verify route configuration
log "Verifying route TLS configuration..."
ROUTE_TLS=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.tls.termination}')
if [ "$ROUTE_TLS" = "edge" ]; then
    success "Route TLS termination verified"
else
    warning "Route TLS termination not properly configured"
fi

# Verify certificate is embedded in route
log "Verifying certificate is embedded in route..."
ROUTE_CERT_CHECK=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.tls.certificate}')
if [ -n "$ROUTE_CERT_CHECK" ]; then
    success "Certificate found in route configuration"
else
    warning "Certificate not found in route - may be using default"
fi

# Test certificate validity
log "Testing certificate validity..."
if curl -s --connect-timeout 10 "https://$CENTRAL_DNS" >/dev/null; then
    success "HTTPS connection successful"
else
    warning "HTTPS connection test failed"
fi

success "SSL Certificate Setup completed!"
log "========================================================="

# Display RHACS access information
log ""
log "========================================================="
log "RHACS ACCESS INFORMATION"
log "========================================================="

# Get admin password
ADMIN_PASSWORD=$(oc get secret central-htpasswd -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$ADMIN_PASSWORD" ]; then
    warning "Could not retrieve admin password"
else
    log "RHACS UI:     https://$CENTRAL_DNS"
    log "---------------------------------------------------------"
    log "User:         admin"
    log "Password:     $ADMIN_PASSWORD"
    log "---------------------------------------------------------"
fi

