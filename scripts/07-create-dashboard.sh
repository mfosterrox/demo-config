#!/bin/bash
# OpenShift Console Dashboard Creation Script
# Creates a custom dashboard for RHACS metrics in OpenShift Console

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_FAILED=false

log() {
    echo -e "${GREEN}[DASHBOARD-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DASHBOARD-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[DASHBOARD-SETUP]${NC} $1"
    SCRIPT_FAILED=true
}

# Configuration
DASHBOARD_NAME="grafana-dashboard-rhacs-security"
COO_NAMESPACE="open-cluster-management-observability"
MONITORING_NAMESPACE="openshift-monitoring"

# Check prerequisites
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first."
fi

# Check if Cluster Observability Operator is installed
log "Checking for Cluster Observability Operator..."
DASHBOARD_NAMESPACE="$MONITORING_NAMESPACE"
if oc get namespace $COO_NAMESPACE &>/dev/null 2>&1; then
    if oc get operator cluster-observability-operator -n openshift-operators &>/dev/null 2>&1 || \
       oc get csv -n openshift-operators | grep -q "cluster-observability" 2>/dev/null; then
        log "Cluster Observability Operator detected, using COO namespace"
        DASHBOARD_NAMESPACE="$COO_NAMESPACE"
    fi
fi

# Check if user-workload monitoring is enabled (for standard OpenShift monitoring)
if [ "$DASHBOARD_NAMESPACE" = "$MONITORING_NAMESPACE" ]; then
log "Checking if user-workload monitoring is enabled..."
if ! oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null 2>&1; then
    warning "Cluster monitoring config not found, it may not be fully configured"
    fi
fi

# Check if we have permissions to create ConfigMaps
if ! oc auth can-i create configmaps -n $DASHBOARD_NAMESPACE &>/dev/null; then
    error "Insufficient permissions to create ConfigMaps in $DASHBOARD_NAMESPACE namespace"
fi

log "✓ Prerequisites validated"
log "Using namespace: $DASHBOARD_NAMESPACE"

# Check if dashboard already exists
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
    log "Dashboard '$DASHBOARD_NAME' already exists, updating..."
    oc delete configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE
fi

# Create the dashboard ConfigMap
log "Creating RHACS Security Dashboard..."

# Generate ConfigMap based on namespace type (following StackRox monitoring-examples/cluster-observability-operator pattern)
if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    # Cluster Observability Operator pattern (from StackRox monitoring-examples)
    log "Using Cluster Observability Operator pattern"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $DASHBOARD_NAME
  namespace: $DASHBOARD_NAMESPACE
  labels:
    grafana-custom-dashboard: "true"
  annotations:
    observability.open-cluster-management.io/dashboard-folder: "RHACS"
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
else
    # Standard OpenShift monitoring pattern
    log "Using standard OpenShift monitoring pattern"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: $DASHBOARD_NAME
  namespace: $DASHBOARD_NAMESPACE
  labels:
    grafana_dashboard: "1"
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
fi

if [ $? -eq 0 ]; then
    log "✓ RHACS Security Dashboard created successfully"
else
    error "Failed to create dashboard ConfigMap"
fi

# Verify the ConfigMap was created
if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
    log "✓ Dashboard ConfigMap verified in $DASHBOARD_NAMESPACE namespace"
    
    # Debug: Show ConfigMap details
    log "Debugging dashboard ConfigMap..."
    log "ConfigMap labels:"
    oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.labels}' 2>/dev/null | python3 -m json.tool 2>/dev/null || oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.labels}' 2>/dev/null
    echo ""
    
    if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
        log "ConfigMap annotations:"
        oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.annotations}' 2>/dev/null | python3 -m json.tool 2>/dev/null || oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.metadata.annotations}' 2>/dev/null
        echo ""
    fi
    
    # Validate JSON
    log "Validating dashboard JSON..."
    if oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.data.rhacs-security\.json}' 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
        log "✓ Dashboard JSON is valid"
    else
        warning "Dashboard JSON validation failed - JSON may be malformed"
    fi
    
    # Check monitoring configuration
    if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
        log "Checking COO Grafana configuration..."
        if oc get deployment grafana -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
            log "✓ Grafana deployment found in $DASHBOARD_NAMESPACE"
            log "Grafana pods:"
            oc get pods -n $DASHBOARD_NAMESPACE -l app=grafana 2>/dev/null || oc get pods -n $DASHBOARD_NAMESPACE | grep grafana || log "No Grafana pods found"
        else
            warning "Grafana deployment not found in $DASHBOARD_NAMESPACE namespace"
        fi
    else
        log "Checking OpenShift monitoring-plugin configuration..."
        if oc get deployment monitoring-plugin -n $DASHBOARD_NAMESPACE &>/dev/null 2>&1; then
            log "✓ monitoring-plugin deployment found (discovers dashboards for OpenShift Console)"
            log "monitoring-plugin pods:"
            oc get pods -n $DASHBOARD_NAMESPACE -l app=monitoring-plugin 2>/dev/null || oc get pods -n $DASHBOARD_NAMESPACE | grep monitoring-plugin || log "No monitoring-plugin pods found"
        else
            warning "monitoring-plugin deployment not found in $DASHBOARD_NAMESPACE namespace"
            log "This may affect dashboard discovery in OpenShift Console"
        fi
    fi
else
    error "Dashboard ConfigMap not found after creation"
fi

log "========================================================="
log "RHACS Security Dashboard Setup Complete!"
log "========================================================="
log ""
log "Dashboard ConfigMap: $DASHBOARD_NAME"
log "Namespace: $DASHBOARD_NAMESPACE"
if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log "Pattern: Cluster Observability Operator (from StackRox monitoring-examples)"
    log "Dashboard folder: RHACS"
else
    log "Pattern: Standard OpenShift Monitoring"
fi
log ""
log "The dashboard JSON includes:"
log "  - Policy Violations by Severity"
log "  - Image Vulnerabilities by Severity"
log "  - Node Vulnerabilities by Severity"
log "  - Critical Policy Violations by Namespace"
log ""
if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log "Cluster Observability Operator detected - dashboard will be automatically discovered"
    log "Access Grafana through the COO Grafana instance in namespace $COO_NAMESPACE"
else
log "IMPORTANT: OpenShift Console doesn't auto-discover custom dashboards."
log "To use this dashboard, you have two options:"
log ""
log "Option 1 - Import to Grafana (if available):"
log "  1. Get Grafana route: oc get route grafana -n openshift-monitoring"
log "  2. Login to Grafana"
log "  3. Import dashboard JSON from ConfigMap:"
log "     oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.data.rhacs-security\.json}'"
fi
log ""
log "Option 2 - Query metrics directly:"
log "  Use the Observe → Metrics page in OpenShift Console"
log "  Example queries:"
log "    sum by (severity) (rox_central_policy_violation_namespace_severity)"
log "    sum by (severity) (rox_central_image_vuln_namespace_severity)"
log ""
log "========================================================="
log "TROUBLESHOOTING: If dashboard doesn't appear in OpenShift Console"
log "========================================================="
log ""

if [ "$DASHBOARD_NAMESPACE" = "$COO_NAMESPACE" ]; then
    log "Cluster Observability Operator Dashboard Troubleshooting:"
    log ""
    log "1. Verify ConfigMap is in COO namespace with correct label:"
    log "   oc get configmap $DASHBOARD_NAME -n $COO_NAMESPACE -o yaml"
    log "   Should have label: grafana-custom-dashboard: \"true\""
    log ""
    log "2. Ensure label is present (fix if missing):"
    log "   oc label configmap $DASHBOARD_NAME -n $COO_NAMESPACE grafana-custom-dashboard=true --overwrite"
    log ""
    log "3. Add folder annotation for organization:"
    log "   oc annotate configmap $DASHBOARD_NAME -n $COO_NAMESPACE observability.open-cluster-management.io/dashboard-folder=RHACS --overwrite"
    log ""
    log "4. List all COO dashboards:"
    log "   oc get configmap -n $COO_NAMESPACE -l grafana-custom-dashboard"
    log ""
    log "5. Restart COO observability stack:"
    log "   oc rollout restart deployment grafana -n $COO_NAMESPACE"
    log "   oc rollout restart deployment observability-grafana -n $COO_NAMESPACE 2>/dev/null || true"
    log ""
    log "6. Check COO operator logs:"
    log "   oc logs -n openshift-operators -l name=cluster-observability-operator --tail=100 | grep -i dashboard"
    log ""
    log "7. Verify MultiClusterObservability CR status:"
    log "   oc get multiclusterobservability -n $COO_NAMESPACE"
    log "   oc describe multiclusterobservability -n $COO_NAMESPACE"
    log ""
    log "8. Wait 2-3 minutes after changes for COO to sync"
    log ""
    log "9. Check OpenShift Console → Observe → Dashboards"
    log "   Dashboard should appear in the dropdown list"
else
    log "Standard OpenShift Monitoring Dashboard Troubleshooting:"
    log ""
    log "1. Verify ConfigMap exists and has correct labels:"
    log "   oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o yaml"
    log "   Should have label: grafana_dashboard: \"1\""
    log ""
    log "2. Ensure label is present (fix if missing):"
    log "   oc label configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE grafana_dashboard=1 --overwrite"
    log ""
    log "3. List all dashboards monitoring-plugin can see:"
    log "   oc get configmap -n $DASHBOARD_NAMESPACE -l grafana_dashboard"
    log ""
    log "4. Restart monitoring-plugin to force dashboard reload:"
    log "   oc rollout restart deployment monitoring-plugin -n openshift-monitoring"
    log ""
    log "5. Check monitoring-plugin logs for dashboard discovery:"
    log "   oc logs -n openshift-monitoring -l app=monitoring-plugin --tail=100 | grep -i dashboard"
    log ""
    log "6. Verify dashboard JSON is valid:"
    log "   oc get configmap $DASHBOARD_NAME -n $DASHBOARD_NAMESPACE -o jsonpath='{.data.rhacs-security\.json}' | python3 -m json.tool"
    log ""
    log "7. Wait 1-2 minutes after restart for dashboard discovery"
    log ""
    log "8. Check OpenShift Console → Observe → Dashboards"
    log "   Dashboard should appear in the dropdown list"
fi

log ""
log "Run debug script for detailed analysis:"
log "   ./scripts/08-debug-dashboard.sh $DASHBOARD_NAME"
log ""

if [ "$SCRIPT_FAILED" = true ]; then
    warning "Dashboard creation script completed with errors. Review the log output for details."
else
    log "Dashboard creation script completed successfully!"
fi
log "========================================================="

