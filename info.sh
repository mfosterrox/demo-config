#!/bin/bash
# Simple script to display RHACS and OpenShift Console URLs and passwords

# Exit immediately on error
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    echo -e "${RED}Error: OpenShift CLI not connected. Please login first with: oc login${NC}" >&2
    exit 1
fi

RHACS_NAMESPACE="rhacs-operator"

echo ""
echo -e "${GREEN}OpenShift Console:${NC}"
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "")
if [ -n "$CONSOLE_URL" ]; then
    echo "  URL: $CONSOLE_URL"
    
    # Get current username
    CURRENT_USER=$(oc whoami 2>/dev/null || echo "")
    if [ -n "$CURRENT_USER" ]; then
        echo "  Username: $CURRENT_USER"
    fi
    
    # Try to get kubeadmin password (for initial admin user)
    KUBEADMIN_PASSWORD=$(oc get secret kubeadmin -n kube-system -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -n "$KUBEADMIN_PASSWORD" ]; then
        KUBEADMIN_PASSWORD_DECODED=$(echo "$KUBEADMIN_PASSWORD" | base64 -d 2>/dev/null || echo "")
        if [ -n "$KUBEADMIN_PASSWORD_DECODED" ]; then
            echo "  kubeadmin Password: $KUBEADMIN_PASSWORD_DECODED"
        fi
    fi
    
    # Note: If using other authentication methods (OAuth, LDAP, etc.), 
    # the password may not be retrievable from cluster secrets
    if [ -z "$KUBEADMIN_PASSWORD" ]; then
        echo -e "  ${YELLOW}Note: Password not available in cluster secrets.${NC}"
        echo -e "  ${YELLOW}If using OAuth/LDAP, use your identity provider credentials.${NC}"
    fi
else
    echo -e "  ${YELLOW}Console URL not available${NC}"
fi

echo ""
echo -e "${GREEN}RHACS (Red Hat Advanced Cluster Security):${NC}"
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_ROUTE" ]; then
    echo "  URL: https://$CENTRAL_ROUTE"
    
    # Get admin password
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASSWORD_B64" ]; then
        ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            echo "  Username: admin"
            echo "  Password: $ADMIN_PASSWORD"
        else
            echo -e "  ${YELLOW}Password: Unable to decode${NC}"
        fi
    else
        echo -e "  ${YELLOW}Password: Secret not found${NC}"
    fi
else
    echo -e "  ${YELLOW}RHACS Central route not found. Central may still be deploying.${NC}"
fi
echo ""

