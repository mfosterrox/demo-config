# Demo Config - OpenShift Security Configuration

A comprehensive automation suite for configuring Red Hat Advanced Cluster Security (RHACS) and Compliance Operator on OpenShift clusters. This repository provides scripts to set up a complete security and compliance monitoring environment.

## 🚀 Quick Start

Run this single command to set up your complete security environment:

```bash
curl -fsSL https://raw.githubusercontent.com/mfosterrox/demo-config/main/install.sh | bash
```

The installation script orchestrates seven sequential scripts that configure your OpenShift cluster with:
- Red Hat Compliance Operator
- RHACS (Red Hat Advanced Cluster Security) Central and Secured Cluster Services
- Sample demo applications
- Automated compliance scanning
- RHACS configuration and metrics dashboards

## 📋 What Gets Installed

### Script 01: Compliance Operator Installation
- Installs the Red Hat Compliance Operator from the `redhat-operators` catalog
- Creates the `openshift-compliance` namespace
- Sets up OperatorGroup and Subscription
- Initializes environment variables (`SCRIPT_DIR`, `PROJECT_ROOT`, `NAMESPACE`) and saves them to `~/.bashrc`
- Verifies operator installation and readiness

### Script 02: RHACS Setup
- Ensures RHACS operator is on the `stable` channel
- Verifies Central deployment is ready
- Generates and saves critical environment variables:
  - `ROX_ENDPOINT` - Central API endpoint URL
  - `ROX_API_TOKEN` - API authentication token
  - `ADMIN_PASSWORD` - Central admin password
- Configures process baseline auto-lock on Central
- Downloads and installs `roxctl` CLI tool
- Generates init bundle for Secured Cluster
- Creates `SecuredCluster` resource with:
  - Admission control (listen mode, non-enforcing)
  - Audit log collection
  - eBPF-based collector
  - Auto-scaling scanner
  - Process baseline auto-lock enabled
- Waits for all Secured Cluster components (sensor, admission-control, collector) to be ready

### Script 03: Application Deployment
- Clones demo applications repository
- Deploys sample applications to the OpenShift cluster
- Sets up `TUTORIAL_HOME` environment variable
- Configures applications for security scanning

### Script 04: Compliance Scan Schedule Setup
- Fetches cluster ID from RHACS
- Creates compliance scan configurations for all supported profiles
- Sets up automated daily compliance scanning schedule
- Configures scan to run against the cluster

### Script 05: Compliance Scan Trigger
- Triggers compliance scans for all configured scan configurations
- Monitors scan completion status
- Provides scan results and status information

### Script 06: RHACS Configuration
- Configures RHACS system settings via API
- Exposes metrics endpoints
- Adds additional namespaces to system policies
- Customizes RHACS behavior for demo environment

### Script 07: Metrics Dashboard Setup
- Installs Cluster Observability Operator (if needed)
- Creates MonitoringStack to scrape RHACS metrics
- Sets up Prometheus data source
- Creates Grafana dashboards for visualizing RHACS metrics
- Configures OpenShift console integration

## 🏗️ Architecture

The installation creates the following components:

### Namespaces
- `openshift-compliance` - Compliance Operator and scan resources
- `tssc-acs` (default) - RHACS Central and Secured Cluster components

### RHACS Components
- **Central** - Management console and API server
- **Sensor** - Cluster monitoring component
- **Admission Controller** - Policy enforcement at admission time
- **Collector** - Per-node security data collection (DaemonSet)
- **Scanner** - Image vulnerability scanning

### Compliance Components
- Compliance Operator - Manages compliance scans
- ScanConfigurations - Automated scanning schedules
- ComplianceScan resources - Individual scan executions

## 🔧 Running Scripts Independently

Each script can be run independently, as long as script 01 has been executed first to initialize environment variables. Scripts load required variables from `~/.bashrc`.

### Prerequisites
- OpenShift cluster access with cluster admin privileges
- `oc` CLI installed and authenticated
- Script 01 must be run first to initialize environment variables

### Running Individual Scripts

```bash
# Run script 01 first (required for all other scripts)
./scripts/01-rhacs-setup.sh

# Then run any other script independently
./scripts/02-compliance-operator-install.sh
./scripts/03-configure-rhacs-settings.sh
./scripts/04-setup-co-scan-schedule.sh
./scripts/05-trigger-compliance-scan.sh
./scripts/06-deploy-applications.sh
./scripts/07-install-cert-manager.sh
./scripts/08-setup-rhacs-route-tls.sh
```

### Environment Variables

All scripts use environment variables stored in `~/.bashrc`:

- `SCRIPT_DIR` - Directory containing the scripts (set by script 01)
- `PROJECT_ROOT` - Parent directory of scripts (set by script 01)
- `NAMESPACE` - RHACS namespace (defaults to `tssc-acs`, set by script 01)
- `ROX_ENDPOINT` - RHACS Central endpoint URL (set by script 02)
- `ROX_API_TOKEN` - RHACS API authentication token (set by script 02)
- `ADMIN_PASSWORD` - RHACS admin password (set by script 02)
- `TUTORIAL_HOME` - Demo applications directory (set by script 03)

## 📊 Access Information

After installation, the script displays:

- **RHACS UI URL**: `https://<ROX_ENDPOINT>`
- **Username**: `admin`
- **Password**: Displayed from Central secret

## 🛠️ Manual Installation

If you prefer to clone and run manually:

```bash
# Clone the repository
git clone https://github.com/mfosterrox/demo-config.git
cd demo-config

# Run the main installation script
./install.sh

# Or run scripts individually
./scripts/01-compliance-operator-install.sh
./scripts/02-rhacs-setup.sh
# ... etc
```

## 🔍 Verification

After installation, verify components are running:

```bash
# Check Compliance Operator
oc get pods -n openshift-compliance

# Check RHACS Central
oc get pods -n tssc-acs

# Check Secured Cluster components
oc get pods -n tssc-acs -l app=sensor
oc get pods -n tssc-acs -l app=admission-control
oc get daemonset collector -n tssc-acs

# Check compliance scans
oc get scansettingbindings -n openshift-compliance
oc get compliancescans -n openshift-compliance
```

## 🐛 Troubleshooting

### Script Fails with "~/.bashrc not found"
Script 01 creates `~/.bashrc` if it doesn't exist. Ensure script 01 runs first.

### Missing Environment Variables
If a script fails due to missing variables, ensure script 01 has been run and check `~/.bashrc` for exported variables.

### Central Not Ready
If script 02 fails waiting for Central, check:
```bash
oc get deployment central -n tssc-acs
oc get pods -n tssc-acs -l app=central
oc describe deployment central -n tssc-acs
```

### Compliance Operator Not Installing
Check operator subscription status:
```bash
oc get subscription compliance-operator -n openshift-compliance
oc get csv -n openshift-compliance
```

## 📝 Notes

- **Idempotent**: Scripts can be run multiple times safely. They check for existing resources and skip creation if already present.
- **TLS**: Scripts do not modify TLS configuration. They use `--insecure-skip-tls-verify` flags for client connections only.
- **Namespace**: Default namespace is `tssc-acs` but can be overridden by setting `NAMESPACE` environment variable before running script 01.

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.