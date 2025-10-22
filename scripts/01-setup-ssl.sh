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
NAMESPACE="rhacs-operator"

# Check if OpenShift CLI is available
if ! command -v oc &>/dev/null; then
    error "OpenShift CLI (oc) is not installed"
fi

# Check if logged in to OpenShift
if ! oc whoami &>/dev/null; then
    error "Not logged in to OpenShift. Please login first using 'oc login'"
fi

# Check if cert-manager is installed
log "Checking if cert-manager is installed..."
if ! oc get crd certificates.cert-manager.io &>/dev/null; then
    warning "cert-manager CRDs not found. Please install cert-manager first."
    warning "Skipping SSL certificate setup..."
    exit 0
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

# Wait for certificate to be ready
log "Waiting for certificate to be issued..."
oc wait --for=condition=Ready certificate/rhacs-central-tls -n $NAMESPACE --timeout=300s

if [ $? -eq 0 ]; then
    success "Certificate issued successfully"
    
    # Verify the secret was created
    if oc get secret rhacs-central-tls-secret -n $NAMESPACE &>/dev/null; then
        success "TLS secret 'rhacs-central-tls-secret' created successfully"
        log "Certificate details:"
        oc describe certificate rhacs-central-tls -n $NAMESPACE | grep -A 5 "Status:"
    else
        warning "Certificate created but secret not found yet"
    fi
else
    warning "Certificate creation timed out or failed"
    log "Check certificate status with: oc describe certificate rhacs-central-tls -n $NAMESPACE"
fi

success "SSL Certificate Setup completed!"
log "========================================================="

