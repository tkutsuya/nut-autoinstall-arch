#!/bin/bash

# 1. Hardware Defaults (Keep for udev rules reference, but not used for config fallback)
VENDOR_ID="0665"
PRODUCT_ID="5161"

# 2. Prompt for UPS Credentials
echo "--- UPS Security Setup ---"
read -p "Enter desired UPS Admin Username [admin]: " UPS_NAME
UPS_NAME=${UPS_NAME:-admin}

while true; do
    read -s -p "Enter new UPS Password: " UPS_PASS
    echo
    read -s -p "Confirm UPS Password: " UPS_PASS_CONFIRM
    echo
    if [ "$UPS_PASS" = "$UPS_PASS_CONFIRM" ]; then break; else echo "Passwords do not match. Try again."; fi
done

echo "--- Installing Network UPS Tools ---"
sudo pacman -S --noconfirm nut

echo "--- UPS Identification ---"
read -p "Enter a name for this UPS (e.g., cleanline): " UPS_ID
UPS_ID=${UPS_ID:-cleanline}

echo "--- Scanning for UPS Hardware ---"
# -U (USB), -N (NUT format), -q (quiet)
SCAN_RESULT=$(sudo nut-scanner -UNq 2>/dev/null | grep -v '\[')

# Check if SCAN_RESULT is empty; if so, exit the script immediately
if [ -z "$SCAN_RESULT" ]; then
    echo "CRITICAL: No UPS hardware detected via nut-scanner. Installation aborted."
    exit 1
fi

echo "--- Configuring UPS Driver (/etc/nut/ups.conf) ---"
echo "Hardware found! Applying configuration..."
sudo tee /etc/nut/ups.conf <<EOF
[$UPS_ID]
$SCAN_RESULT
    desc = "Cleanline UPS"
    default.battery.voltage.high = 40.5
    default.battery.voltage.low = 30.0
EOF

echo "--- Configuring Services ---"
sudo sed -i 's/MODE=none/MODE=standalone/' /etc/nut/nut.conf
echo "LISTEN 127.0.0.1 3493" | sudo tee /etc/nut/upsd.conf

sudo tee /etc/nut/upsd.users <<EOF
[$UPS_NAME]
    password = $UPS_PASS
    actions = SET
    instcmds = ALL
    upsmon primary
EOF

sudo tee /etc/nut/upsmon.conf <<EOF
MONITOR $UPS_ID@localhost 1 $UPS_NAME $UPS_PASS primary
SHUTDOWNCMD "/sbin/shutdown -h +P now"
POWERDOWNFLAG /etc/killpower
EOF

# Grant 'uucp' group access to the USB bridge
sudo tee /etc/udev/rules.d/99-nut-cypress.rules <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="$VENDOR_ID", ATTR{idProduct}=="$PRODUCT_ID", MODE="0664", GROUP="uucp"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger

# Fix Race Condition & Permissions
sudo mkdir -p /etc/systemd/system/nut-monitor.service.d
sudo tee /etc/systemd/system/nut-monitor.service.d/override.conf <<EOF
[Unit]
After=nut-server.service
Wants=nut-server.service
[Service]
ExecStartPre=/usr/bin/sleep 2
EOF

sudo chown root:nut /etc/nut/*.conf /etc/nut/upsd.users
sudo chmod 640 /etc/nut/*.conf /etc/nut/upsd.users

echo "--- Starting Services ---"
getent group uucp || sudo groupadd uucp
sudo usermod -aG uucp $USER
sudo systemctl daemon-reload
sudo systemctl enable --now nut-driver@$UPS_ID.service nut-server.service nut-monitor.service

echo "--- Installation Complete ---"
echo "Check status with: upsc $UPS_ID@localhost"
