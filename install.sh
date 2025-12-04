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

# Run RHACS setup script (Step 1)
setup_rhacs() {
    log "Running RHACS secured cluster setup..."
    if ! bash "${SCRIPT_DIR}/scripts/01-rhacs-setup.sh"; then
        error "RHACS setup script failed. Installation stopped."
    fi
    success "RHACS setup completed successfully"
}

# Install Red Hat Compliance Operator (Step 2)
install_compliance_operator() {
    log "Installing Red Hat Compliance Operator..."
    if ! bash "${SCRIPT_DIR}/scripts/02-compliance-operator-install.sh"; then
        error "Compliance Operator installation script failed. Installation stopped."
    fi
    success "Compliance Operator installation completed successfully"
}

# Setup Perses monitoring (Step 3)
setup_perses_monitoring() {
    log "Setting up Perses monitoring..."
    if ! bash "${SCRIPT_DIR}/scripts/03-setup-perses-monitoring.sh"; then
        error "Perses monitoring setup script failed. Installation stopped."
    fi
    success "Perses monitoring setup completed successfully"
}

# Setup compliance scan schedule (Step 4)
setup_compliance_scan_schedule() {
    log "Setting up compliance scan schedule..."
    if ! bash "${SCRIPT_DIR}/scripts/04-setup-co-scan-schedule.sh"; then
        error "Compliance scan schedule script failed. Installation stopped."
    fi
    success "Compliance scan schedule setup completed successfully"
}

# Trigger compliance scan (Step 5)
trigger_compliance_scan() {
    log "Triggering compliance scan..."
    if ! bash "${SCRIPT_DIR}/scripts/05-trigger-compliance-scan.sh"; then
        error "Compliance scan trigger script failed. Installation stopped."
    fi
    success "Compliance scan trigger completed successfully"
}

# Configure RHACS settings (Step 6)
configure_rhacs_settings() {
    log "Configuring RHACS settings..."
    if ! bash "${SCRIPT_DIR}/scripts/06-configure-rhacs-settings.sh"; then
        error "RHACS configuration script failed. Installation stopped."
    fi
    success "RHACS configuration completed successfully"
}

# Deploy applications to OpenShift cluster (Step 7)
deploy_applications() {
    log "Deploying applications to OpenShift cluster..."
    if ! bash "${SCRIPT_DIR}/scripts/07-deploy-applications.sh"; then
        error "Application deployment script failed. Installation stopped."
    fi
    success "Application deployment completed successfully"
}


# Main function
main() {
    log "Starting Demo Config Setup..."
    
    # Clone the repository if running from curl
    # Check if we're running from curl by looking for the scripts directory
    if [ ! -d "scripts" ] || [ ! -f "scripts/02-rhacs-setup.sh" ]; then
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
    # Scripts listed in execution order
    for script in "01-rhacs-setup.sh" "02-compliance-operator-install.sh" "03-setup-perses-monitoring.sh" "04-setup-co-scan-schedule.sh" "05-trigger-compliance-scan.sh" "06-configure-rhacs-settings.sh" "07-deploy-applications.sh"; do
        if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
            error "Required script not found: $SCRIPT_DIR/scripts/$script"
        fi
    done
    log "✓ All required scripts found"
    
    # Run setup scripts in order
    setup_rhacs
    install_compliance_operator
    setup_perses_monitoring
    setup_compliance_scan_schedule
    trigger_compliance_scan
    configure_rhacs_settings
    deploy_applications
    
    log "========================================================="
    success "Demo Config setup completed successfully!"
    log "========================================================="
    log ""
    log "All scripts have been executed in order:"
    log "  1. RHACS secured cluster setup"
    log "  2. Red Hat Compliance Operator installation"
    log "  3. Setup Perses monitoring with RHACS metrics dashboards"
    log "  4. Compliance scan schedule setup"
    log "  5. Compliance scan trigger"
    log "  6. RHACS system configuration, exposed metrics, and additional namespaces added to system policies"
    log "  7. Application deployment"

    
    # Display RHACS access information
    log ""
    log "========================================================="
    log "RHACS ACCESS INFORMATION"
    log "========================================================="
    
    # Source bashrc to get the environment variables
    # Temporarily disable unbound variable checking to avoid errors from /etc/bashrc
    if [ -f ~/.bashrc ]; then
        set +u  # Temporarily disable unbound variable checking
        source ~/.bashrc || true
        set -u  # Re-enable unbound variable checking
    fi
    
    log "RHACS UI:     https://$ROX_ENDPOINT"
    log "User:         admin"
    
    # Try to get the admin password from the RHACS secret
    if command -v oc &>/dev/null && oc whoami &>/dev/null; then
        ADMIN_PASSWORD=$(oc get secret central-htpasswd -n tssc-acs -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
        if [ -n "$ADMIN_PASSWORD" ]; then
            log "Password:     $ADMIN_PASSWORD"
        else
            ADMIN_PASSWORD=$(oc get secret central-htpasswd -n tssc-acs -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
            log "Password:     $ADMIN_PASSWORD"
        fi
    else
        log "Password:     (Check RHACS Central secret)"
    fi
    
    log "========================================================="
}

# Run main function
main "$@"
