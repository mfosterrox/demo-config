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

# Reconfigure RHACS operators (cleanup existing operators)
reconfigure_rhacs() {
    log "Reconfiguring RHACS operators (cleaning up existing operators)..."
    if ! bash "${SCRIPT_DIR}/scripts/01-RHACS-reconfigure.sh"; then
        error "RHACS reconfigure script failed. Installation stopped."
    fi
    success "RHACS reconfigure completed successfully"
}


# Main function
main() {
    log "Starting Demo Config Setup..."
    
    # Clone the repository if running from curl
    # Check if we're running from curl by looking for the scripts directory
    if [ ! -d "scripts" ] || [ ! -f "scripts/01-RHACS-reconfigure.sh" ]; then
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
    if [ ! -f "$SCRIPT_DIR/scripts/01-RHACS-reconfigure.sh" ]; then
        error "Required script not found: $SCRIPT_DIR/scripts/01-RHACS-reconfigure.sh"
    fi
    log "✓ Required script found"
    
    # Run setup scripts in order
    reconfigure_rhacs
    
    log "========================================================="
    success "Demo Config setup completed successfully!"
    log "========================================================="
    log ""
    log "Scripts executed:"
    log "  - RHACS operator reconfigure (cleanup existing operators)"
    log ""
    log "Additional scripts will be added one-by-one as needed."
}

# Run main function
main "$@"
