#!/bin/bash

# Demo Config - Simple Setup Script
# Download and run with: curl -fsSL https://raw.githubusercontent.com/your-username/demo-config/main/install.sh | bash

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

# Add to shell config
if [[ "$SHELL" == *"zsh"* ]]; then
    echo "source $aliases_file" >> "$HOME/.zshrc"
    log "Added aliases to ~/.zshrc"
elif [[ "$SHELL" == *"bash"* ]]; then
    echo "source $aliases_file" >> "$HOME/.bashrc"
    log "Added aliases to ~/.bashrc"
fi

# Run RHACS setup script (Step 1)
setup_rhacs() {
    log "Running RHACS secured cluster setup..."
    bash "${SCRIPT_DIR}/scripts/01-rhacs-setup.sh"
}

# Install Red Hat Compliance Operator (Step 2)
install_compliance_operator() {
    log "Installing Red Hat Compliance Operator..."
    bash "${SCRIPT_DIR}/scripts/02-compliance-operator-install.sh"
}

# Deploy applications to OpenShift cluster (Step 3)
deploy_applications() {
    log "Deploying applications to OpenShift cluster..."
    bash "${SCRIPT_DIR}/scripts/03-deploy-applications.sh"
}

# Setup compliance scan schedule (Step 4)
setup_compliance_scan_schedule() {
    log "Setting up compliance scan schedule..."
    bash "${SCRIPT_DIR}/scripts/04-setup-co-scan-schedule.sh"
}

# Trigger compliance scan (Step 5)
trigger_compliance_scan() {
    log "Triggering compliance scan..."
    bash "${SCRIPT_DIR}/scripts/05-trigger-compliance-scan.sh"
}

# Main function
main() {
    log "Starting Demo Config Setup..."
    
    # Clone the repository if running from curl
    if [ -z "${BASH_SOURCE[0]}" ] || [[ "${BASH_SOURCE[0]}" == *"/dev/fd/"* ]]; then
        log "Running from curl, cloning repository..."
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
    
    # Install tools
    install_tools
    
    # Setup aliases
    setup_aliases
    
    # Verify scripts exist
    for script in "01-rhacs-setup.sh" "02-compliance-operator-install.sh" "03-deploy-applications.sh" "04-setup-co-scan-schedule.sh" "05-trigger-compliance-scan.sh"; do
        if [ ! -f "$SCRIPT_DIR/scripts/$script" ]; then
            error "Required script not found: $SCRIPT_DIR/scripts/$script"
        fi
    done
    
    # Run setup scripts in order
    setup_rhacs
    install_compliance_operator
    deploy_applications
    setup_compliance_scan_schedule
    trigger_compliance_scan
    
    success "Demo Config setup completed successfully!"
    log "All scripts have been executed in order:"
    log "  1. RHACS secured cluster setup"
    log "  2. Red Hat Compliance Operator installation"
    log "  3. Application deployment"
    log "  4. Compliance scan schedule setup"
    log "  5. Compliance scan trigger"
    
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
