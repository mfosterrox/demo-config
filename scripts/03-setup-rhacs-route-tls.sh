#!/bin/bash
# RHACS Route TLS Setup Script
# Configures TLS for RHACS Central route using cert-manager Certificate resource

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-TLS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-TLS]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-TLS] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-TLS] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
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
if ! oc auth can-i create certificates --all-namespaces; then
    warning "May not have sufficient privileges to create Certificate resources. Current user: $(oc whoami)"
fi
log "✓ Privileges checked"

# Check if cert-manager is installed
log "Checking if cert-manager is installed..."
if ! oc get crd certificates.cert-manager.io &>/dev/null; then
    error "cert-manager is not installed. Please run script 07-install-cert-manager.sh first."
fi
log "✓ cert-manager CRD found"

log "Prerequisites validated successfully"

# Load NAMESPACE from ~/.bashrc (set by previous scripts)
NAMESPACE=$(load_from_bashrc "NAMESPACE")
if [ -z "$NAMESPACE" ]; then
    NAMESPACE="tssc-acs"
    log "NAMESPACE not found in ~/.bashrc, using default: $NAMESPACE"
else
    log "✓ Loaded NAMESPACE from ~/.bashrc: $NAMESPACE"
fi

# Verify RHACS namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Please ensure RHACS is installed first."
fi
log "✓ Namespace '$NAMESPACE' exists"

# Step 1: Get the Current Route Hostname
log ""
log "========================================================="
log "Step 1: Getting Current Route Hostname"
log "========================================================="

if ! oc get route central -n "$NAMESPACE" &>/dev/null; then
    error "Route 'central' not found in namespace '$NAMESPACE'. Please ensure RHACS is installed first."
fi

ROUTE_HOST=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')
if [ -z "$ROUTE_HOST" ]; then
    error "Failed to get Central route hostname. Check route exists: oc get route central -n $NAMESPACE"
fi

log "✓ Route hostname: $ROUTE_HOST"

# Step 2: Configure cert-manager issuer
log ""
log "========================================================="
log "Step 2: Configuring cert-manager Issuer"
log "========================================================="

# Prompt for issuer details (with defaults)
ISSUER_NAME="${CERT_MANAGER_ISSUER_NAME:-zerossl-production-ec2}"
ISSUER_KIND="${CERT_MANAGER_ISSUER_KIND:-ClusterIssuer}"

log "Using issuer configuration:"
log "  Name: $ISSUER_NAME"
log "  Kind: $ISSUER_KIND"
log ""
log "To use a different issuer, set environment variables:"
log "  export CERT_MANAGER_ISSUER_NAME=your-issuer-name"
log "  export CERT_MANAGER_ISSUER_KIND=ClusterIssuer  # or Issuer"

# Verify issuer exists
if [ "$ISSUER_KIND" = "ClusterIssuer" ]; then
    if ! oc get clusterissuer "$ISSUER_NAME" &>/dev/null; then
        warning "ClusterIssuer '$ISSUER_NAME' not found. The certificate may fail to issue."
        warning "Available ClusterIssuers:"
        oc get clusterissuer 2>/dev/null | head -10 || log "  None found"
    else
        log "✓ ClusterIssuer '$ISSUER_NAME' found"
    fi
else
    if ! oc get issuer "$ISSUER_NAME" -n "$NAMESPACE" &>/dev/null; then
        warning "Issuer '$ISSUER_NAME' not found in namespace '$NAMESPACE'. The certificate may fail to issue."
        warning "Available Issuers in namespace '$NAMESPACE':"
        oc get issuer -n "$NAMESPACE" 2>/dev/null | head -10 || log "  None found"
    else
        log "✓ Issuer '$ISSUER_NAME' found in namespace '$NAMESPACE'"
    fi
fi

# Step 3: Create the cert-manager Certificate Resource
log ""
log "========================================================="
log "Step 3: Creating Certificate Resource"
log "========================================================="

CERT_NAME="central-tls-cert"
SECRET_NAME="central-tls"

# Check if certificate already exists
CERT_NEEDS_UPDATE=false
CERT_NEEDS_WAIT=false

# Check if secret exists and contains self-signed certificate
if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Secret '$SECRET_NAME' already exists"
    SECRET_ISSUER=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -i "issuer" || echo "")
    if echo "$SECRET_ISSUER" | grep -qi "StackRox\|CN=.*CA"; then
        log "Secret contains self-signed certificate (issuer: ${SECRET_ISSUER:0:80}...)"
        log "cert-manager will replace this with the issued certificate when Ready"
    fi
fi

if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Certificate '$CERT_NAME' already exists"
    
    # Check if certificate is using the correct issuer
    CURRENT_ISSUER_NAME=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null || echo "")
    CURRENT_ISSUER_KIND=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.issuerRef.kind}' 2>/dev/null || echo "")
    
    if [ "$CURRENT_ISSUER_NAME" != "$ISSUER_NAME" ] || [ "$CURRENT_ISSUER_KIND" != "$ISSUER_KIND" ]; then
        log "Certificate is using issuer: $CURRENT_ISSUER_NAME ($CURRENT_ISSUER_KIND)"
        log "Expected issuer: $ISSUER_NAME ($ISSUER_KIND)"
        log "Updating certificate to use correct issuer..."
        CERT_NEEDS_UPDATE=true
    fi
    
    # Check certificate status
    CERT_READY=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CERT_READY" = "True" ] && [ "$CERT_NEEDS_UPDATE" = "false" ]; then
        log "✓ Certificate is Ready"
    else
        CERT_NEEDS_WAIT=true
        if [ "$CERT_READY" != "True" ]; then
            log "Certificate status: $CERT_READY"
            CERT_MESSAGE=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            if [ -n "$CERT_MESSAGE" ] && [ "$CERT_MESSAGE" != "null" ]; then
                log "  Message: $CERT_MESSAGE"
            fi
        fi
    fi
else
    CERT_NEEDS_WAIT=true
fi

# Create or update Certificate resource
if [ "$CERT_NEEDS_UPDATE" = "true" ]; then
    log "Updating Certificate resource '$CERT_NAME' with correct issuer..."
    
    # Create Certificate YAML
    CERT_YAML=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $NAMESPACE
spec:
  secretName: $SECRET_NAME
  issuerRef:
    name: $ISSUER_NAME
    kind: $ISSUER_KIND
  commonName: $ROUTE_HOST
  dnsNames:
  - $ROUTE_HOST
  duration: 2160h
  renewBefore: 360h
EOF
)
    
    # Apply Certificate
    echo "$CERT_YAML" | oc apply -f - || error "Failed to update Certificate resource"
    log "✓ Certificate resource updated"
elif [ ! -v CERT_NEEDS_UPDATE ] || [ "$CERT_NEEDS_UPDATE" = "false" ]; then
    if ! oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "Creating Certificate resource '$CERT_NAME'..."
        
        # Create Certificate YAML
        CERT_YAML=$(cat <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $NAMESPACE
spec:
  secretName: $SECRET_NAME
  issuerRef:
    name: $ISSUER_NAME
    kind: $ISSUER_KIND
  commonName: $ROUTE_HOST
  dnsNames:
  - $ROUTE_HOST
  duration: 2160h
  renewBefore: 360h
EOF
)
        
        # Apply Certificate
        echo "$CERT_YAML" | oc apply -f - || error "Failed to create Certificate resource"
        log "✓ Certificate resource created"
    fi
fi

# Step 4: Wait for the Certificate to Be Issued and Ready
log ""
log "========================================================="
log "Step 4: Waiting for Certificate to Be Ready"
log "========================================================="

# Only wait if certificate is not already Ready
CERT_READY_CHECK=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

if [ "$CERT_READY_CHECK" = "True" ]; then
    log "✓ Certificate is already Ready!"
else
    log "Waiting for certificate to be Ready (timeout: 15 minutes)..."
    log "This may take a few minutes depending on your issuer..."
    
    MAX_CERT_WAIT=900  # 15 minutes
    CERT_WAIT_COUNT=0
    CERT_READY_FINAL=false
    
    while [ $CERT_WAIT_COUNT -lt $MAX_CERT_WAIT ]; do
        CERT_READY_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [ "$CERT_READY_STATUS" = "True" ]; then
            CERT_READY_FINAL=true
            log "✓ Certificate is Ready!"
            break
        fi
        
        # Show progress every 30 seconds
        if [ $((CERT_WAIT_COUNT % 30)) -eq 0 ] && [ $CERT_WAIT_COUNT -gt 0 ]; then
            log "  Still waiting... (${CERT_WAIT_COUNT}s/${MAX_CERT_WAIT}s)"
            CERT_MESSAGE_CURRENT=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            if [ -n "$CERT_MESSAGE_CURRENT" ] && [ "$CERT_MESSAGE_CURRENT" != "null" ]; then
                log "  Status: $CERT_READY_STATUS - $CERT_MESSAGE_CURRENT"
            else
                log "  Status: $CERT_READY_STATUS"
            fi
            
            # Show CertificateRequest status if available
            CERT_REQUEST=$(oc get certificaterequest -n "$NAMESPACE" -l cert-manager.io/certificate-name="$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$CERT_REQUEST" ]; then
                CERT_REQUEST_READY=$(oc get certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                log "  CertificateRequest: $CERT_REQUEST ($CERT_REQUEST_READY)"
            fi
        fi
        
        sleep 5
        CERT_WAIT_COUNT=$((CERT_WAIT_COUNT + 5))
    done
    
    if [ "$CERT_READY_FINAL" = "false" ]; then
        error "Certificate did not become Ready within ${MAX_CERT_WAIT} seconds"
        log ""
        log "Diagnosing certificate issuance issue..."
        
        # Check CertificateRequest status
        CERT_REQUEST=$(oc get certificaterequest -n "$NAMESPACE" -l cert-manager.io/certificate-name="$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$CERT_REQUEST" ]; then
            log "Found CertificateRequest: $CERT_REQUEST"
            log "CertificateRequest details:"
            oc describe certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" 2>/dev/null | grep -A 20 "Status:\|Events:" || log "  Could not get details"
        fi
        
        log ""
        log "Certificate details:"
        oc describe certificate "$CERT_NAME" -n "$NAMESPACE" 2>/dev/null | grep -A 20 "Status:\|Events:" || log "  Could not get details"
        
        log ""
        log "Troubleshooting commands:"
        log "  oc -n $NAMESPACE describe certificate $CERT_NAME"
        log "  oc -n $NAMESPACE describe certificaterequest -l cert-manager.io/certificate-name=$CERT_NAME"
        log "  oc -n $NAMESPACE get certificate $CERT_NAME -w"
        log ""
        error "Cannot proceed without a Ready certificate. Please resolve the certificate issue and try again."
    fi
fi

# Verify secret exists and contains cert-manager certificate
log ""
log "Verifying TLS secret exists and contains cert-manager certificate..."
if ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    error "Secret '$SECRET_NAME' not found. Certificate must be Ready before proceeding."
fi

log "✓ Secret '$SECRET_NAME' exists"

# Check secret has required keys
if ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' &>/dev/null || \
   ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' &>/dev/null; then
    error "Secret '$SECRET_NAME' does not contain required keys (tls.crt, tls.key)"
fi

log "✓ Secret contains tls.crt and tls.key"

# Verify the certificate in the secret is from cert-manager (not self-signed)
log "Verifying certificate issuer..."
CERT_ISSUER=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "")
if [ -n "$CERT_ISSUER" ]; then
    log "Certificate issuer: $CERT_ISSUER"
    # Check if it's a self-signed cert (issuer == subject typically means self-signed)
    CERT_SUBJECT=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || echo "")
    if echo "$CERT_ISSUER" | grep -qi "StackRox\|self" || [ "$CERT_ISSUER" = "$CERT_SUBJECT" ]; then
        warning "Secret contains self-signed certificate. Waiting for cert-manager to update it..."
        log "The secret will be updated by cert-manager when the Certificate becomes Ready."
        log "If the certificate is Ready but secret still has self-signed cert, cert-manager may need more time."
    else
        log "✓ Certificate appears to be from cert-manager (not self-signed)"
    fi
else
    warning "Could not verify certificate issuer. Proceeding anyway..."
fi

# Step 5: Patch the Central CR to Reference the Secret
log ""
log "========================================================="
log "Step 5: Updating Central CR to Reference TLS Secret"
log "========================================================="

# Get Central CR name
CENTRAL_CR_NAME=$(oc get central -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CENTRAL_CR_NAME" ]; then
    error "Central CR not found in namespace '$NAMESPACE'. Please ensure RHACS is installed first."
fi
log "✓ Central CR found: $CENTRAL_CR_NAME"

log "Checking current Central CR configuration..."

# Check if defaultTLS is already configured
CURRENT_SECRET_REF=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.defaultTLS.secretRef.name}' 2>/dev/null || echo "")

if [ "$CURRENT_SECRET_REF" = "$SECRET_NAME" ]; then
    log "✓ Central CR already configured with secret '$SECRET_NAME'"
else
    log "Updating Central CR to use secret '$SECRET_NAME'..."
    
    # Patch Central CR with correct field path: spec.defaultTLS.secretRef.name
    if ! oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type=merge -p "{
      \"spec\": {
        \"defaultTLS\": {
          \"secretRef\": {
            \"name\": \"$SECRET_NAME\"
          }
        }
      }
    }"; then
        error "Failed to patch Central CR"
    fi
    
    log "✓ Central CR updated successfully"
    
    # Verify the update
    VERIFY_SECRET_REF=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.defaultTLS.secretRef.name}' 2>/dev/null || echo "")
    if [ "$VERIFY_SECRET_REF" = "$SECRET_NAME" ]; then
        log "✓ Verified: Central CR is configured with secret '$SECRET_NAME'"
    else
        warning "Central CR update may not have been applied correctly. Current secretRef: ${VERIFY_SECRET_REF:-none}"
        log "Checking Central CR structure:"
        oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.defaultTLS}' 2>/dev/null || log "  defaultTLS field not found"
    fi
    
    # Wait for Central operator to reconcile
    log "Waiting for Central operator to reconcile the change..."
    sleep 10
    log "✓ Central operator should have picked up the configuration"
fi

# Step 6: Restart the Central Pod to Load the New Certificate
log ""
log "========================================================="
log "Step 6: Restarting Central Pods"
log "========================================================="

log "Deleting Central pods to trigger restart..."

# Delete pods with central label
if oc delete pod -l app=central -n "$NAMESPACE" 2>/dev/null; then
    log "✓ Central pods deleted"
else
    warning "Failed to delete Central pods. Trying alternative label..."
    oc delete pod -l app.kubernetes.io/component=central -n "$NAMESPACE" 2>/dev/null || \
    warning "Could not delete Central pods. You may need to restart manually: oc -n $NAMESPACE delete pod -l app=central"
fi

log "Waiting for Central deployment to be Available..."
if oc wait --for=condition=Available "deployment/central" -n "$NAMESPACE" --timeout=300s 2>/dev/null; then
    log "✓ Central deployment is Available"
else
    warning "Central deployment may not be Available yet. Check status: oc get deployment central -n $NAMESPACE"
fi

# Wait a bit more for pods to fully start and load the certificate
log "Waiting for Central pods to fully initialize with new certificate..."
sleep 15

# Verify Central is using the cert-manager certificate
log ""
log "Verifying Central is using cert-manager certificate..."
CENTRAL_POD=$(oc get pods -n "$NAMESPACE" -l app=central --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_POD" ]; then
    log "Checking certificate in Central pod..."
    # Try to get certificate info from the pod (if possible)
    log "Central pod '$CENTRAL_POD' is running"
    log "To verify the certificate is being used, check:"
    log "  oc exec -n $NAMESPACE $CENTRAL_POD -- openssl x509 -in /run/secrets/stackrox.io/certs/tls.crt -noout -issuer -subject -dates"
else
    warning "Could not find running Central pod to verify certificate"
fi

# Step 7: Verify
log ""
log "========================================================="
log "Step 7: Verification"
log "========================================================="

log "Certificate and Central configuration:"
log "  Certificate: $CERT_NAME"
log "  Secret: $SECRET_NAME"
log "  Route hostname: $ROUTE_HOST"
log "  Central CR: $CENTRAL_CR_NAME"
log ""

# Check certificate status
CERT_FINAL_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "$CERT_FINAL_STATUS" = "True" ]; then
    log "✓ Certificate is Ready"
    
    # Get certificate expiry info if available
    CERT_NOT_AFTER=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.notAfter}' 2>/dev/null || echo "")
    if [ -n "$CERT_NOT_AFTER" ] && [ "$CERT_NOT_AFTER" != "null" ]; then
        log "  Certificate valid until: $CERT_NOT_AFTER"
    fi
else
    warning "Certificate status: $CERT_FINAL_STATUS (may still be issuing)"
fi

# Check Central pods
CENTRAL_PODS=$(oc get pods -n "$NAMESPACE" -l app=central --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "${CENTRAL_PODS:-0}" -gt 0 ]; then
    log "✓ Central pods are Running ($CENTRAL_PODS pod(s))"
else
    warning "No Running Central pods found. Check status: oc get pods -n $NAMESPACE -l app=central"
fi

# Final verification: Check that the secret contains cert-manager certificate (not self-signed)
log ""
log "Final verification: Checking secret contains cert-manager certificate..."
FINAL_SECRET_ISSUER=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || echo "")
if [ -n "$FINAL_SECRET_ISSUER" ]; then
    if echo "$FINAL_SECRET_ISSUER" | grep -qi "StackRox\|CN=.*CA" && ! echo "$FINAL_SECRET_ISSUER" | grep -qi "ZeroSSL\|Let's Encrypt\|zerossl"; then
        warning "Secret still contains self-signed certificate!"
        warning "Issuer: $FINAL_SECRET_ISSUER"
        warning "cert-manager may not have updated the secret yet, or the Certificate may not be Ready."
        warning "Check: oc get certificate $CERT_NAME -n $NAMESPACE"
        warning "Central may still be using the self-signed certificate. You may need to:"
        warning "  1. Ensure Certificate is Ready: oc get certificate $CERT_NAME -n $NAMESPACE"
        warning "  2. Wait for cert-manager to update the secret"
        warning "  3. Restart Central pods again: oc delete pod -l app=central -n $NAMESPACE"
    else
        log "✓ Secret contains cert-manager certificate"
        log "  Issuer: $FINAL_SECRET_ISSUER"
    fi
fi

# Final summary
log ""
log "========================================================="
log "RHACS Route TLS Setup Completed!"
log "========================================================="
log ""
log "Summary:"
log "  ✓ Certificate resource created: $CERT_NAME"
log "  ✓ TLS secret: $SECRET_NAME"
log "  ✓ Central CR configured with custom certificate"
log "  ✓ Central pods restarted"
log ""
log "Certificate Details:"
log "  Route hostname: $ROUTE_HOST"
log "  Issuer: $ISSUER_NAME ($ISSUER_KIND)"
log "  Duration: 90 days (2160h)"
log "  Renew before: 15 days (360h)"
log ""
log "The RHACS Central route is now configured with TLS."
log "Access RHACS at: https://$ROUTE_HOST"
log ""
log "To verify the certificate:"
log "  openssl s_client -connect $ROUTE_HOST:443 -servername $ROUTE_HOST < /dev/null | openssl x509 -noout -issuer -subject -dates"
log ""
log "To monitor certificate status:"
log "  oc -n $NAMESPACE get certificate $CERT_NAME -w"
log ""
log "Note: The certificate will auto-renew via cert-manager."
log "      Central will pick up the renewed certificate on restart or reconciliation."
log "========================================================="
log ""
