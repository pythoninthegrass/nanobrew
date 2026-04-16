#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/nanobrew"

echo ""
echo "  nanobrew — uninstaller"
echo ""

# Detect OS
OS="$(uname -s)"

# Remove PATH entry from shell rc files
remove_path_entry() {
    local rc_file="$1"
    if [ ! -f "$rc_file" ]; then
        return
    fi
    if grep -q '/opt/nanobrew/prefix/bin' "$rc_file" 2>/dev/null; then
        if [ "$OS" = "Darwin" ]; then
            sed -i '' '/^# nanobrew$/d' "$rc_file"
            sed -i '' '/\/opt\/nanobrew\/prefix\/bin/d' "$rc_file"
        else
            sed -i '/^# nanobrew$/d' "$rc_file"
            sed -i '/\/opt\/nanobrew\/prefix\/bin/d' "$rc_file"
        fi
        echo "  Removed PATH entry from $rc_file"
    fi
}

remove_path_entry "$HOME/.zshrc"
remove_path_entry "$HOME/.bashrc"
remove_path_entry "$HOME/.bash_profile"
remove_path_entry "$HOME/.profile"

# Remove nanobrew directory
if [ -d "$INSTALL_DIR" ]; then
    echo "  Removing $INSTALL_DIR ..."
    if [ -w "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    else
        sudo rm -rf "$INSTALL_DIR"
    fi
    echo "  Removed $INSTALL_DIR"
else
    echo "  $INSTALL_DIR not found — already removed or never installed"
fi

echo ""
echo "  nanobrew has been uninstalled."
echo "  Restart your shell or run: exec \$SHELL"
echo ""