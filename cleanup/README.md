# Cleanup Scripts

This directory contains scripts to completely remove all resources created by the installation scripts in this repository.

## 📋 Overview

The cleanup script (`cleanup-all.sh`) performs a comprehensive removal of all components installed by the demo-config installation scripts, including:

- **RHACS (Red Hat Advanced Cluster Security)** operator and all custom resources
- **Cluster Observability Operator** and monitoring resources
- **Compliance Operator** and all compliance scan resources
- **Demo applications** deployed with the `demo=roadshow` label
- **Namespaces** created during installation
- **Operator subscriptions** and **OperatorGroups**

## 🚀 Quick Start

To remove all installed resources:

```bash
cd cleanup
./cleanup-all.sh
```

## ⚠️ Prerequisites

Before running the cleanup script, ensure you have:

1. **OpenShift CLI (`oc`) installed** and authenticated
   ```bash
   oc login <your-cluster-url>
   ```

2. **Cluster admin privileges** - The script requires cluster admin permissions to delete operators and namespaces
   ```bash
   oc auth can-i delete subscriptions --all-namespaces
   ```

3. **Access to the cluster** - Verify connectivity:
   ```bash
   oc whoami
   ```

## 🔍 What Gets Deleted

### Step 1: Custom Resources

The script deletes all custom resources in the following order:

#### RHACS Resources
- `Central` custom resources (`central.platform.stackrox.io`)
- `SecuredCluster` custom resources (`securedcluster.platform.stackrox.io`)
- Monitoring resources:
  - `MonitoringStack` (rhacs-monitoring-stack)
  - `ScrapeConfig` (rhacs-scrape-config)
  - `Prometheus` (rhacs-prometheus-server)
  - `PrometheusRule` (rhacs-health-alerts)
- Perses resources:
  - `Datasource` (rhacs-datasource)
  - `Dashboard` (rhacs-dashboard)
  - `UIPlugin` (rhacs-perses-ui-plugin) - cluster-scoped
- RHACS declarative configuration ConfigMap
- TLS certificates and secrets created for RHACS

#### Compliance Operator Resources
- `ScanConfiguration` resources
- `ComplianceScan` resources
- `ProfileBundle` resources (if present)

### Step 2: Operator Subscriptions and OperatorGroups

The script removes:
- RHACS operator subscription (`rhacs-operator`)
- Cluster Observability Operator subscription (`cluster-observability-operator`)
- Compliance Operator subscription (`compliance-operator`)
- All associated `OperatorGroup` resources

**Note:** Cert-Manager operator is **NOT** deleted as it may be used by other cluster components.

### Step 3: Demo Applications

All resources labeled with `demo=roadshow` are deleted, including:
- Deployments
- Services
- ConfigMaps
- Secrets
- Any other resources with the demo label

### Step 4: Namespaces

The following namespaces are deleted:
- `rhacs-operator` - RHACS operator and resources
- `openshift-cluster-observability-operator` - Cluster Observability Operator
- `openshift-compliance` - Compliance Operator and scans

**Note:** The `cert-manager-operator` namespace is **NOT** deleted as cert-manager may be used by other components.

### Step 5: Verification

The script verifies that:
- All namespaces are deleted or terminating
- No RHACS custom resources remain
- No monitoring resources remain
- No compliance resources remain
- No operator subscriptions remain (except cert-manager)
- No OperatorGroups remain
- No demo applications remain

## 🔧 Force Deletion

The script includes robust namespace force deletion capabilities for namespaces that are stuck in `Terminating` state or have finalizers. It attempts multiple methods:

1. Standard namespace deletion
2. Merge patch to remove finalizers (metadata)
3. Merge patch to remove finalizers (spec)
4. JSON patch to remove finalizers
5. Direct JSON edit with `jq` (if available)
6. Direct API call via `oc proxy` (most robust)

## ⏱️ Execution Time

The cleanup script typically completes in **2-5 minutes**, depending on:
- Number of resources to delete
- Cluster performance
- Whether namespaces need force deletion

Some resources may continue terminating after the script completes. This is normal and expected.

## 📊 Script Output

The script provides color-coded output:
- **Green** - Successful operations and information
- **Yellow** - Warnings (non-fatal)
- **Red** - Errors (fatal)

Example output:
```
[CLEANUP] =========================================================
[CLEANUP] Complete Cleanup Script
[CLEANUP] =========================================================
[CLEANUP] Validating prerequisites...
[CLEANUP] ✓ OpenShift CLI connected as: admin
[CLEANUP] ✓ Cluster admin privileges confirmed
...
```

## 🛡️ What is NOT Deleted

The following resources are **intentionally preserved**:

- **Cert-Manager Operator** - May be used by other cluster components
- **cert-manager-operator namespace** - Preserved for the same reason
- **Resources without the `demo=roadshow` label** - Only demo applications are removed
- **Other cluster resources** - Only resources created by the installation scripts are removed

## 🔍 Verification Commands

After running the cleanup script, you can verify deletion manually:

```bash
# Check for remaining namespaces
oc get namespaces | grep -E '(rhacs-operator|openshift-cluster-observability|openshift-compliance)'

# Check for remaining RHACS resources
oc get central,securedcluster --all-namespaces

# Check for remaining operator subscriptions
oc get subscription --all-namespaces | grep -E '(rhacs|observability|compliance)'

# Check for remaining OperatorGroups
oc get operatorgroup --all-namespaces | grep -E '(rhacs|observability|compliance)'

# Check for remaining demo applications
oc get deployments -l demo=roadshow -A
```

## 🐛 Troubleshooting

### Namespace Stuck in Terminating State

If a namespace remains in `Terminating` state after the script completes:

1. **Wait a few minutes** - Namespace deletion can take time
2. **Check for remaining resources**:
   ```bash
   oc get all -n <namespace>
   oc get pvc -n <namespace>
   ```
3. **Manually force delete** (if needed):
   ```bash
   oc get namespace <namespace> -o json | jq '.spec.finalizers = []' | oc replace --raw /api/v1/namespaces/<namespace>/finalize -f -
   ```

### Resources Not Deleting

If custom resources are not deleting:

1. **Check operator status** - Operators may be preventing deletion:
   ```bash
   oc get pods -n <operator-namespace>
   ```
2. **Delete operator first** - Ensure the operator subscription is deleted
3. **Check finalizers**:
   ```bash
   oc get <resource-type> <resource-name> -n <namespace> -o jsonpath='{.metadata.finalizers}'
   ```

### Permission Errors

If you encounter permission errors:

1. **Verify cluster admin access**:
   ```bash
   oc auth can-i delete subscriptions --all-namespaces
   ```
2. **Check current user**:
   ```bash
   oc whoami
   ```
3. **Re-authenticate** if needed:
   ```bash
   oc login <cluster-url>
   ```

### Script Fails Mid-Execution

If the script fails partway through:

1. **Check error message** - The script shows the exact line where it failed
2. **Manually delete remaining resources** using the verification commands above
3. **Re-run the script** - It's idempotent and will skip already-deleted resources

## 🔄 Re-running the Script

The cleanup script is **idempotent** - it can be run multiple times safely. It checks for resource existence before attempting deletion, so re-running will:
- Skip resources that don't exist
- Continue with remaining resources
- Complete successfully even if some resources were already deleted

## 📝 Notes

- **Non-destructive**: The script only deletes resources created by the installation scripts. Other cluster resources are unaffected.
- **Graceful handling**: The script handles missing resources gracefully and continues execution.
- **Finalizers**: The script includes robust handling for resources with finalizers that may delay deletion.
- **Timeouts**: Resource deletions have 60-120 second timeouts to prevent hanging.

## 🔗 Related Documentation

- [Main README](../README.md) - Installation and setup instructions
- [Installation Scripts](../scripts/) - Scripts that create the resources this cleanup removes

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](../LICENSE) for details.

