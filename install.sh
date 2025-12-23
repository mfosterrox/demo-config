#!/bin/bash

# Demo Config - Simple Setup Script
# Download and run with: curl -fsSL https://raw.githubusercontent.com/mfosterrox/demo-config/main/install.sh | bash

# Exit immediately on error - fail fast if any script fails
set -euo pipefail

# Trap to catch errors and show which command failed
trap 'error "Command failed: $BASH_COMMAND"' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Function to save variable to ~/.bashrc for debugging
save_to_bashrc() {
    local var_name="$1"
    local var_value="$2"
    local comment="${3:-}"
    
    if [ -z "$var_value" ]; then
        return 0  # Don't save empty values
    fi
    
    # Remove existing export line for this variable
    if [ -f ~/.bashrc ]; then
        sed -i "/^export ${var_name}=/d" ~/.bashrc 2>/dev/null || true
    else
        touch ~/.bashrc
    fi
    
    # Add comment if provided
    if [ -n "$comment" ]; then
        echo "# $comment" >> ~/.bashrc
    fi
    
    # Escape special characters in the value for safe storage
    local escaped_value=$(printf '%s\n' "$var_value" | sed "s/'/'\\\\''/g")
    echo "export ${var_name}='${escaped_value}'" >> ~/.bashrc
}

# Delete RHACS operators (cleanup existing operators)
delete_rhacs() {
    log "Deleting RHACS operators (cleaning up existing operators)..."
    if ! bash "${SCRIPT_DIR}/scripts/01-rhacs-delete.sh"; then
        error "RHACS delete script failed. Installation stopped."
    fi
    success "RHACS delete completed successfully"
}

# Install cert-manager operator (required for RHACS TLS certificates)
install_cert_manager() {
    log "Installing cert-manager operator..."
    if ! bash "${SCRIPT_DIR}/scripts/02-install-cert-manager.sh"; then
        error "Cert-manager installation script failed. Installation stopped."
    fi
    success "Cert-manager installation completed successfully"
}

# Setup RHACS route TLS certificate (creates custom certificate for RHACS)
setup_rhacs_tls_certificate() {
    log "Setting up RHACS route TLS certificate..."
    if ! bash "${SCRIPT_DIR}/scripts/03-setup-rhacs-route-tls.sh"; then
        error "RHACS TLS certificate setup script failed. Installation stopped."
    fi
    success "RHACS TLS certificate setup completed successfully"
}

# Install RHACS operator subscription
install_rhacs_operator() {
    log "Installing RHACS operator subscription..."
    if ! bash "${SCRIPT_DIR}/scripts/04-rhacs-subscription-install.sh"; then
        error "RHACS operator installation script failed. Installation stopped."
    fi
    success "RHACS operator installation completed successfully"
}

# Install RHACS Central
install_rhacs_central() {
    log "Installing RHACS Central..."
    if ! bash "${SCRIPT_DIR}/scripts/05-central-install.sh"; then
        error "RHACS Central installation script failed. Installation stopped."
    fi
    success "RHACS Central installation completed successfully"
}

# Setup RHACS Secured Cluster Services
setup_rhacs_scs() {
    log "Setting up RHACS Secured Cluster Services..."
    if ! bash "${SCRIPT_DIR}/scripts/06-scs-setup.sh"; then
        error "RHACS Secured Cluster Services setup script failed. Installation stopped."
    fi
    success "RHACS Secured Cluster Services setup completed successfully"
}

# Install Compliance Operator
install_compliance_operator() {
    log "Installing Compliance Operator..."
    if ! bash "${SCRIPT_DIR}/scripts/07-compliance-operator-install.sh"; then
        error "Compliance Operator installation script failed. Installation stopped."
    fi
    success "Compliance Operator installation completed successfully"
}

# Deploy demo applications
deploy_applications() {
    log "Deploying demo applications..."
    if ! bash "${SCRIPT_DIR}/scripts/08-deploy-applications.sh"; then
        error "Application deployment script failed. Installation stopped."
    fi
    success "Application deployment completed successfully"
}

# Setup Compliance Operator scan schedule
setup_co_scan_schedule() {
    log "Setting up Compliance Operator scan schedule..."
    if ! bash "${SCRIPT_DIR}/scripts/09-setup-co-scan-schedule.sh"; then
        error "Compliance Operator scan schedule setup script failed. Installation stopped."
    fi
    success "Compliance Operator scan schedule setup completed successfully"
}

# Trigger Compliance Operator scan
trigger_compliance_scan() {
    log "Triggering Compliance Operator scan..."
    if ! bash "${SCRIPT_DIR}/scripts/10-trigger-compliance-scan.sh"; then
        error "Compliance scan trigger script failed. Installation stopped."
    fi
    success "Compliance scan triggered successfully"
}

# Configure RHACS settings (enable monitoring and set policy guidelines)
configure_rhacs_settings() {
    log "Configuring RHACS settings (monitoring and policies)..."
    if ! bash "${SCRIPT_DIR}/scripts/11-configure-rhacs-settings.sh"; then
        error "RHACS configuration script failed. Installation stopped."
    fi
    success "RHACS configuration completed successfully"
}

# Setup Perses monitoring (install Cluster Observability Operator and Perses)
setup_perses_monitoring() {
    log "Setting up Perses monitoring (Cluster Observability Operator)..."
    if ! bash "${SCRIPT_DIR}/scripts/12-setup-perses-monitoring.sh"; then
        error "Perses monitoring setup script failed. Installation stopped."
    fi
    success "Perses monitoring setup completed successfully"
}


# Main function
main() {
    log "Starting Demo Config Setup..."
    
    # Clone the repository if running from curl
    # Check if we're running from curl by looking for the scripts directory
    if [ ! -d "scripts" ] || [ ! -f "scripts/01-rhacs-delete.sh" ]; then
        log "Scripts not found locally, cloning repository..."
        REPO_DIR="$HOME/demo-config"
        if [ -d "$REPO_DIR" ]; then
            log "Repository already exists, updating..."
            cd "$REPO_DIR"
            git pull
        else
            log "Cloning repository..."
            git clone https://github.com/mfosterrox/demo-config.git "$REPO_DIR"
            cd "$REPO_DIR"
        fi
        SCRIPT_DIR="$REPO_DIR"
    else
        # Get script directory when running locally
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    
    log "Using script directory: $SCRIPT_DIR"
    
    # Verify scripts exist - fail fast if any script is missing
    for script in "01-rhacs-delete.sh" "02-install-cert-manager.sh" "03-setup-rhacs-route-tls.sh" "04-rhacs-subscription-install.sh" "05-central-install.sh" "06-scs-setup.sh" "07-compliance-operator-install.sh" "08-deploy-applications.sh" "09-setup-co-scan-schedule.sh" "10-trigger-compliance-scan.sh" "11-configure-rhacs-settings.sh" "12-setup-perses-monitoring.sh"; do
        if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
            error "Required script not found: $SCRIPT_DIR/scripts/$script"
        fi
    done
    log "✓ All required scripts found"
    
    # Run setup scripts in order
    delete_rhacs
    install_cert_manager
    setup_rhacs_tls_certificate
    install_rhacs_operator
    install_rhacs_central
    setup_rhacs_scs
    install_compliance_operator
    
    # Run scripts 08, 09, 11, and 12 in parallel to speed up installation
    log "Running scripts 08, 09, 11, and 12 in parallel..."
    
    # Start scripts 08, 09, 11, and 12 in background
    deploy_applications &
    DEPLOY_APPS_PID=$!
    
    setup_co_scan_schedule &
    SETUP_SCAN_PID=$!
    
    configure_rhacs_settings &
    CONFIG_RHACS_PID=$!
    
    setup_perses_monitoring &
    SETUP_PERSES_PID=$!
    
    # Wait for script 09 to complete before running script 10
    log "Waiting for compliance scan schedule setup (script 09) to complete..."
    wait $SETUP_SCAN_PID
    if [ $? -ne 0 ]; then
        error "Compliance scan schedule setup failed. Installation stopped."
    fi
    
    # Now run script 10 (depends on script 09)
    trigger_compliance_scan
    
    # Wait for remaining parallel scripts to complete
    log "Waiting for remaining parallel scripts to complete..."
    wait $DEPLOY_APPS_PID
    if [ $? -ne 0 ]; then
        error "Application deployment failed. Installation stopped."
    fi
    
    wait $CONFIG_RHACS_PID
    if [ $? -ne 0 ]; then
        error "RHACS configuration failed. Installation stopped."
    fi
    
    wait $SETUP_PERSES_PID
    if [ $? -ne 0 ]; then
        error "Perses monitoring setup failed. Installation stopped."
    fi
    
    log "✓ All parallel scripts completed successfully"
    
    log ""
    log "========================================================="
    success "Demo Config setup completed successfully!"
    log "========================================================="
    log ""
    
    # Final Information Summary
    log "========================================================="
    log "Installation Summary"
    log "========================================================="
    log ""
    
    # RHACS Information
    log "RHACS Access Information:"
    log "------------------------"
    RHACS_NAMESPACE="rhacs-operator"
    
    # Get Central route
    CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    ROX_ENDPOINT="$CENTRAL_ROUTE"
    ROX_API_TOKEN=""
    
    if [ -n "$CENTRAL_ROUTE" ]; then
        # Get admin password
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        fi
        
        log "  RHACS UI URL:     https://$CENTRAL_ROUTE"
        log "  Username:         admin"
        if [ -n "$ADMIN_PASSWORD" ]; then
            log "  Password:         $ADMIN_PASSWORD"
            
            # Generate API token for debugging purposes
            if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
                ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
                ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
                
                set +e
                TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
                    -u "admin:${ADMIN_PASSWORD}" \
                    -H "Content-Type: application/json" \
                    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
                    -d '{"name":"install-script-debug-token","roles":["Admin"]}' 2>&1)
                TOKEN_CURL_EXIT_CODE=$?
                set -e
                
                if [ $TOKEN_CURL_EXIT_CODE -eq 0 ]; then
                    # Extract token from response
                    if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
                    fi
                    
                    if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
                        ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
                    fi
                fi
            fi
        else
            log "  Password:         (retrieve with: oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"
        fi
    else
        log "  RHACS UI URL:     (not found - may still be deploying)"
        log "  Username:         admin"
        log "  Password:         (retrieve with: oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"
    fi
    log ""
    
    # Compliance Scan Information
    log "Compliance Scan Status:"
    log "----------------------"
    COMPLIANCE_NAMESPACE="openshift-compliance"
    if oc get namespace "$COMPLIANCE_NAMESPACE" &>/dev/null 2>&1; then
        SCAN_CONFIGS=$(oc get scanconfiguration -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        SCANS=$(oc get compliancescan -n "$COMPLIANCE_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        log "  Scan Configurations: $SCAN_CONFIGS"
        log "  Compliance Scans:     $SCANS"
        log "  Namespace:           $COMPLIANCE_NAMESPACE"
        log "  View scans:          oc get compliancescan -n $COMPLIANCE_NAMESPACE"
    else
        log "  Compliance Operator namespace not found"
    fi
    log ""
    
    # Monitoring Information
    log "Monitoring & Observability:"
    log "---------------------------"
    if oc get monitoringstack rhacs-monitoring-stack -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
        log "  MonitoringStack:     Installed (rhacs-monitoring-stack)"
    fi
    if oc get datasource rhacs-datasource -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
        log "  Perses Datasource:   Installed (rhacs-datasource)"
    fi
    if oc get dashboard rhacs-dashboard -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
        log "  Perses Dashboard:    Installed (rhacs-dashboard)"
        log "  Access via:          OpenShift Console -> Observe -> Dashboards"
    fi
    log ""
    
    # Demo Applications Information
    log "Demo Applications:"
    log "------------------"
    DEMO_LABEL="demo=roadshow"
    DEMO_DEPLOYMENTS=$(oc get deployments -l "$DEMO_LABEL" -A --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    DEMO_NAMESPACES=$(oc get deployments -l "$DEMO_LABEL" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u | wc -l | tr -d '[:space:]' || echo "0")
    log "  Deployments:         $DEMO_DEPLOYMENTS"
    log "  Namespaces:          $DEMO_NAMESPACES"
    log "  Label:               $DEMO_LABEL"
    log "  View apps:           oc get deployments -l $DEMO_LABEL -A"
    log ""
    
    log "========================================================="
    log ""
    
    # Save meaningful variables to ~/.bashrc for debugging
    save_to_bashrc "RHACS_NAMESPACE" "$RHACS_NAMESPACE" "RHACS namespace"
    save_to_bashrc "ROX_ENDPOINT" "$ROX_ENDPOINT" "RHACS Central endpoint (for API calls and roxctl)"
    if [ -n "$ROX_API_TOKEN" ]; then
        save_to_bashrc "ROX_API_TOKEN" "$ROX_API_TOKEN" "RHACS API token (may expire - regenerate if needed)"
    fi
    if [ -n "$ADMIN_PASSWORD" ]; then
        save_to_bashrc "ADMIN_PASSWORD" "$ADMIN_PASSWORD" "RHACS admin password"
    fi
    # Initialize variables that may be set by other scripts
    CONSOLE_ROUTE="${CONSOLE_ROUTE:-}"
    RHDH_ROUTE="${RHDH_ROUTE:-}"
    if [ -n "$CONSOLE_ROUTE" ]; then
        save_to_bashrc "CONSOLE_ROUTE" "$CONSOLE_ROUTE" "OpenShift Console route"
    fi
    if [ -n "$RHDH_ROUTE" ]; then
        save_to_bashrc "RHDH_ROUTE" "$RHDH_ROUTE" "Red Hat Developer Hub route"
    fi
    log ""
    
}


# Run main function
main "$@"
