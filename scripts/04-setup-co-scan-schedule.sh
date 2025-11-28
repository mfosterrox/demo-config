#!/bin/bash
# Application Setup API Script for RHACS
# Fetches cluster ID and creates compliance scan configuration

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[API-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[API-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[API-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[API-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Source environment variables
if [ -f ~/.bashrc ]; then
    # Clean up malformed source commands in bashrc before sourcing
    if grep -q "^source $" ~/.bashrc; then
        log "Cleaning up malformed source commands in ~/.bashrc..."
        sed -i '/^source $/d' ~/.bashrc
    fi
    
    # Source bashrc with error handling
    set +u  # Temporarily disable unbound variable checking
    if ! source ~/.bashrc; then
        warning "Error loading ~/.bashrc, proceeding with current environment"
    fi
    set -u  # Re-enable unbound variable checking
else
    log "~/.bashrc not found, proceeding with current environment"
fi

# Validate required environment variables (should be set by script 01)
if [ -z "$ROX_ENDPOINT" ]; then
    error "ROX_ENDPOINT not set. Please run script 01-rhacs-setup.sh first to generate required variables."
fi
if [ -z "$ROX_API_TOKEN" ]; then
    error "ROX_API_TOKEN not set. Please run script 01-rhacs-setup.sh first to generate required variables."
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
        error "jq not found and cannot be installed automatically. Please install jq manually."
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

# Fetch cluster ID
log "Fetching cluster ID for 'production' cluster..."
CLUSTER_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v1/clusters" 2>&1)
CLUSTER_CURL_EXIT_CODE=$?

if [ $CLUSTER_CURL_EXIT_CODE -ne 0 ]; then
    error "Cluster API request failed with exit code $CLUSTER_CURL_EXIT_CODE. Response: $CLUSTER_RESPONSE"
fi

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Extract cluster ID
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[0].id')
if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
    error "Failed to extract cluster ID. Response: ${CLUSTER_RESPONSE:0:300}"
fi
log "✓ Cluster ID: $PRODUCTION_CLUSTER_ID"

# Check if Compliance Operator ProfileBundles are ready
# This is critical - scans cannot be created until ProfileBundles are processed
if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    log "Checking Compliance Operator ProfileBundle status..."
    log "ProfileBundles must be ready before creating scan configurations..."
    
    PROFILEBUNDLE_WAIT_TIMEOUT=600  # 10 minutes max wait
    PROFILEBUNDLE_WAIT_INTERVAL=10  # Check every 10 seconds
    PROFILEBUNDLE_ELAPSED=0
    PROFILEBUNDLES_READY=false
    
    # Required ProfileBundles for the profiles we're using
    REQUIRED_BUNDLES=("ocp4" "rhcos4")
    
    while [ $PROFILEBUNDLE_ELAPSED -lt $PROFILEBUNDLE_WAIT_TIMEOUT ]; do
        ALL_READY=true
        BUNDLE_STATUS=""
        
        for bundle in "${REQUIRED_BUNDLES[@]}"; do
            # Check multiple status fields - different versions use different fields
            BUNDLE_PHASE=$(oc get profilebundle "$bundle" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")
            BUNDLE_DATASTREAM=$(oc get profilebundle "$bundle" -n openshift-compliance -o jsonpath='{.status.dataStreamStatus}' 2>/dev/null || echo "")
            
            if [ "$BUNDLE_PHASE" = "NOT_FOUND" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: Not found\n"
                ALL_READY=false
            elif [ "$BUNDLE_PHASE" = "Ready" ] || [ "$BUNDLE_PHASE" = "READY" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ✓ Ready\n"
            elif [ -n "$BUNDLE_DATASTREAM" ] && [ "$BUNDLE_DATASTREAM" = "Valid" ] || [ "$BUNDLE_DATASTREAM" = "VALID" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ✓ Ready (dataStream: Valid)\n"
            else
                STATUS_DISPLAY="${BUNDLE_PHASE:-Unknown}"
                if [ -n "$BUNDLE_DATASTREAM" ] && [ "$BUNDLE_DATASTREAM" != "Valid" ]; then
                    STATUS_DISPLAY="${STATUS_DISPLAY} (dataStream: ${BUNDLE_DATASTREAM})"
                fi
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ⏳ Processing ($STATUS_DISPLAY)\n"
                ALL_READY=false
            fi
        done
        
        if [ "$ALL_READY" = true ]; then
            PROFILEBUNDLES_READY=true
            log "✓ All ProfileBundles are ready:"
            echo -e "$BUNDLE_STATUS"
            break
        else
            if [ $((PROFILEBUNDLE_ELAPSED % 30)) -eq 0 ]; then
                log "Waiting for ProfileBundles to be ready... (${PROFILEBUNDLE_ELAPSED}s/${PROFILEBUNDLE_WAIT_TIMEOUT}s)"
                echo -e "$BUNDLE_STATUS"
            fi
        fi
        
        sleep $PROFILEBUNDLE_WAIT_INTERVAL
        PROFILEBUNDLE_ELAPSED=$((PROFILEBUNDLE_ELAPSED + PROFILEBUNDLE_WAIT_INTERVAL))
    done
    
    if [ "$PROFILEBUNDLES_READY" = false ]; then
        warning "ProfileBundles did not become ready within ${PROFILEBUNDLE_WAIT_TIMEOUT}s timeout"
        log "Current ProfileBundle status:"
        echo -e "$BUNDLE_STATUS"
        log ""
        log "This may indicate:"
        log "  1. Compliance Operator is still installing/processing"
        log "  2. ProfileBundles are stuck in processing state"
        log ""
        log "Troubleshooting steps:"
        log "  1. Check Compliance Operator pods: oc get pods -n openshift-compliance"
        log "  2. Check ProfileBundle status: oc get profilebundle -n openshift-compliance"
        log "  3. Check ProfileBundle details: oc describe profilebundle ocp4 -n openshift-compliance"
        log "  4. Check operator logs: oc logs -n openshift-compliance -l name=compliance-operator"
        log ""
        warning "Attempting to create scan configuration anyway..."
        warning "If it fails with 'ProfileBundle still being processed', wait and retry later"
    fi
else
    warning "OpenShift CLI (oc) not available - cannot check ProfileBundle status"
    warning "If scan creation fails with 'ProfileBundle still being processed', ensure ProfileBundles are ready"
fi

log ""

# Check if acs-catch-all scan configuration already exists
log "Checking if 'acs-catch-all' scan configuration already exists..."
EXISTING_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)

CONFIG_CURL_EXIT_CODE=$?
if [ $CONFIG_CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch existing scan configurations (exit code: $CONFIG_CURL_EXIT_CODE). Response: ${EXISTING_CONFIGS:0:300}"
fi

if [ -z "$EXISTING_CONFIGS" ]; then
    error "Empty response from scan configurations API"
fi

if ! echo "$EXISTING_CONFIGS" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from scan configurations API. Response: ${EXISTING_CONFIGS:0:300}"
fi

EXISTING_SCAN=$(echo "$EXISTING_CONFIGS" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_SCAN" ] && [ "$EXISTING_SCAN" != "null" ]; then
        log "✓ Scan configuration 'acs-catch-all' already exists (ID: $EXISTING_SCAN)"
        log "Skipping creation..."
        SCAN_CONFIG_ID="$EXISTING_SCAN"
        SKIP_CREATION=true
    else
        log "Scan configuration 'acs-catch-all' not found, creating new configuration..."
    SKIP_CREATION=false
fi

# Create compliance scan configuration (only if it doesn't exist)
if [ "$SKIP_CREATION" = "false" ]; then
    log "Creating compliance scan configuration 'acs-catch-all'..."
    SCAN_CONFIG_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X POST \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-raw "{
        \"scanName\": \"acs-catch-all\",
        \"scanConfig\": {
            \"oneTimeScan\": false,
            \"profiles\": [
                \"ocp4-cis\",
                \"ocp4-cis-node\",
                \"ocp4-e8\",
                \"ocp4-high\",
                \"ocp4-high-node\",
                \"ocp4-nerc-cip\",
                \"ocp4-nerc-cip-node\",
                \"ocp4-pci-dss\",
                \"ocp4-pci-dss-node\",
                \"ocp4-stig\",
                \"ocp4-stig-node\"
            ],
            \"scanSchedule\": {
                \"intervalType\": \"DAILY\",
                \"hour\": 12,
                \"minute\": 0
            },
            \"description\": \"Daily compliance scan for all profiles\"
        },
        \"clusters\": [
            \"$PRODUCTION_CLUSTER_ID\"
        ]
    }" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
    SCAN_CREATE_EXIT_CODE=$?

    if [ $SCAN_CREATE_EXIT_CODE -ne 0 ]; then
        error "Failed to create compliance scan configuration (exit code: $SCAN_CREATE_EXIT_CODE). Response: ${SCAN_CONFIG_RESPONSE:0:300}"
    fi

    if [ -z "$SCAN_CONFIG_RESPONSE" ]; then
        error "Empty response from scan configuration creation API"
    fi

    # Check for ProfileBundle processing error
    if echo "$SCAN_CONFIG_RESPONSE" | grep -qi "ProfileBundle.*still being processed"; then
        warning "Scan creation failed: ProfileBundle is still being processed"
        log ""
        log "This means the Compliance Operator is still processing profile bundles."
        log "Please wait for ProfileBundles to be ready and retry."
        log ""
        log "To check ProfileBundle status:"
        log "  oc get profilebundle -n openshift-compliance"
        log "  oc describe profilebundle ocp4 -n openshift-compliance"
        log ""
        log "Wait for dataStreamStatus to show 'Valid' before retrying."
        log ""
        error "Cannot create scan: ProfileBundles are still being processed. Wait and retry."
    fi

    if ! echo "$SCAN_CONFIG_RESPONSE" | jq . >/dev/null 2>&1; then
        # Check if it's an error message about ProfileBundle
        if echo "$SCAN_CONFIG_RESPONSE" | grep -qi "ProfileBundle"; then
            warning "Scan creation failed with ProfileBundle-related error:"
            echo "$SCAN_CONFIG_RESPONSE" | head -20
            log ""
            log "Check ProfileBundle status: oc get profilebundle -n openshift-compliance"
            error "ProfileBundle error detected. See above for details."
        else
            error "Invalid JSON response from scan configuration creation API. Response: ${SCAN_CONFIG_RESPONSE:0:300}"
        fi
    fi

        log "✓ Compliance scan configuration created successfully"
        
        # Get the scan configuration ID from the response
    SCAN_CONFIG_ID=$(echo "$SCAN_CONFIG_RESPONSE" | jq -r '.id')
        if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
            log "Could not extract scan configuration ID from response, trying to get it from configurations list..."
            
            # Get scan configurations to find our configuration
            CONFIGS_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
                -H "Authorization: Bearer $ROX_API_TOKEN" \
                -H "Content-Type: application/json" \
                "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
        CONFIGS_EXIT_CODE=$?
    
        if [ $CONFIGS_EXIT_CODE -ne 0 ]; then
            error "Failed to get scan configurations list (exit code: $CONFIGS_EXIT_CODE). Response: ${CONFIGS_RESPONSE:0:300}"
        fi

        SCAN_CONFIG_ID=$(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id')
        if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
            error "Could not find 'acs-catch-all' configuration in the list. Available configurations: $(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[] | .scanName' 2>/dev/null | tr '\n' ' ' || echo "none")"
        else
            log "✓ Found scan configuration ID: $SCAN_CONFIG_ID"
        fi
    else
        log "✓ Scan configuration ID: $SCAN_CONFIG_ID"
    fi
fi

    log "Compliance scan schedule setup completed successfully!"
log "Scan configuration ID: $SCAN_CONFIG_ID"
log "Note: Run script 05-trigger-compliance-scan.sh to trigger an immediate scan"
log ""

# Diagnostic: Check if compliance scan results are syncing properly
log "========================================================="
log "Diagnosing compliance scan results sync..."
log "========================================================="

# Get namespace from environment or default
NAMESPACE="${NAMESPACE:-tssc-acs}"

# Check scan configuration status
log "Checking scan configuration status..."
CURRENT_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)

if [ -n "$CURRENT_CONFIGS" ] && echo "$CURRENT_CONFIGS" | jq . >/dev/null 2>&1; then
    LAST_STATUS=$(echo "$CURRENT_CONFIGS" | jq -r ".configurations[] | select(.id == \"$SCAN_CONFIG_ID\") | .lastScanStatus // \"UNKNOWN\"" 2>/dev/null)
    LAST_SCANNED=$(echo "$CURRENT_CONFIGS" | jq -r ".configurations[] | select(.id == \"$SCAN_CONFIG_ID\") | .lastScanned // \"Never\"" 2>/dev/null)
    
    if [ -n "$LAST_STATUS" ] && [ "$LAST_STATUS" != "null" ]; then
        log "  Scan Status: $LAST_STATUS"
        log "  Last Scanned: $LAST_SCANNED"
    fi
fi

# Check if results are available in RHACS
log "Checking if scan results are available in RHACS..."
SCAN_RESULTS=$(curl -k -s --connect-timeout 15 --max-time 45 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/results" 2>&1)

RESULTS_AVAILABLE=false
if [ -n "$SCAN_RESULTS" ] && echo "$SCAN_RESULTS" | jq . >/dev/null 2>&1; then
    RESULT_COUNT=$(echo "$SCAN_RESULTS" | jq '.results | length' 2>/dev/null || echo "0")
    if [ "$RESULT_COUNT" -gt 0 ]; then
        RESULTS_AVAILABLE=true
        log "  ✓ Found $RESULT_COUNT scan result(s) in RHACS"
    else
        log "  ⚠ No scan results found in RHACS API"
    fi
else
    log "  ⚠ Could not check scan results API"
fi

# Check Compliance Operator status if oc is available
if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    log "Checking Compliance Operator scan status..."
    
    CHECK_RESULTS=$(oc get compliancecheckresult -A 2>/dev/null | grep -v NAME | wc -l || echo "0")
    if [ "$CHECK_RESULTS" -gt 0 ]; then
        log "  ✓ Found $CHECK_RESULTS ComplianceCheckResult resources"
        CO_HAS_RESULTS=true
    else
        log "  ⚠ No ComplianceCheckResult resources found"
        CO_HAS_RESULTS=false
    fi
    
    # Check sensor status
    log "Checking RHACS sensor status..."
    SENSOR_PODS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=sensor 2>/dev/null | grep -v NAME | wc -l || echo "0")
    if [ "$SENSOR_PODS" -gt 0 ]; then
        READY_PODS=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/component=sensor -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c "true" || echo "0")
        log "  Sensor pods: $READY_PODS/$SENSOR_PODS ready"
    else
        log "  ⚠ No sensor pods found in namespace $NAMESPACE"
    fi
    
    # Diagnose sync issue
    if [ "$CO_HAS_RESULTS" = true ] && [ "$RESULTS_AVAILABLE" = false ]; then
        log ""
        warning "ISSUE DETECTED: Compliance Operator has results but RHACS doesn't show them"
        warning "This indicates a sync issue between Compliance Operator and RHACS"
        log ""
        log "NOTE: Since Compliance Operator is installed before RHACS (script 01),"
        log "      sensor restart should not be needed. However, if results still"
        log "      don't appear, try restarting the sensor:"
        log "  oc delete pods -l app.kubernetes.io/component=sensor -n $NAMESPACE"
        log ""
        log "After restarting (if needed), wait 1-2 minutes and check:"
        log "  - RHACS UI: Compliance → Coverage tab"
        log "  - Select your scan configuration to view results"
    elif [ -n "$LAST_STATUS" ] && [ "$LAST_STATUS" = "COMPLETED" ] && [ "$RESULTS_AVAILABLE" = false ]; then
        log ""
        warning "ISSUE DETECTED: Scan shows COMPLETED but results not available in RHACS"
        warning "The scan completed and sent a report, but results haven't synced to RHACS yet"
        log ""
        log "NOTE: Since Compliance Operator is installed before RHACS (script 01),"
        log "      this should be rare. Wait a few minutes for automatic sync."
        log ""
        log "If results still don't appear after waiting, restart the sensor:"
        log "  oc delete pods -l app.kubernetes.io/component=sensor -n $NAMESPACE"
        log ""
        log "Then check the Compliance → Coverage tab."
    elif [ "$RESULTS_AVAILABLE" = true ]; then
        log ""
        log "✓ Scan results are available in RHACS"
        log "  View them in: Compliance → Coverage tab"
    else
        log ""
        log "No scan results found yet. This is normal if:"
        log "  - No scans have been run yet (run script 05-trigger-compliance-scan.sh)"
        log "  - Scan is still in progress"
        log ""
        log "If scan completed but results don't appear, restart the sensor:"
        log "  oc delete pods -l app.kubernetes.io/component=sensor -n $NAMESPACE"
    fi
else
    log "  ⚠ OpenShift CLI (oc) not available - skipping Compliance Operator checks"
    log ""
    log "If scan results don't appear in the dashboard after completion:"
    log "  1. Restart RHACS sensor: oc delete pods -l app.kubernetes.io/component=sensor -n $NAMESPACE"
    log "  2. Wait 1-2 minutes"
    log "  3. Check Compliance → Coverage tab in RHACS UI"
fi

log ""