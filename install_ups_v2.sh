#!/bin/bash

# 1. Prompt for UPS Credentials (Security Purpose)
echo "--- UPS Security Setup ---"
read -p "Enter desired UPS Admin Username [admin]: " UPS_NAME
UPS_NAME=${UPS_NAME:-admin} # Defaults to 'admin' if left blank

# Prompt for password securely (not stored in script)
while true; do
    read -s -p "Enter new UPS Password: " UPS_PASS
    echo
    read -s -p "Confirm UPS Password: " UPS_PASS_CONFIRM
    echo
    if [ "$UPS_PASS" = "$UPS_PASS_CONFIRM" ]; then
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

# Hardware Variables (Specific to your Cypress 0665:5161 chip)
UPS_ID="cleanline"
VENDOR_ID="0665"
PRODUCT_ID="5161"

echo "--- Installing Network UPS Tools ---"
sudo pacman -S --noconfirm nut

echo "--- Configuring UPS Driver (/etc/nut/ups.conf) ---"
sudo tee /etc/nut/ups.conf <<EOF
[$UPS_ID]
    driver = nutdrv_qx
    port = auto
    vendorid = $VENDOR_ID
    productid = $PRODUCT_ID
    desc = "Cleanline UPS"
    # Voltage scaling for 36V systems
    default.battery.voltage.high = 40.5
    default.battery.voltage.low = 30.0
EOF

echo "--- Configuring NUT Mode (/etc/nut/nut.conf) ---"
sudo sed -i 's/MODE=none/MODE=standalone/' /etc/nut/nut.conf

echo "--- Configuring Server (/etc/nut/upsd.conf) ---"
sudo tee /etc/nut/upsd.conf <<EOF
LISTEN 127.0.0.1 3493
EOF

echo "--- Configuring Users (/etc/nut/upsd.users) ---"
sudo tee /etc/nut/upsd.users <<EOF
[$UPS_NAME]
    password = $UPS_PASS
    actions = SET
    instcmds = ALL
    upsmon master
EOF

echo "--- Configuring Monitor (/etc/nut/upsmon.conf) ---"
sudo tee /etc/nut/upsmon.conf <<EOF
MONITOR $UPS_ID@localhost 1 $UPS_NAME $UPS_PASS master
SHUTDOWNCMD "/sbin/shutdown -h +P now"
POWERDOWNFLAG /etc/killpower
EOF

echo "--- Adding USB Permissions (udev) ---"
# This grants the 'uucp' group access to the Cypress USB bridge
sudo tee /etc/udev/rules.d/99-nut-cypress.rules <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="$VENDOR_ID", ATTR{idProduct}=="$PRODUCT_ID", MODE="0664", GROUP="uucp"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger

echo "--- Fixing Startup Race Condition (Systemd Override) ---"
# This ensures the monitor waits for the driver and server to fully initialize
sudo mkdir -p /etc/systemd/system/nut-server.service.d
sudo tee /etc/systemd/system/nut-server.service.d/override.conf <<EOF
[Unit]
# Wait for the specific driver instance to be ready
After=nut-driver@$UPS_ID.service
BindsTo=nut-driver@$UPS_ID.service
EOF



echo "--- Enabling Services ---"
getent group uucp || groupadd uucp
sudo usermod -aG uucp nut
sudo systemctl daemon-reload
sudo systemctl enable nut-driver-enumerator.service
sudo systemctl enable --now nut-driver@$UPS_ID.service
sudo systemctl enable --now nut-server.service
sudo systemctl enable --now nut-monitor.service
sudo systemctl enable --now nut.target



echo "--- Installation Complete ---"
echo "UPS Admin User: $UPS_NAME"
echo "Check status with: upsc $UPS_ID@localhost"
echo "NOTE: Please log out and back in (or reboot) for group permissions to take effect."


