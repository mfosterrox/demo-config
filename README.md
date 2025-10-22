# Demo Config

A simple, single-command environment setup script that installs essential development tools and creates a demo project.

## 🚀 Quick Start

Run this single command to set up your development environment:

```bash
curl -fsSL https://raw.githubusercontent.com/mfosterrox/demo-config/main/install.sh | bash
```

That's it! The script will:

- Install and configure Red Hat Advanced Cluster Security (RHACS) Central and Sensor
- Install the Red Hat Compliance Operator on your OpenShift cluster
- Deploy sample demo applications to the cluster
- Configure a daily compliance scan schedule for the cluster (covering all supported profiles)
- Trigger compliance scans and monitor their completion
- Set up command-line aliases and configure Git with sensible defaults

Afterward, you'll have a working RHACS + Compliance Operator environment, demo workloads, and a daily compliance scanning schedule—all preconfigured. RHACS access details are printed at the end of the script.

## 📋 What Gets Installed

### Configuration
- Git configured with default branch `main`
- Useful aliases added to your shell config
- Demo project created at `~/demo-project`

## 🛠️ After Installation

1. **Restart your terminal** or reload your shell:
   ```bash
   source ~/.zshrc  # for zsh
   # or
   source ~/.bashrc  # for bash
   ```

2. **Check out your demo project**:
   ```bash
   cd ~/demo-project
   npm start  # or python3 -m http.server 8080
   ```

## 🎯 Demo Project

The script creates a simple demo project at `~/demo-project` with:
- `index.html` - A simple welcome page
- `package.json` - Node.js project configuration
- `README.md` - Project documentation

## 🔧 Manual Installation

If you prefer to download and run manually:

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/mfosterrox/demo-config/main/install.sh -o install.sh

# Make it executable
chmod +x install.sh

# Run it
./install.sh
```

## 🐛 Troubleshooting

### Permission Issues
```bash
chmod +x install.sh
```

### Missing Package Manager
The script works with:
- **RHEL/CentOS**: YUM

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.