#!/bin/bash

# Demo Config - Simple Setup Script
# Download and run with: curl -fsSL https://raw.githubusercontent.com/mfosterrox/demo-config/main/install.sh | bash

set -e

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
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Setup SSL certificates (Step 1)
setup_ssl() {
    log "Setting up SSL certificates..."
    bash "${SCRIPT_DIR}/scripts/01-setup-ssl.sh"
}

# Run RHACS setup script (Step 2)
setup_rhacs() {
    log "Running RHACS secured cluster setup..."
    bash "${SCRIPT_DIR}/scripts/02-rhacs-setup.sh"
}

# Install Red Hat Compliance Operator (Step 3)
install_compliance_operator() {
    log "Installing Red Hat Compliance Operator..."
    bash "${SCRIPT_DIR}/scripts/03-compliance-operator-install.sh"
}

# Deploy applications to OpenShift cluster (Step 4)
deploy_applications() {
    log "Deploying applications to OpenShift cluster..."
    bash "${SCRIPT_DIR}/scripts/04-deploy-applications.sh"
}

# Setup compliance scan schedule (Step 5)
setup_compliance_scan_schedule() {
    log "Setting up compliance scan schedule..."
    bash "${SCRIPT_DIR}/scripts/05-setup-co-scan-schedule.sh"
}

# Trigger compliance scan (Step 6)
trigger_compliance_scan() {
    log "Triggering compliance scan..."
    bash "${SCRIPT_DIR}/scripts/06-trigger-compliance-scan.sh"
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
    
    # Verify scripts exist
    for script in "01-setup-ssl.sh" "02-rhacs-setup.sh" "03-compliance-operator-install.sh" "04-deploy-applications.sh" "05-setup-co-scan-schedule.sh" "06-trigger-compliance-scan.sh"; do
        if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
            error "Required script not found: $SCRIPT_DIR/scripts/$script"
        fi
    done
    
    # Run setup scripts in order
    setup_ssl
    setup_rhacs
    install_compliance_operator
    deploy_applications
    setup_compliance_scan_schedule
    trigger_compliance_scan
    
    success "Demo Config setup completed successfully!"
    log "All scripts have been executed in order:"
    log "  1. SSL certificate setup"
    log "  2. RHACS secured cluster setup"
    log "  3. Red Hat Compliance Operator installation"
    log "  4. Application deployment"
    log "  5. Compliance scan schedule setup"
    log "  6. Compliance scan trigger"
    
    # Display RHACS access information
    log ""
    log "========================================================="
    log "RHACS ACCESS INFORMATION"
    log "========================================================="
    
    # Source bashrc to get the environment variables
    if [ -f ~/.bashrc ]; then
        source ~/.bashrc
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