# Demo Config

A simple, single-command environment setup script that installs essential development tools and creates a demo project.

## 🚀 Quick Start

Run this single command to set up your development environment:

```bash
curl -fsSL https://raw.githubusercontent.com/your-username/demo-config/main/install.sh | bash
```

That's it! The script will:
- Install essential tools (git, curl, wget, jq, tree, htop)
- Configure Git with sensible defaults
- Set up useful command-line aliases
- Install Node.js (if possible)
- Install Docker (if possible)
- Create a demo project in `~/demo-project`

## 📋 What Gets Installed

### Essential Tools
- **Git** - Version control with basic configuration
- **curl** - HTTP client
- **wget** - File downloader
- **jq** - JSON processor
- **tree** - Directory structure viewer
- **htop** - System monitor

### Optional Tools
- **Node.js** - JavaScript runtime (if package manager available)
- **Docker** - Container platform (if package manager available)

### Configuration
- Git configured with default branch `main`
- Useful aliases added to your shell config
- Demo project created at `~/demo-project`

## 🛠️ After Installation

1. **Configure Git** (required):
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email "your.email@example.com"
   ```

2. **Restart your terminal** or reload your shell:
   ```bash
   source ~/.zshrc  # for zsh
   # or
   source ~/.bashrc  # for bash
   ```

3. **Check out your demo project**:
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
curl -fsSL https://raw.githubusercontent.com/your-username/demo-config/main/install.sh -o install.sh

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
- **macOS**: Homebrew
- **Ubuntu/Debian**: APT
- **RHEL/CentOS**: YUM

If you don't have a package manager, install the tools manually.

### Git Configuration
After installation, you must configure Git:
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

## 📄 License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.

---

**Simple. Fast. Effective.** 🚀