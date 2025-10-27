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

# Create Certificate resource via cert-manager
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
log "CONFIGURING OPENSHIFT ROUTE WITH TLS"
log "========================================================="

# Extract certificate and key for route configuration
log "Extracting certificate and key from rhacs-central-tls-secret..."
ROUTE_CERT=$(oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.crt}')
ROUTE_KEY=$(oc get secret rhacs-central-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.key}')

if [ -z "$ROUTE_CERT" ] || [ -z "$ROUTE_KEY" ]; then
    error "Failed to extract certificate or key from secret"
fi

# Decode certificate and key
DECODED_CERT=$(echo "$ROUTE_CERT" | base64 -d)
DECODED_KEY=$(echo "$ROUTE_KEY" | base64 -d)

# Create temporary files with decoded cert and key
CERT_FILE=$(mktemp)
KEY_FILE=$(mktemp)
echo "$DECODED_CERT" > "$CERT_FILE"
echo "$DECODED_KEY" > "$KEY_FILE"

# Delete existing route if it exists
log "Preparing route for reconfiguration..."
oc delete route central -n $NAMESPACE --ignore-not-found=true
sleep 2

# Create route using oc apply with re-encrypt termination
log "Creating route with re-encrypt TLS termination..."
log "  (RHACS requires HTTPS on backend port 8443)"
cat <<YAMEOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: central
  namespace: $NAMESPACE
spec:
  host: $CENTRAL_DNS
  port:
    targetPort: https
  to:
    kind: Service
    name: central
    weight: 100
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(sed 's/^/      /' "$CERT_FILE")
    key: |
$(sed 's/^/      /' "$KEY_FILE")
    destinationCACertificate: |
$(sed 's/^/      /' "$CERT_FILE")
YAMEOF

if [ $? -eq 0 ]; then
    success "Route created with re-encrypt TLS termination"
else
    error "Failed to create route"
fi

# Clean up temp files
rm -f "$CERT_FILE" "$KEY_FILE"

# Wait for route to be established
log "Waiting for route to be established..."
sleep 10

# Verify route configuration
log "Verifying route TLS configuration..."
ROUTE_TLS=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.tls.termination}' 2>/dev/null)
if [ "$ROUTE_TLS" = "reencrypt" ]; then
    success "Route TLS termination verified: reencrypt"
else
    warning "Route TLS termination: $ROUTE_TLS (expected: reencrypt)"
fi

REDIRECT_POLICY=$(oc get route central -n $NAMESPACE -o jsonpath='{.spec.tls.insecureEdgeTerminationPolicy}' 2>/dev/null)
if [ "$REDIRECT_POLICY" = "Redirect" ]; then
    success "HTTP->HTTPS redirect policy verified"
else
    warning "HTTP->HTTPS redirect policy: $REDIRECT_POLICY"
fi

success "SSL Certificate Setup completed!"
log "========================================================="

# Display RHACS access information
log ""
log "========================================================="
log "RHACS ACCESS INFORMATION"
log "========================================================="

log "RHACS UI:     https://$CENTRAL_DNS"
log "---------------------------------------------------------"

# Get admin password
ADMIN_PASSWORD=$(oc get secret central-htpasswd -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "$ADMIN_PASSWORD" ]; then
    warning "Could not retrieve admin password"
else
    log "User:         admin"
    log "Password:     $ADMIN_PASSWORD"
fi

log "---------------------------------------------------------"

