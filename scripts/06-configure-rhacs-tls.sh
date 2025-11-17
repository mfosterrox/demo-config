#!/bin/bash
# RHACS TLS/HTTPS Route Configuration Script
# Configures TLS termination for the RHACS Central route in OpenShift

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

# Verify namespace and route exist
if ! oc get ns "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found"
    exit 1
fi

if ! oc -n "$NAMESPACE" get route "$ROUTE_NAME" &>/dev/null; then
    error "RHACS route '$ROUTE_NAME' not found in namespace '$NAMESPACE'"
    exit 1
fi

log "Using namespace: $NAMESPACE"

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

# Function to configure TLS with edge termination (default router certificate)
configure_edge_tls_default() {
    log "Configuring TLS with edge termination using default router certificate..."
    
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p '{
        "spec": {
            "tls": {
                "termination": "edge",
                "insecureEdgeTerminationPolicy": "Redirect"
            }
        }
    }'
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured successfully with edge termination"
        log "  Termination: edge"
        log "  Insecure policy: Redirect (HTTP -> HTTPS)"
        log "  Certificate: Default router certificate"
        log ""
        warning "⚠️  IMPORTANT: The default router certificate is likely self-signed"
        warning "   Browsers will show a certificate warning (NET::ERR_CERT_AUTHORITY_INVALID)"
        warning "   This is normal for development/testing environments"
        log ""
        log "To resolve the certificate warning, you have these options:"
        log "  1. Accept the certificate in your browser (click 'Advanced' -> 'Proceed')"
        log "  2. Use a custom trusted certificate (run with --custom-cert option)"
        log "  3. Configure Let's Encrypt certificate using cert-manager"
        log ""
        log "For production, use option 2 or 3 with a trusted certificate authority."
    else
        error "Failed to configure TLS"
        return 1
    fi
}

# Function to configure TLS with edge termination (custom certificate)
configure_edge_tls_custom() {
    local cert_file="$1"
    local key_file="$2"
    local ca_file="${3:-}"
    
    if [ -z "$cert_file" ] || [ -z "$key_file" ]; then
        error "Certificate and key files are required for custom TLS configuration"
        return 1
    fi
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        error "Certificate or key file not found"
        return 1
    fi
    
    log "Configuring TLS with edge termination using custom certificate..."
    
    # Create or update TLS secret
    SECRET_NAME="central-tls"
    
    if [ -n "$ca_file" ] && [ -f "$ca_file" ]; then
        log "Creating TLS secret with certificate, key, and CA..."
        oc create secret tls "$SECRET_NAME" \
            --cert="$cert_file" \
            --key="$key_file" \
            --certificate-authority="$ca_file" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | oc apply -f -
    else
        log "Creating TLS secret with certificate and key..."
        oc create secret tls "$SECRET_NAME" \
            --cert="$cert_file" \
            --key="$key_file" \
            -n "$NAMESPACE" \
            --dry-run=client -o yaml | oc apply -f -
    fi
    
    # Update route to use the secret
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p "{
        \"spec\": {
            \"tls\": {
                \"termination\": \"edge\",
                \"insecureEdgeTerminationPolicy\": \"Redirect\",
                \"certificate\": \"$(cat $cert_file | base64 -w 0)\",
                \"key\": \"$(cat $key_file | base64 -w 0)\"
            }
        }
    }"
    
    # Alternative: Use secret reference (recommended)
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='merge' -p "{
        \"spec\": {
            \"tls\": {
                \"termination\": \"edge\",
                \"insecureEdgeTerminationPolicy\": \"Redirect\",
                \"key\": \"\",
                \"certificate\": \"\"
            }
        }
    }"
    
    # Set the secret reference
    oc set data route/"$ROUTE_NAME" -n "$NAMESPACE" --from-file=tls.crt="$cert_file" --from-file=tls.key="$key_file" 2>/dev/null || \
    oc patch route "$ROUTE_NAME" -n "$NAMESPACE" --type='json' -p "[
        {
            \"op\": \"replace\",
            \"path\": \"/spec/tls/key\",
            \"value\": \"$(cat $key_file | base64 -w 0)\"
        },
        {
            \"op\": \"replace\",
            \"path\": \"/spec/tls/certificate\",
            \"value\": \"$(cat $cert_file | base64 -w 0)\"
        }
    ]"
    
    if [ $? -eq 0 ]; then
        log "✓ TLS configured successfully with custom certificate"
        log "  Termination: edge"
        log "  Certificate: $cert_file"
        log "  Key: $key_file"
    else
        error "Failed to configure TLS with custom certificate"
        return 1
    fi
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
log ""
log "========================================================="
log "RHACS TLS Configuration Options"
log "========================================================="
log "1. Edge termination with default router certificate (recommended for most cases)"
log "2. Edge termination with custom certificate"
log "3. Passthrough termination (TLS terminates at backend)"
log "4. Reencrypt termination (TLS terminates at router, re-encrypts to backend)"
log "========================================================="
log ""

# Default to edge termination with default certificate
if [ "$1" = "--custom-cert" ] && [ -n "$2" ] && [ -n "$3" ]; then
    configure_edge_tls_custom "$2" "$3" "$4"
elif [ "$1" = "--passthrough" ]; then
    configure_passthrough_tls
elif [ "$1" = "--reencrypt" ]; then
    configure_reencrypt_tls "$2"
else
    # Default: edge termination with default router certificate
    configure_edge_tls_default
fi

# Verify configuration
log ""
log "Verifying route configuration..."
UPDATED_ROUTE=$(oc get route "$ROUTE_NAME" -n "$NAMESPACE" -o json)
UPDATED_TLS=$(echo "$UPDATED_ROUTE" | jq -r '.spec.tls // empty' 2>/dev/null)

if [ -n "$UPDATED_TLS" ] && [ "$UPDATED_TLS" != "null" ]; then
    TERMINATION=$(echo "$UPDATED_ROUTE" | jq -r '.spec.tls.termination // "none"')
    INSECURE_POLICY=$(echo "$UPDATED_ROUTE" | jq -r '.spec.tls.insecureEdgeTerminationPolicy // "none"')
    
    log "✓ Route TLS configuration verified"
    log "  Termination: $TERMINATION"
    log "  Insecure policy: $INSECURE_POLICY"
    log "  Host: $CURRENT_HOST"
    log ""
    
    # Check certificate status
    log "Checking certificate status..."
    CERT_CHECK=$(echo | openssl s_client -connect "$CURRENT_HOST:443" -servername "$CURRENT_HOST" 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null)
    
    if [ -n "$CERT_CHECK" ]; then
        CERT_SUBJECT=$(echo "$CERT_CHECK" | grep "subject=" | sed 's/subject=//')
        CERT_ISSUER=$(echo "$CERT_CHECK" | grep "issuer=" | sed 's/issuer=//')
        log "  Certificate Subject: $CERT_SUBJECT"
        log "  Certificate Issuer: $CERT_ISSUER"
        
        # Check if certificate is self-signed
        if echo "$CERT_SUBJECT" | grep -q "$CERT_ISSUER"; then
            warning "  ⚠️  Certificate appears to be self-signed"
            warning "  Browser will show security warning"
        fi
    else
        log "  Could not retrieve certificate details (may need to accept certificate first)"
    fi
    
    log ""
    log "========================================================="
    log "RHACS HTTPS Configuration Complete"
    log "========================================================="
    log "HTTPS URL: https://$CURRENT_HOST"
    if [ "$INSECURE_POLICY" = "Redirect" ]; then
        log "HTTP URL: http://$CURRENT_HOST (redirects to HTTPS)"
    fi
    log ""
    log "⚠️  If you see a certificate warning in your browser:"
    log "   1. Click 'Advanced' button"
    log "   2. Click 'Proceed to [hostname] (unsafe)'"
    log "   3. This is safe for development/testing environments"
    log ""
    log "For production, use a trusted certificate:"
    log "   ./scripts/06-configure-rhacs-tls.sh --custom-cert /path/to/cert.crt /path/to/key.key"
    log "========================================================="
else
    warning "TLS configuration may not have been applied correctly"
fi

if [ "$SCRIPT_FAILED" = true ]; then
    warning "TLS configuration completed with errors. Review log output for details."
    exit 1
else
    log "✓ RHACS TLS configuration completed successfully!"
fi

