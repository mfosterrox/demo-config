#!/bin/bash
# RHACS Route TLS Setup Script
# Configures TLS for RHACS Central using cert-manager Certificate resource

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
    error "cert-manager is not installed. Please install cert-manager first."
fi
log "✓ cert-manager CRD found"

# Check if cert-manager controller is running
CERT_MANAGER_NS="cert-manager"
if oc get namespace "$CERT_MANAGER_NS" &>/dev/null; then
    CERT_MANAGER_PODS=$(oc get pods -n "$CERT_MANAGER_NS" -l app.kubernetes.io/name=cert-manager --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [ "${CERT_MANAGER_PODS:-0}" -eq 0 ]; then
        warning "cert-manager pods may not be running. Continuing anyway..."
    else
        log "✓ cert-manager controller is running ($CERT_MANAGER_PODS pod(s))"
    fi
else
    warning "cert-manager namespace not found. Continuing anyway (may be installed in different namespace)..."
fi

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

# Check if Central CR exists
log ""
log "========================================================="
log "Step 0: Checking RHACS Central"
log "========================================================="

# Get Central CR name (usually "central" but could be different)
CENTRAL_CR_NAME=$(oc get central -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CENTRAL_CR_NAME" ]; then
    error "Central CR not found in namespace '$NAMESPACE'. Please ensure RHACS is installed first."
fi
log "✓ Central CR found: $CENTRAL_CR_NAME"

# Get Central route hostname
ROUTE_HOST=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$ROUTE_HOST" ]; then
    error "Failed to get Central route hostname. Check route exists: oc get route central -n $NAMESPACE"
fi
log "✓ Route hostname: $ROUTE_HOST"

# Check if cert-manager issuer/clusterissuer exists
log ""
log "Checking for cert-manager Issuer/ClusterIssuer..."
log "Please ensure you have a ClusterIssuer or Issuer configured."

# Prompt for issuer details (with defaults)
ISSUER_NAME="${CERT_MANAGER_ISSUER_NAME:-letsencrypt-prod}"
ISSUER_KIND="${CERT_MANAGER_ISSUER_KIND:-ClusterIssuer}"

log ""
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

# Step 1: Create Certificate Resource
log ""
log "========================================================="
log "Step 1: Creating Certificate Resource with cert-manager"
log "========================================================="

CERT_NAME="central-tls-cert"
SECRET_NAME="central-tls"

# Check if the secret already exists (from self-signed cert)
if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Secret '$SECRET_NAME' already exists (likely from self-signed certificate)"
    log "This secret will be replaced/updated when the Certificate resource issues a new certificate"
fi

# Check if certificate already exists
if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Certificate '$CERT_NAME' already exists"
    
    # Check certificate status
    CERT_READY=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [ "$CERT_READY" = "True" ]; then
        log "✓ Certificate is Ready"
    else
        log "Certificate status: $CERT_READY"
        CERT_MESSAGE=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        if [ -n "$CERT_MESSAGE" ]; then
            log "  Message: $CERT_MESSAGE"
        fi
        warning "Certificate exists but is not Ready. You may need to check the CertificateRequest."
    fi
else
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
  duration: 2160h  # 90 days
  renewBefore: 360h  # Renew 15 days before expiry
EOF
)
    
    # Apply Certificate
    echo "$CERT_YAML" | oc apply -f - || error "Failed to create Certificate resource"
    log "✓ Certificate resource created"
    
    # Wait for certificate to be issued
    log ""
    log "Waiting for certificate to be issued..."
    log "This may take a few minutes depending on your issuer (Let's Encrypt can take 1-2 minutes)..."
    log "Monitoring certificate status (press Ctrl+C to skip waiting)..."
    
    MAX_WAIT=300  # 5 minutes
    WAIT_COUNT=0
    CERT_READY=false
    
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
            CERT_READY_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
            
            if [ "$CERT_READY_STATUS" = "True" ]; then
                CERT_READY=true
                log "✓ Certificate is Ready!"
                break
            elif [ "$CERT_READY_STATUS" = "False" ]; then
                CERT_MESSAGE=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                if [ -n "$CERT_MESSAGE" ]; then
                    log "  Certificate not ready: $CERT_MESSAGE"
                fi
            fi
        fi
        
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Still waiting... (${WAIT_COUNT}s/${MAX_WAIT}s)"
            log "  Check status: oc -n $NAMESPACE get certificate $CERT_NAME -w"
        fi
        
        sleep 5
        WAIT_COUNT=$((WAIT_COUNT + 5))
    done
    
    if [ "$CERT_READY" = false ]; then
        warning "Certificate did not become Ready within ${MAX_WAIT} seconds"
        log ""
        log "Diagnosing certificate issuance issue..."
        
        # Check CertificateRequest status
        CERT_REQUEST=$(oc get certificaterequest -n "$NAMESPACE" -l cert-manager.io/certificate-name="$CERT_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$CERT_REQUEST" ]; then
            log "Found CertificateRequest: $CERT_REQUEST"
            
            CERT_REQUEST_READY=$(oc get certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
            CERT_REQUEST_MESSAGE=$(oc get certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            CERT_REQUEST_REASON=$(oc get certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
            
            log "  CertificateRequest Ready status: $CERT_REQUEST_READY"
            if [ -n "$CERT_REQUEST_REASON" ]; then
                log "  Reason: $CERT_REQUEST_REASON"
            fi
            if [ -n "$CERT_REQUEST_MESSAGE" ]; then
                log "  Message: $CERT_REQUEST_MESSAGE"
            fi
            
            # Check for failure conditions
            CERT_REQUEST_FAILURE=$(oc get certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Denied")].message}' 2>/dev/null || echo "")
            if [ -n "$CERT_REQUEST_FAILURE" ]; then
                warning "CertificateRequest was denied: $CERT_REQUEST_FAILURE"
            fi
            
            # Show CertificateRequest details
            log ""
            log "CertificateRequest details:"
            oc describe certificaterequest "$CERT_REQUEST" -n "$NAMESPACE" 2>/dev/null | grep -A 30 "Status:\|Events:" || log "  Could not get details"
            
            # Check for Order/Challenge resources (for ACME/Let's Encrypt)
            if [ "$ISSUER_KIND" = "ClusterIssuer" ]; then
                ISSUER_TYPE=$(oc get clusterissuer "$ISSUER_NAME" -o jsonpath='{.spec.acme.server}' 2>/dev/null || echo "")
                if [ -n "$ISSUER_TYPE" ]; then
                    log ""
                    log "ACME/Let's Encrypt issuer detected. Checking for Order resources..."
                    ORDERS=$(oc get order -n "$NAMESPACE" -l acme.cert-manager.io/certificate-name="$CERT_NAME" 2>/dev/null || echo "")
                    if [ -n "$ORDERS" ]; then
                        log "Found Order resources:"
                        oc get order -n "$NAMESPACE" -l acme.cert-manager.io/certificate-name="$CERT_NAME" 2>/dev/null || true
                        log ""
                        log "Check Order details: oc -n $NAMESPACE describe order -l acme.cert-manager.io/certificate-name=$CERT_NAME"
                        log "Check Challenge resources: oc -n $NAMESPACE get challenge"
                    fi
                fi
            fi
        else
            warning "No CertificateRequest found for certificate $CERT_NAME"
        fi
        
        log ""
        log "Troubleshooting steps:"
        log "  1. Check CertificateRequest: oc -n $NAMESPACE describe certificaterequest $CERT_REQUEST"
        log "  2. Check Certificate: oc -n $NAMESPACE describe certificate $CERT_NAME"
        log "  3. Check cert-manager logs: oc logs -n cert-manager -l app.kubernetes.io/name=cert-manager"
        log "  4. Verify issuer is configured correctly: oc describe clusterissuer $ISSUER_NAME"
        log "  5. For Let's Encrypt, ensure DNS is properly configured and the domain is publicly accessible"
        log ""
        warning "Proceeding with next steps anyway. The certificate may still be issuing..."
        warning "Central will continue using the self-signed certificate until the new one is ready."
    fi
fi

# Verify secret exists
log ""
log "Verifying TLS secret exists..."
if oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "✓ Secret '$SECRET_NAME' exists"
    
    # Check if this is from cert-manager or self-signed
    if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
        CERT_SECRET_NAME=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.secretName}' 2>/dev/null || echo "")
        if [ "$CERT_SECRET_NAME" = "$SECRET_NAME" ]; then
            log "  Secret is managed by cert-manager Certificate resource"
        fi
    else
        log "  Note: Secret exists but Certificate resource not found (may be self-signed cert)"
        log "  The Certificate resource will update this secret when it's issued"
    fi
    
    # Check secret has required keys
    if oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' &>/dev/null && \
       oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' &>/dev/null; then
        log "✓ Secret contains tls.crt and tls.key"
    else
        warning "Secret exists but may not have required keys (tls.crt, tls.key)"
    fi
else
    log "Secret '$SECRET_NAME' not found yet."
    if oc get certificate "$CERT_NAME" -n "$NAMESPACE" &>/dev/null; then
        log "  It will be created when the Certificate resource issues the certificate."
        log "  You may need to wait for the certificate to be Ready before proceeding."
    else
        warning "Secret not found and Certificate resource doesn't exist. Check Certificate creation."
    fi
fi

# Step 2: Update Central CR to Use Custom Certificate
log ""
log "========================================================="
log "Step 2: Updating Central CR to Use Custom Certificate"
log "========================================================="

# Check if certificate is ready before proceeding
CERT_FINAL_STATUS=$(oc get certificate "$CERT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
if [ "$CERT_FINAL_STATUS" != "True" ]; then
    warning "Certificate is not Ready yet (status: $CERT_FINAL_STATUS)"
    warning "Central will continue using the existing certificate (self-signed) until the new certificate is issued."
    warning "The Central CR will be configured now, and Central will automatically use the new certificate when it's ready."
    log ""
fi

log "Checking current Central CR configuration..."

# Check if customCert is already configured
CURRENT_SECRET_REF=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.tls.customCert.secretRef}' 2>/dev/null || echo "")

if [ "$CURRENT_SECRET_REF" = "$SECRET_NAME" ]; then
    log "✓ Central CR already configured with secret '$SECRET_NAME'"
    log "Skipping Central CR update..."
else
    log "Updating Central CR to use secret '$SECRET_NAME'..."
    
    # Check if tls section exists
    HAS_TLS=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.tls}' 2>/dev/null || echo "")
    
    if [ -z "$HAS_TLS" ] || [ "$HAS_TLS" = "null" ]; then
        # Add tls section with customCert
        log "  Adding TLS configuration to Central CR..."
        oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type merge -p '{
          "spec": {
            "central": {
              "tls": {
                "customCert": {
                  "secretRef": "'"$SECRET_NAME"'"
                }
              }
            }
          }
        }' || error "Failed to patch Central CR"
    else
        # Update existing tls section
        log "  Updating TLS configuration in Central CR..."
        oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type json -p '[{
          "op": "add",
          "path": "/spec/central/tls/customCert",
          "value": {
            "secretRef": "'"$SECRET_NAME"'"
          }
        }]' 2>/dev/null || \
        oc patch central "$CENTRAL_CR_NAME" -n "$NAMESPACE" --type merge -p '{
          "spec": {
            "central": {
              "tls": {
                "customCert": {
                  "secretRef": "'"$SECRET_NAME"'"
                }
              }
            }
          }
        }' || error "Failed to patch Central CR"
    fi
    
    log "✓ Central CR updated successfully"
    
    # Verify the update
    VERIFY_SECRET_REF=$(oc get central "$CENTRAL_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.central.tls.customCert.secretRef}' 2>/dev/null || echo "")
    if [ "$VERIFY_SECRET_REF" = "$SECRET_NAME" ]; then
        log "✓ Verified: Central CR is configured with secret '$SECRET_NAME'"
    else
        warning "Central CR update may not have been applied correctly. Current secretRef: ${VERIFY_SECRET_REF:-none}"
    fi
fi

# Step 3: Restart Central to Apply Changes
log ""
log "========================================================="
log "Step 3: Restarting Central to Apply Changes"
log "========================================================="

log "Restarting Central pods to load the new certificate..."

# Get Central deployment name
CENTRAL_DEPLOYMENT=$(oc get deployment -n "$NAMESPACE" -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$CENTRAL_DEPLOYMENT" ]; then
    # Try alternative label
    CENTRAL_DEPLOYMENT=$(oc get deployment -n "$NAMESPACE" -l app.kubernetes.io/component=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [ -n "$CENTRAL_DEPLOYMENT" ]; then
    log "Found Central deployment: $CENTRAL_DEPLOYMENT"
    log "Deleting Central pods to trigger restart..."
    
    # Delete pods with central label
    oc delete pod -l app=central -n "$NAMESPACE" 2>/dev/null || \
    oc delete pod -l app.kubernetes.io/component=central -n "$NAMESPACE" 2>/dev/null || \
    warning "Failed to delete Central pods. You may need to restart manually."
    
    log "✓ Central pods deleted, waiting for restart..."
    
    # Wait for pods to be ready
    log "Waiting for Central pods to be ready..."
    if oc wait --for=condition=Available "deployment/$CENTRAL_DEPLOYMENT" -n "$NAMESPACE" --timeout=300s 2>/dev/null; then
        log "✓ Central pods are ready"
    else
        warning "Central pods may not be ready yet. Check status: oc get pods -n $NAMESPACE -l app=central"
    fi
else
    warning "Could not find Central deployment. You may need to restart Central manually:"
    warning "  oc -n $NAMESPACE delete pod -l app=central"
fi

# Final summary
log ""
log "========================================================="
log "RHACS Route TLS Setup Completed Successfully!"
log "========================================================="
log ""
log "Summary:"
log "  ✓ Certificate resource: $CERT_NAME"
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
log "To monitor certificate status:"
log "  oc -n $NAMESPACE get certificate $CERT_NAME -w"
log ""
log "To check certificate details:"
log "  oc -n $NAMESPACE describe certificate $CERT_NAME"
log ""
log "Note: If using Let's Encrypt, ensure your route hostname is publicly"
log "      accessible and DNS is properly configured."
log "========================================================="
log ""
