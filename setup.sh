#!/bin/bash
set -euo pipefail

# ================= CONFIG =================
BINARY_URL="https://github.com/davudsedft/icmp/releases/download/1/pingtunnel"
INSTALL_DIR="/opt/pingtunnel"
CONFIG_FILE="$INSTALL_DIR/config-server.json"
SERVICE_FILE="/etc/systemd/system/pingtunnel.service"
BINARY_NAME="pingtunnel"
SERVICE_NAME="pingtunnel"
# ==========================================

# ---------- helpers ----------
install_pkg() {
    local pkg="$1"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y "$pkg"
    elif command -v dnf &> /dev/null; then
        dnf install -y "$pkg"
    elif command -v yum &> /dev/null; then
        yum install -y "$pkg"
    elif command -v apk &> /dev/null; then
        apk add --no-cache "$pkg"
    elif command -v zypper &> /dev/null; then
        zypper install -y "$pkg"
    else
        echo "ERROR: No supported package manager found. Please install '$pkg' manually."
        exit 1
    fi
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please run this script as root (use sudo)."
        exit 1
    fi
}

# ---------- actions ----------
do_install() {
    require_root

    echo "========================================="
    echo "   PingTunnel Server Installer"
    echo "========================================="

    # 1. Password prompt (from /dev/tty so it works with curl | bash)
    while true; do
        read -sp "Enter a password (min 8 characters, press Enter to confirm): " PASSWORD < /dev/tty
        echo ""
        if [ ${#PASSWORD} -ge 8 ]; then
            read -sp "Confirm password: " PASSWORD_CONFIRM < /dev/tty
            echo ""
            if [ "$PASSWORD" == "$PASSWORD_CONFIRM" ]; then
                break
            else
                echo "Passwords do not match. Try again."
            fi
        else
            echo "Password must be at least 8 characters. Try again."
        fi
    done
    echo "Password set successfully."

    # 2. Dependency: only curl now (no unzip needed)
    if ! command -v curl &> /dev/null; then
        echo "Installing curl..."
        install_pkg curl
    fi

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # 3. Download raw binary
    echo "Downloading PingTunnel binary..."
    curl -fL -o "$BINARY_NAME" "$BINARY_URL"

    # Sanity check: file must exist and not be tiny (e.g. an HTML error page)
    if [ ! -f "$BINARY_NAME" ]; then
        echo "Download failed: file not saved."
        exit 1
    fi
    SIZE=$(stat -c%s "$BINARY_NAME" 2>/dev/null || echo 0)
    if [ "$SIZE" -lt 100000 ]; then
        echo "Downloaded file is suspiciously small ($SIZE bytes)."
        echo "It may be an error page instead of the binary. Aborting."
        rm -f "$BINARY_NAME"
        exit 1
    fi

    # 4. Make executable and verify it runs
    chmod +x "$BINARY_NAME"
    if ! "./$BINARY_NAME" -h &> /dev/null && [ $? -ne 1 ]; then
        echo "Warning: binary did not respond to -h as expected."
        echo "Continuing anyway..."
    fi
    echo "Binary installed ($SIZE bytes)."

    # 5. Generate JSON config
    echo "Generating config file..."
    cat > "$CONFIG_FILE" <<EOF
{
  "type": "server",
  "password": "$PASSWORD",
  "encrypt": "chacha20",
  "icmp_listen": "0.0.0.0"
}
EOF
    chmod 600 "$CONFIG_FILE"

    # 6. systemd service
    echo "Creating systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=PingTunnel Server Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/$BINARY_NAME -c $CONFIG_FILE
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 7. Enable and start
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME.service"
    systemctl restart "$SERVICE_NAME.service"

    # 8. Status check
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME.service"; then
        echo "========================================="
        echo "Installation complete! PingTunnel is running."
        echo "Config file:  $CONFIG_FILE"
        echo "Check status: systemctl status pingtunnel"
        echo "View logs:    journalctl -u pingtunnel -f"
        echo "========================================="
    else
        echo "Service failed to start. Check logs:"
        echo "journalctl -u pingtunnel -xe"
    fi
}

do_uninstall() {
    require_root

    echo "========================================="
    echo "   PingTunnel Uninstaller"
    echo "========================================="
    read -rp "Are you sure you want to remove PingTunnel? [y/N]: " CONFIRM < /dev/tty
    case "$CONFIRM" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Aborted."; exit 0 ;;
    esac

    echo "Stopping and disabling service..."
    systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true

    if [ -f "$SERVICE_FILE" ]; then
        echo "Removing systemd unit..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl reset-failed 2>/dev/null || true
    fi

    if [ -d "$INSTALL_DIR" ]; then
        echo "Removing install directory ($INSTALL_DIR)..."
        rm -rf "$INSTALL_DIR"
    fi

    echo "========================================="
    echo "PingTunnel removed successfully."
    echo "========================================="
}

do_status() {
    echo "========================================="
    echo "   PingTunnel Status"
    echo "========================================="

    if systemctl list-unit-files 2>/dev/null | grep -q "^$SERVICE_NAME.service"; then
        systemctl status "$SERVICE_NAME.service" --no-pager || true
        echo ""
        echo "---- Last 20 log lines ----"
        journalctl -u "$SERVICE_NAME.service" -n 20 --no-pager || true
    else
        echo "PingTunnel service is NOT installed."
    fi
}

# ---------- menu ----------
require_root

echo "========================================="
echo "   PingTunnel Management Menu"
echo "========================================="
echo "1) Install"
echo "2) Uninstall"
echo "3) Status"
echo "4) Exit"
echo "========================================="
read -rp "Choose an option [1-4]: " CHOICE < /dev/tty

case "$CHOICE" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_status ;;
    4) echo "Bye."; exit 0 ;;
    *) echo "Invalid option."; exit 1 ;;
esac
