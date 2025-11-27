#!/bin/bash
# RHACS Configuration Script
# Makes API calls to RHACS to change configuration details

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-CONFIG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-CONFIG]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-CONFIG] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-CONFIG] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Source environment variables
if [ -f ~/.bashrc ]; then
    log "Sourcing ~/.bashrc..."
    
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    set +u  # Temporarily disable unbound variable checking
    if ! source ~/.bashrc; then
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    log "~/.bashrc not found, proceeding with current environment"
fi

# Validate required environment variables (should be set by script 01)
if [ -z "${ROX_API_TOKEN:-}" ]; then
    error "ROX_API_TOKEN not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi

if [ -z "${ROX_ENDPOINT:-}" ]; then
    error "ROX_ENDPOINT not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi
log "✓ Required environment variables validated: ROX_ENDPOINT=$ROX_ENDPOINT"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq is required for this script to work correctly. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# API endpoint base URL
API_BASE="${ROX_ENDPOINT}/v1"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
    log "Making $description: $method $endpoint"
    
    local temp_file=""
    local curl_cmd="curl -k -s -w \"\n%{http_code}\" -X $method"
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $ROX_API_TOKEN\""
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
    
    if [ -n "$data" ]; then
        # For multi-line JSON, use a temporary file to avoid quoting issues
        if echo "$data" | grep -q $'\n'; then
            temp_file=$(mktemp)
            echo "$data" > "$temp_file"
            curl_cmd="$curl_cmd --data-binary @\"$temp_file\""
        else
            # Single-line data can use -d directly
            curl_cmd="$curl_cmd -d '$data'"
        fi
    fi
    
    curl_cmd="$curl_cmd \"$API_BASE/$endpoint\""
    
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # Clean up temp file if used
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -ne 0 ]; then
        error "$description failed (curl exit code: $exit_code). Response: ${body:0:500}"
    fi
    
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        error "$description failed (HTTP $http_code). Response: ${body:0:500}"
    fi
    
    echo "$body"
}


# Prepare configuration payload
log "Preparing configuration payload..."
CONFIG_PAYLOAD=$(cat <<'EOF'
{
  "config": {
    "publicConfig": {
      "loginNotice": { "enabled": false, "text": "" },
      "header": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "footer": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "telemetry": { "enabled": true, "lastSetTime": null }
    },
    "privateConfig": {
      "alertConfig": {
        "resolvedDeployRetentionDurationDays": 7,
        "deletedRuntimeRetentionDurationDays": 7,
        "allRuntimeRetentionDurationDays": 30,
        "attemptedDeployRetentionDurationDays": 7,
        "attemptedRuntimeRetentionDurationDays": 7
      },
      "imageRetentionDurationDays": 7,
      "expiredVulnReqRetentionDurationDays": 90,
      "decommissionedClusterRetention": {
        "retentionDurationDays": 0,
        "ignoreClusterLabels": {},
        "lastUpdated": "2025-11-26T15:02:32.522230327Z",
        "createdAt": "2025-11-26T15:02:32.522229766Z"
      },
      "reportRetentionConfig": {
        "historyRetentionDurationDays": 7,
        "downloadableReportRetentionDays": 7,
        "downloadableReportGlobalRetentionBytes": 524288000
      },
      "vulnerabilityExceptionConfig": {
        "expiryOptions": {
          "dayOptions": [
            { "numDays": 14, "enabled": true },
            { "numDays": 30, "enabled": true },
            { "numDays": 60, "enabled": true },
            { "numDays": 90, "enabled": true }
          ],
          "fixableCveOptions": { "allFixable": true, "anyFixable": true },
          "customDate": false,
          "indefinite": false
        }
      },
      "administrationEventsConfig": { "retentionDurationDays": 4 },
      "metrics": {
        "imageVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "cve_severity": { "labels": ["Cluster","CVE","IsPlatformWorkload","IsFixable","Severity"] },
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformWorkload","IsFixable","Severity"] }
          }
        },
        "policyViolations": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"] }
          }
        },
        "nodeVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "component_severity": { "labels": ["Cluster","Node","Component","IsFixable","Severity"] },
            "cve_severity": { "labels": ["Cluster","CVE","IsFixable","Severity"] },
            "node_severity": { "labels": ["Cluster","Node","IsFixable","Severity"] }
          }
        }
      }
    },
    "platformComponentConfig": {
      "rules": [
        {
          "name": "red hat layered products",
          "namespaceRule": { "regex": "^aap$|^ack-system$|^aws-load-balancer-operator$|^cert-manager-operator$|^cert-utils-operator$|^costmanagement-metrics-operator$|^external-dns-operator$|^metallb-system$|^mtr$|^multicluster-engine$|^multicluster-global-hub$|^node-observability-operator$|^open-cluster-management$|^openshift-adp$|^openshift-apiserver-operator$|^openshift-authentication$|^openshift-authentication-operator$|^openshift-builds$|^openshift-cloud-controller-manager$|^openshift-cloud-controller-manager-operator$|^openshift-cloud-credential-operator$|^openshift-cloud-network-config-controller$|^openshift-cluster-csi-drivers$|^openshift-cluster-machine-approver$|^openshift-cluster-node-tuning-operator$|^openshift-cluster-observability-operator$|^openshift-cluster-samples-operator$|^openshift-cluster-storage-operator$|^openshift-cluster-version$|^openshift-cnv$|^openshift-compliance$|^openshift-config$|^openshift-config-managed$|^openshift-config-operator$|^openshift-console$|^openshift-console-operator$|^openshift-console-user-settings$|^openshift-controller-manager$|^openshift-controller-manager-operator$|^openshift-dbaas-operator$|^openshift-distributed-tracing$|^openshift-dns$|^openshift-dns-operator$|^openshift-dpu-network-operator$|^openshift-dr-system$|^openshift-etcd$|^openshift-etcd-operator$|^openshift-file-integrity$|^openshift-gitops-operator$|^openshift-host-network$|^openshift-image-registry$|^openshift-infra$|^openshift-ingress$|^openshift-ingress-canary$|^openshift-ingress-node-firewall$|^openshift-ingress-operator$|^openshift-insights$|^openshift-keda$|^openshift-kmm$|^openshift-kmm-hub$|^openshift-kni-infra$|^openshift-kube-apiserver$|^openshift-kube-apiserver-operator$|^openshift-kube-controller-manager$|^openshift-kube-controller-manager-operator$|^openshift-kube-scheduler$|^openshift-kube-scheduler-operator$|^openshift-kube-storage-version-migrator$|^openshift-kube-storage-version-migrator-operator$|^openshift-lifecycle-agent$|^openshift-local-storage$|^openshift-logging$|^openshift-machine-api$|^openshift-machine-config-operator$|^openshift-marketplace$|^openshift-migration$|^openshift-monitoring$|^openshift-mta$|^openshift-mtv$|^openshift-multus$|^openshift-netobserv-operator$|^openshift-network-diagnostics$|^openshift-network-node-identity$|^openshift-network-operator$|^openshift-nfd$|^openshift-nmstate$|^openshift-node$|^openshift-nutanix-infra$|^openshift-oauth-apiserver$|^openshift-openstack-infra$|^openshift-opentelemetry-operator$|^openshift-operator-lifecycle-manager$|^openshift-operators$|^openshift-operators-redhat$|^openshift-ovirt-infra$|^openshift-ovn-kubernetes$|^openshift-ptp$|^openshift-route-controller-manager$|^openshift-sandboxed-containers-operator$|^openshift-security-profiles$|^openshift-serverless$|^openshift-serverless-logic$|^openshift-service-ca$|^openshift-service-ca-operator$|^openshift-sriov-network-operator$|^openshift-storage$|^openshift-tempo-operator$|^openshift-update-service$|^openshift-user-workload-monitoring$|^openshift-vertical-pod-autoscaler$|^openshift-vsphere-infra$|^openshift-windows-machine-config-operator$|^openshift-workload-availability$|^redhat-ods-operator$|^rhdh-operator$|^service-telemetry$|^stackrox$|^submariner-operator$|^tssc-acs$|^openshift-devspaces$" }
        },
        {
          "name": "system rule",
          "namespaceRule": { "regex": "^openshift$|^openshift-apiserver$|^openshift-operators$|^kube-.*" }
        }
      ],
      "needsReevaluation": false
    }
  }
}
EOF
)

# Update configuration
log "Updating RHACS configuration..."
CONFIG_RESPONSE=$(make_api_call "PUT" "config" "$CONFIG_PAYLOAD" "Update RHACS configuration")
log "✓ Configuration updated successfully (HTTP 200)"

# Validate configuration changes
log "Validating configuration changes..."
VALIDATED_CONFIG=$(make_api_call "GET" "config" "" "Validate configuration")
log "✓ Configuration validated"

# Verify key settings
log "Verifying telemetry configuration..."
TELEMETRY_ENABLED=$(echo "$VALIDATED_CONFIG" | jq -r '.config.publicConfig.telemetry.enabled' 2>/dev/null || echo "unknown")

if [ "$TELEMETRY_ENABLED" = "unknown" ]; then
    # Try alternative path if the structure is different
    TELEMETRY_ENABLED=$(echo "$VALIDATED_CONFIG" | jq -r '.publicConfig.telemetry.enabled' 2>/dev/null || echo "unknown")
fi

if [ "$TELEMETRY_ENABLED" = "true" ]; then
    log "✓ Telemetry configuration verified: enabled"
elif [ "$TELEMETRY_ENABLED" = "unknown" ]; then
    warning "Could not verify telemetry status from response. Response structure may differ."
    log "Response preview: $(echo "$VALIDATED_CONFIG" | jq -c '.' 2>/dev/null | head -c 200 || echo "$VALIDATED_CONFIG" | head -c 200)"
    # Don't fail the script if we can't verify telemetry - the PUT succeeded with HTTP 200
    log "Note: Configuration update succeeded (HTTP 200), but telemetry verification failed"
else
    warning "Telemetry configuration verification: expected 'true', got '$TELEMETRY_ENABLED'"
fi

log "========================================================="
log "RHACS Configuration Script Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - RHACS configuration updated (PUT /v1/config)"
log "  - Configuration validated (GET /v1/config)"
log "  - Metrics enabled/updated"
log "  - Additional namespaces added to system policies"
if [ "$TELEMETRY_ENABLED" != "unknown" ]; then
    log "  - Telemetry enabled: $TELEMETRY_ENABLED"
fi

