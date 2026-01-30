#!/bin/bash
# Detect if the system is Manjaro Linux
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "Manjaro" ]; then
        echo "ERROR: This script is designed for Arch Linux. Detected: $NAME"
        exit 1
    fi
else
    echo "ERROR: Cannot detect OS. This script requires Arch Linux."
    exit 1
fi

# 1. Hardware Defaults
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

# 3. Validation Check
if [[ -z "$UPS_NAME" || -z "$UPS_PASS" ]]; then
    echo "ERROR: Username and Password cannot be empty."
    exit 1
fi

if [[ "$UPS_PASS" =~ [[:space:]] || "$UPS_PASS" == *"#"* ]]; then
    echo "ERROR: Password cannot contain spaces or '#' (NUT config limitation)."
    exit 1
fi

echo "Credentials validated. Proceeding..."
echo "--- Installing Network UPS Tools ---"
sudo pacman -S --noconfirm nut

# CRITICAL: Grant permissions BEFORE testing connection
echo "--- Setting Device Permissions ---"
getent group uucp || sudo groupadd uucp
sudo usermod -aG uucp $USER
sudo tee /etc/udev/rules.d/99-nut-cypress.rules <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="$VENDOR_ID", ATTR{idProduct}=="$PRODUCT_ID", MODE="0664", GROUP="uucp"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger

echo "--- UPS Identification ---"
read -p "Enter a name for this UPS [cleanline]: " UPS_ID
UPS_ID=${UPS_ID:-cleanline}

echo "--- Scanning for UPS Hardware ---"
SCAN_RESULT=$(sudo nut-scanner -UNq 2>/dev/null | grep -v '\[')

if [ -z "$SCAN_RESULT" ]; then
    echo "CRITICAL: No UPS hardware detected via nut-scanner. Installation aborted."
    exit 1
fi

echo "--- Configuring UPS Driver (/etc/nut/ups.conf) ---"
sudo tee /etc/nut/ups.conf <<EOF
[$UPS_ID]
$SCAN_RESULT
    default.battery.voltage.high = 40.5
    default.battery.voltage.low = 30.0
EOF

echo "--- Testing Connection to Hardware ---"
# Test connection with the applied permissions
if ! sudo upsdrvctl -t start >/dev/null 2>&1; then
    echo "ERROR: Driver failed to communicate with the UPS."
    echo "Verify the USB connection and that VendorID $VENDOR_ID matches your device."
    exit 1
fi
echo "Connection successful!"

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
sudo systemctl daemon-reload
sudo systemctl enable --now nut-driver@$UPS_ID.service nut-server.service nut-monitor.service

echo "--- Installation Complete ---"
echo "Check status with: upsc $UPS_ID@localhost"
