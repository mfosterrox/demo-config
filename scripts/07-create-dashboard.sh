#!/bin/bash
# OpenShift Console Dashboard Creation Script
# Creates a custom dashboard for RHACS metrics in OpenShift Console

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DASHBOARD-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DASHBOARD-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[DASHBOARD-SETUP]${NC} $1"
    exit 1
}

# Configuration
DASHBOARD_NAMESPACE="openshift-config-managed"
DASHBOARD_NAME="rhacs-security-dashboard"

# Check prerequisites
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Check if we have permissions to create ConfigMaps in openshift-config-managed
if ! oc auth can-i create configmaps -n $DASHBOARD_NAMESPACE &>/dev/null; then
    error "Insufficient permissions to create ConfigMaps in $DASHBOARD_NAMESPACE namespace"
fi

log "✓ Prerequisites validated"

# Check if dashboard already exists
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
    log "Dashboard '$DASHBOARD_NAME' already exists, updating..."
    oc delete configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE
fi

# Create the dashboard ConfigMap
log "Creating RHACS Security Dashboard..."

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: rhacs-security-dashboard
  namespace: openshift-config-managed
  labels:
    console.openshift.io/dashboard: "true"
data:
  rhacs-security.json: |
    {
      "annotations": {
        "list": []
      },
      "editable": true,
      "gnetId": null,
      "graphTooltip": 0,
      "hideControls": false,
      "id": null,
      "links": [],
      "refresh": "30s",
      "rows": [
        {
          "collapse": false,
          "height": "250px",
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "prometheus",
              "fill": 1,
              "fillGradient": 0,
              "gridPos": {
                "h": 8,
                "w": 12,
                "x": 0,
                "y": 0
              },
              "id": 1,
              "legend": {
                "alignAsTable": true,
                "avg": false,
                "current": true,
                "max": false,
                "min": false,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 2,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": true,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum by (severity) (rox_central_policy_violation_namespace_severity)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{severity}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeRegions": [],
              "timeShift": null,
              "title": "Policy Violations by Severity",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "format": "short",
                  "label": "Violations",
                  "logBase": 1,
                  "max": null,
                  "min": "0",
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": false
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "prometheus",
              "fill": 1,
              "fillGradient": 0,
              "gridPos": {
                "h": 8,
                "w": 12,
                "x": 12,
                "y": 0
              },
              "id": 2,
              "legend": {
                "alignAsTable": true,
                "avg": false,
                "current": true,
                "max": false,
                "min": false,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 2,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": true,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum by (severity) (rox_central_image_vuln_namespace_severity)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{severity}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeRegions": [],
              "timeShift": null,
              "title": "Image Vulnerabilities by Severity",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "format": "short",
                  "label": "Vulnerabilities",
                  "logBase": 1,
                  "max": null,
                  "min": "0",
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": false
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "repeat": null,
          "repeatIteration": null,
          "repeatRowId": null,
          "showTitle": false,
          "title": "Security Overview",
          "titleSize": "h6"
        },
        {
          "collapse": false,
          "height": "250px",
          "panels": [
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "prometheus",
              "fill": 1,
              "fillGradient": 0,
              "gridPos": {
                "h": 8,
                "w": 12,
                "x": 0,
                "y": 8
              },
              "id": 3,
              "legend": {
                "alignAsTable": true,
                "avg": false,
                "current": true,
                "max": false,
                "min": false,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 2,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": true,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum by (severity) (rox_central_node_vuln_node_severity)",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{severity}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeRegions": [],
              "timeShift": null,
              "title": "Node Vulnerabilities by Severity",
              "tooltip": {
                "shared": true,
                "sort": 0,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "format": "short",
                  "label": "Vulnerabilities",
                  "logBase": 1,
                  "max": null,
                  "min": "0",
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": false
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            },
            {
              "aliasColors": {},
              "bars": false,
              "dashLength": 10,
              "dashes": false,
              "datasource": "prometheus",
              "fill": 1,
              "fillGradient": 0,
              "gridPos": {
                "h": 8,
                "w": 12,
                "x": 12,
                "y": 8
              },
              "id": 4,
              "legend": {
                "alignAsTable": true,
                "avg": false,
                "current": true,
                "max": false,
                "min": false,
                "rightSide": true,
                "show": true,
                "total": false,
                "values": true
              },
              "lines": true,
              "linewidth": 1,
              "nullPointMode": "null",
              "percentage": false,
              "pointradius": 2,
              "points": false,
              "renderer": "flot",
              "seriesOverrides": [],
              "spaceLength": 10,
              "stack": false,
              "steppedLine": false,
              "targets": [
                {
                  "expr": "sum by (namespace) (rox_central_policy_violation_namespace_severity{severity=\"CRITICAL\"})",
                  "format": "time_series",
                  "intervalFactor": 1,
                  "legendFormat": "{{namespace}}",
                  "refId": "A"
                }
              ],
              "thresholds": [],
              "timeFrom": null,
              "timeRegions": [],
              "timeShift": null,
              "title": "Critical Policy Violations by Namespace",
              "tooltip": {
                "shared": true,
                "sort": 2,
                "value_type": "individual"
              },
              "type": "graph",
              "xaxis": {
                "buckets": null,
                "mode": "time",
                "name": null,
                "show": true,
                "values": []
              },
              "yaxes": [
                {
                  "format": "short",
                  "label": "Critical Violations",
                  "logBase": 1,
                  "max": null,
                  "min": "0",
                  "show": true
                },
                {
                  "format": "short",
                  "label": null,
                  "logBase": 1,
                  "max": null,
                  "min": null,
                  "show": false
                }
              ],
              "yaxis": {
                "align": false,
                "alignLevel": null
              }
            }
          ],
          "repeat": null,
          "repeatIteration": null,
          "repeatRowId": null,
          "showTitle": false,
          "title": "Detailed Metrics",
          "titleSize": "h6"
        }
      ],
      "schemaVersion": 16,
      "style": "dark",
      "tags": ["rhacs", "security"],
      "templating": {
        "list": []
      },
      "time": {
        "from": "now-1h",
        "to": "now"
      },
      "timepicker": {
        "refresh_intervals": ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"],
        "time_options": ["5m", "15m", "1h", "6h", "12h", "24h", "2d", "7d", "30d"]
      },
      "timezone": "browser",
      "title": "RHACS Security Dashboard",
      "uid": "rhacs-security",
      "version": 1
    }
EOF

if [ $? -eq 0 ]; then
    log "✓ RHACS Security Dashboard created successfully"
else
    error "Failed to create dashboard ConfigMap"
fi

# Verify the ConfigMap was created
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
    log "✓ Dashboard ConfigMap verified in $DASHBOARD_NAMESPACE namespace"
else
    error "Dashboard ConfigMap not found after creation"
fi

log "========================================================="
log "RHACS Security Dashboard Setup Complete!"
log "========================================================="
log ""
log "Dashboard Name: RHACS Security Dashboard"
log "Location: OpenShift Console → Observe → Dashboards"
log ""
log "The dashboard includes:"
log "  - Policy Violations by Severity"
log "  - Image Vulnerabilities by Severity"
log "  - Node Vulnerabilities by Severity"
log "  - Critical Policy Violations by Namespace"
log ""
log "To access:"
log "  1. Log into OpenShift Console"
log "  2. Navigate to Observe → Dashboards"
log "  3. Select 'RHACS Security Dashboard' from the dropdown"
log "========================================================="

