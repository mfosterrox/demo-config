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
    deploy_applications
    setup_co_scan_schedule
    trigger_compliance_scan
    configure_rhacs_settings
    setup_perses_monitoring
    
    log "========================================================="
    success "Demo Config setup completed successfully!"
    log "========================================================="
    log ""
    
    # Display RHACS access information
    log "Retrieving RHACS access information..."
    RHACS_NAMESPACE="rhacs-operator"
    
    # Get Central route
    CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$CENTRAL_ROUTE" ]; then
        # Get admin password
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
        fi
        
        log ""
        log "========================================================="
        log "RHACS Access Information"
        log "========================================================="
        log "RHACS UI URL:     https://$CENTRAL_ROUTE"
        log "Username:         admin"
        if [ -n "$ADMIN_PASSWORD" ]; then
            log "Password:         $ADMIN_PASSWORD"
        else
            log "Password:         (retrieve with: oc get secret central-htpasswd -n $RHACS_NAMESPACE -o jsonpath='{.data.password}' | base64 -d)"
        fi
        log "========================================================="
        log ""
    else
        warning "Central route not found. RHACS may still be deploying."
    fi
    
}


# Run main function
main "$@"
