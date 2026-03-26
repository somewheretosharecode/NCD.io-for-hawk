#!/bin/bash
# =============================================================================
# NCD.io CM5 Full Setup Script
# run this on the terminal:
# curl -sL https://raw.githubusercontent.com/somewheretosharecode/NCD.io-for-hawk/main/ncd_setup.sh -o ~/ncd_setup.sh && bash ~/ncd_setup.sh
#
# When booted from USB → clones OS to eMMC, reboots
# When booted from eMMC → installs everything, asks to reboot
# =============================================================================

printf '\e[?2004l' 2>/dev/null || true

# =============================================================================
# STEP 1 — Clone USB OS to eMMC (runs when booted from USB)
# =============================================================================

ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DEV=$(echo "$ROOT_PART" | sed 's/p\?[0-9]*$//')

if echo "$ROOT_DEV" | grep -q "mmcblk"; then
    echo "Skipping clone — already booted from eMMC. Continuing to next steps."
else
    echo "============================================="
    echo " Clone USB → eMMC"
    echo " User: $USER  |  Date: $(date)"
    echo "============================================="

    EMMC_DEV=""
    for dev in /dev/mmcblk0 /dev/mmcblk1; do
        if [ -b "$dev" ]; then
            EMMC_SIZE=$(lsblk -d -n -o SIZE "$dev" 2>/dev/null || echo "?")
            echo "  Found eMMC: $dev ($EMMC_SIZE)"
            EMMC_DEV="$dev"
        fi
    done

    if [ -z "$EMMC_DEV" ]; then
        echo "  No eMMC auto-detected. Available devices:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL
        echo "  Enter eMMC device path (e.g. /dev/mmcblk0):"
        read -r EMMC_DEV
    fi

    USB_SIZE=$(lsblk -d -n -o SIZE "$ROOT_DEV" 2>/dev/null || echo "?")
    EMMC_SIZE=$(lsblk -d -n -o SIZE "$EMMC_DEV" 2>/dev/null || echo "?")

    echo ""
    echo "  Source (USB):   $ROOT_DEV  ($USB_SIZE)"
    echo "  Target (eMMC):  $EMMC_DEV  ($EMMC_SIZE)"
    echo ""
    echo "  ALL DATA ON $EMMC_DEV WILL BE PERMANENTLY ERASED."
    echo "  Type YES to confirm:"
    read -r CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi

    echo "Wiping eMMC..."
    sudo dd if=/dev/zero of="$EMMC_DEV" bs=1M count=100 status=progress
    sudo sync

    echo "Cloning USB to eMMC..."
    sudo dd if="$ROOT_DEV" of="$EMMC_DEV" bs=4M status=progress conv=fsync
    sudo sync

    echo "Expanding filesystem..."
    sudo parted -s "$EMMC_DEV" resizepart 2 100% 2>/dev/null || true
    sudo e2fsck -f "${EMMC_DEV}p2" 2>/dev/null || true
    sudo resize2fs "${EMMC_DEV}p2" 2>/dev/null || true

    echo "Setting eMMC as permanent boot device..."
    if command -v rpi-eeprom-config &>/dev/null; then
        TMPCONF=$(mktemp)
        sudo rpi-eeprom-config > "$TMPCONF"
        if grep -q "^BOOT_ORDER=" "$TMPCONF"; then
            sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf14/' "$TMPCONF"
        else
            echo "BOOT_ORDER=0xf14" >> "$TMPCONF"
        fi
        sudo rpi-eeprom-config --apply "$TMPCONF"
        rm -f "$TMPCONF"
    fi

    echo "  ✓ Clone complete — remove USB stick"
    echo "  Run this script again after reboot to continue setup"
    echo ""
    echo "Remove USB stick now, then reboot? (yes/no):"
    read -r CLONE_REBOOT
    if [ "$CLONE_REBOOT" = "yes" ] || [ "$CLONE_REBOOT" = "YES" ] || [ "$CLONE_REBOOT" = "y" ] || [ "$CLONE_REBOOT" = "Y" ]; then
        echo "Rebooting in 5 seconds... Press Ctrl+C to cancel."
        sleep 5
        sudo reboot
    else
        echo "Reboot skipped. Remove USB stick and run 'sudo reboot' when ready."
    fi
    exit 0
fi

# =============================================================================
# STEP 2 — Fan curve
# =============================================================================

echo "Setting up fan curve..."
sudo sed -i '/^dtparam=fan_temp/d' /boot/firmware/config.txt
sudo tee -a /boot/firmware/config.txt > /dev/null << 'FANEOF'

# NCD.io Fan Curve (4-pin PWM fan on J13)
dtparam=fan_temp0=35000,fan_temp0_hyst=5000,fan_temp0_speed=40
dtparam=fan_temp1=45000,fan_temp1_hyst=5000,fan_temp1_speed=55
dtparam=fan_temp2=55000,fan_temp2_hyst=5000,fan_temp2_speed=75
dtparam=fan_temp3=65000,fan_temp3_hyst=5000,fan_temp3_speed=100
FANEOF
echo "  ✓ Fan curve set (35°C=40% | 45°C=55% | 55°C=75% | 65°C=100%)"

# =============================================================================
# STEP 3 — Screenshot shortcuts (Wayland/labwc)
# =============================================================================

echo "Setting up screenshot shortcuts..."
sudo apt install -y grim slurp wl-clipboard
mkdir -p ~/.config/labwc

cat > ~/screenshot-clip.sh << 'CLIPEOF'
#!/bin/bash
grim -g "$(slurp)" - | wl-copy --type image/png
sleep 15
wl-copy --clear
CLIPEOF
chmod +x ~/screenshot-clip.sh

cat > ~/.config/labwc/rc.xml << LABWCEOF
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <keyboard>
    <keybind key="Print">
      <action name="Execute">
        <command>bash -c 'grim \${HOME}/Desktop/screenshot_\$(date +%Y%m%d_%H%M%S).png'</command>
      </action>
    </keybind>
    <keybind key="S-Print">
      <action name="Execute">
        <command>bash /home/$USER/screenshot-clip.sh</command>
      </action>
    </keybind>
  </keyboard>
</openbox_config>
LABWCEOF

labwc --reconfigure 2>/dev/null || true
echo "  ✓ Print Screen       → PNG saved to Desktop"
echo "  ✓ Shift+Print Screen → region to clipboard (clears after 15s)"

# =============================================================================
# STEP 4 — Node.js v18 + Node-RED v3.1.15 (optional)
# =============================================================================

INSTALL_NODERED=false
echo ""
echo "Do you want to install Node-RED? (yes/no):"
read -r NR_CONFIRM
if [ "$NR_CONFIRM" = "yes" ] || [ "$NR_CONFIRM" = "YES" ] || [ "$NR_CONFIRM" = "y" ] || [ "$NR_CONFIRM" = "Y" ]; then
    INSTALL_NODERED=true
else
    echo "  Skipping Node-RED installation."
fi

if [ "$INSTALL_NODERED" = true ]; then

    echo "Installing Node.js v18..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    nvm install 18
    nvm use 18
    nvm alias default 18
    sudo ln -sf "$(which node)" /usr/bin/node
    sudo ln -sf "$(which npm)"  /usr/bin/npm
    echo "  ✓ Node: $(node --version)  npm: $(npm --version)"

    echo "Installing Node-RED v3.1.15..."
    mkdir -p ~/.node-red
    cd ~/.node-red
    npm install node-red@3.1.15
    sudo npm install -g --unsafe-perm node-red@3.1.15
    sudo ln -sf "$(which node-red)" /usr/bin/node-red
    echo "  ✓ Node-RED installed"

    # =============================================================================
    # STEP 5 — NCD package + serialport fix + dialout
    # =============================================================================

    echo "Installing NCD enterprise sensors package..."
    cd ~/.node-red
    npm install @ncd-io/node-red-enterprise-sensors

    WIRELESS="$HOME/.node-red/node_modules/@ncd-io/node-red-enterprise-sensors/wireless.js"
    if grep -q "sp\.list()" "$WIRELESS"; then
        sed -i 's/sp\.list()/sp.SerialPort.list()/' "$WIRELESS"
        echo "  ✓ Patched sp.list() → sp.SerialPort.list()"
    else
        echo "  ✓ Serialport patch not needed"
    fi

    sudo usermod -a -G dialout "$USER"
    echo "  ✓ Added $USER to dialout group"

    # =============================================================================
    # STEP 6 — Enable Node-RED autostart on every boot
    # =============================================================================

    echo "Enabling Node-RED to start automatically on every boot..."
    sudo systemctl enable nodered.service 2>/dev/null || true
    echo "  ✓ Node-RED will start automatically on every boot"

fi

# =============================================================================
# DONE
# =============================================================================

echo ""
echo "============================================="
echo " Setup Complete!"
echo "============================================="
echo ""
if [ "$INSTALL_NODERED" = true ]; then
    echo " Node-RED starts automatically on every boot."
    echo " Open browser: http://localhost:1880"
    echo ""
    echo " To import the NCD flow:"
    echo "  1. Menu → Import → select ~/ncd_flow_patched.json"
    echo "  2. In gateway config type port: /dev/ttyUSB0"
    echo "  3. Click Deploy"
else
    echo " Node-RED was not installed."
    echo " Run this script again and select yes to install it."
fi
echo "============================================="
echo ""
echo "A reboot is required to activate:"
echo "  - Fan curve"
echo "  - Screenshot shortcuts"
echo "  - dialout group permissions"
if [ "$INSTALL_NODERED" = true ]; then
echo "  - Node-RED autostart"
fi
echo ""
echo "Reboot now? (yes/no):"
read -r REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "yes" ] || [ "$REBOOT_CONFIRM" = "YES" ] || [ "$REBOOT_CONFIRM" = "y" ] || [ "$REBOOT_CONFIRM" = "Y" ]; then
    echo "Rebooting in 5 seconds... Press Ctrl+C to cancel."
    sleep 5
    sudo reboot
else
    echo "Reboot skipped. Run 'sudo reboot' when ready."
fi
