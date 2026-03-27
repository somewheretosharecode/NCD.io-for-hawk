#!/bin/bash
# =============================================================================
# NCD.io Full Setup Script — One Run Does Everything
# curl -sL https://raw.githubusercontent.com/somewheretosharecode/NCD.io-for-hawk/main/ncd_setup.sh -o ~/ncd_setup.sh && bash ~/ncd_setup.sh
# =============================================================================

printf '\e[?2004l' 2>/dev/null || true

PHASE_FILE="/home/$USER/.ncd_setup_phase"

# =============================================================================
# AUTO-DETECT HARDWARE
# =============================================================================

detect_hardware() {
    PI_MODEL=""
    HAS_EEPROM=false
    HAS_FAN_SUPPORT=false

    if [ -f /proc/device-tree/model ]; then
        PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')
    fi

    if echo "$PI_MODEL" | grep -qi "Compute Module 5\|CM5\|Compute Module 4\|CM4"; then
        HAS_EEPROM=true
        HAS_FAN_SUPPORT=true
    elif echo "$PI_MODEL" | grep -qi "Raspberry Pi 5\|Raspberry Pi 4"; then
        HAS_EEPROM=true
        HAS_FAN_SUPPORT=true
    fi

    export PI_MODEL HAS_EEPROM HAS_FAN_SUPPORT
}

detect_hardware
echo "============================================="
echo " NCD.io CM5 Full Setup"
echo " Hardware: $PI_MODEL"
echo " User: $USER  |  Date: $(date)"
echo "============================================="

# =============================================================================
# PHASE 1 — Clone USB to eMMC (runs when booted from USB)
# =============================================================================

ROOT_PART=$(findmnt -n -o SOURCE /)
ROOT_DEV=$(echo "$ROOT_PART" | sed 's/p\?[0-9]*$//')

if ! echo "$ROOT_DEV" | grep -q "mmcblk"; then

    echo ""
    echo "[PHASE 1/2] Cloning USB → eMMC"
    echo ""

    # Find eMMC
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
    echo "  Source (USB):      $ROOT_DEV  ($USB_SIZE)"
    echo "  Target (eMMC):     $EMMC_DEV  ($EMMC_SIZE)"
    echo ""
    echo "  ALL DATA ON $EMMC_DEV WILL BE PERMANENTLY ERASED."
    echo "  Type YES to confirm:"
    read -r CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted."
        exit 1
    fi

    # Ask Node-RED question NOW before clone so answer is saved
    echo ""
    echo "Do you want to install Node-RED? (yes/no):"
    read -r NR_CONFIRM
    if [ "$NR_CONFIRM" = "yes" ] || [ "$NR_CONFIRM" = "YES" ] || [ "$NR_CONFIRM" = "y" ] || [ "$NR_CONFIRM" = "Y" ]; then
        INSTALL_NODERED=true
    else
        INSTALL_NODERED=false
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

    # Lock boot order
    if [ "$HAS_EEPROM" = true ] && command -v rpi-eeprom-config &>/dev/null; then
        echo "Locking boot order to eMMC..."
        TMPCONF=$(mktemp)
        sudo rpi-eeprom-config > "$TMPCONF"
        if grep -q "^BOOT_ORDER=" "$TMPCONF"; then
            sed -i 's/^BOOT_ORDER=.*/BOOT_ORDER=0xf14/' "$TMPCONF"
        else
            echo "BOOT_ORDER=0xf14" >> "$TMPCONF"
        fi
        sudo rpi-eeprom-config --apply "$TMPCONF"
        rm -f "$TMPCONF"
        echo "  ✓ Boot order locked to eMMC"
    fi

    # Save phase file and Node-RED choice to eMMC so phase 2 continues after reboot
    EMMC_MOUNT="/tmp/emmc_mount"
    sudo mkdir -p "$EMMC_MOUNT"
    sudo mount "${EMMC_DEV}p2" "$EMMC_MOUNT" 2>/dev/null || true

    if mountpoint -q "$EMMC_MOUNT"; then
        sudo cp ~/ncd_setup.sh "$EMMC_MOUNT/home/$USER/ncd_setup.sh" 2>/dev/null || true
        echo "INSTALL_NODERED=$INSTALL_NODERED" | sudo tee "$EMMC_MOUNT/home/$USER/.ncd_setup_phase" > /dev/null
        sudo umount "$EMMC_MOUNT"
        echo "  ✓ Setup will continue automatically after reboot"
    else
        echo "  ⚠ Could not mount eMMC to save phase — run script manually after reboot"
    fi

    # Register phase 2 to run on next boot via rc.local on eMMC
    sudo mount "${EMMC_DEV}p2" "$EMMC_MOUNT" 2>/dev/null || true
    if mountpoint -q "$EMMC_MOUNT"; then
        sudo tee "$EMMC_MOUNT/etc/rc.local" > /dev/null << RCEOF
#!/bin/bash
PHASE_FILE="/home/$USER/.ncd_setup_phase"
if [ -f "\$PHASE_FILE" ]; then
    sleep 10
    su - $USER -c "bash /home/$USER/ncd_setup.sh" > /home/$USER/ncd_setup_phase2.log 2>&1
fi
exit 0
RCEOF
        sudo chmod +x "$EMMC_MOUNT/etc/rc.local"
        sudo umount "$EMMC_MOUNT"
        echo "  ✓ Phase 2 registered to run on next boot"
    fi

    echo ""
    echo "  ✓ Clone complete — remove USB stick now"
    echo "  Phase 2 (fan, screenshots, Node-RED) will run automatically after reboot"
    echo ""
    echo "Remove USB stick now, then reboot? (yes/no):"
    read -r CLONE_REBOOT
    if [ "$CLONE_REBOOT" = "yes" ] || [ "$CLONE_REBOOT" = "YES" ] || [ "$CLONE_REBOOT" = "y" ] || [ "$CLONE_REBOOT" = "Y" ]; then
        echo "Rebooting in 5 seconds..."
        for i in 5 4 3 2 1; do echo "  $i..."; done
        sudo reboot
    else
        echo "Reboot skipped. Remove USB stick and run 'sudo reboot' when ready."
    fi
    exit 0
fi

# =============================================================================
# PHASE 2 — Runs after reboot from eMMC
# =============================================================================

echo ""
echo "[PHASE 2/2] Installing software..."
echo ""

# Load saved Node-RED choice if coming from phase 1 auto-run
INSTALL_NODERED=false
if [ -f "$PHASE_FILE" ]; then
    source "$PHASE_FILE"
    rm -f "$PHASE_FILE"
    echo "  Resuming from phase 1 — Node-RED choice: $INSTALL_NODERED"
else
    # Running manually — ask again
    echo "Do you want to install Node-RED? (yes/no):"
    read -r NR_CONFIRM
    if [ "$NR_CONFIRM" = "yes" ] || [ "$NR_CONFIRM" = "YES" ] || [ "$NR_CONFIRM" = "y" ] || [ "$NR_CONFIRM" = "Y" ]; then
        INSTALL_NODERED=true
    fi
fi

# Fan curve
detect_hardware
if [ "$HAS_FAN_SUPPORT" = true ]; then
    echo "Setting up fan curve..."
    sudo sed -i '/^dtparam=fan_temp/d' /boot/firmware/config.txt
    sudo tee -a /boot/firmware/config.txt > /dev/null << 'FANEOF'

# NCD.io Fan Curve (4-pin PWM fan on J13)
dtparam=fan_temp0=35000,fan_temp0_hyst=5000,fan_temp0_speed=40
dtparam=fan_temp1=45000,fan_temp1_hyst=5000,fan_temp1_speed=55
dtparam=fan_temp2=55000,fan_temp2_hyst=5000,fan_temp2_speed=75
dtparam=fan_temp3=65000,fan_temp3_hyst=5000,fan_temp3_speed=100
FANEOF
    echo "  ✓ Fan curve set"
else
    echo "  Skipping fan — not supported on $PI_MODEL"
fi

# Screenshots
echo "Setting up screenshot shortcuts..."
sudo apt install -y grim slurp wl-clipboard 2>/dev/null
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
echo "  ✓ Screenshot shortcuts configured"

# Node-RED
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
    echo "  ✓ Node: $(node --version)"

    echo "Installing Node-RED v3.1.15..."
    mkdir -p ~/.node-red && cd ~/.node-red
    npm install node-red@3.1.15
    sudo npm install -g --unsafe-perm node-red@3.1.15
    sudo ln -sf "$(which node-red)" /usr/bin/node-red
    echo "  ✓ Node-RED installed"

    echo "Installing NCD package..."
    cd ~/.node-red
    npm install @ncd-io/node-red-enterprise-sensors
    WIRELESS="$HOME/.node-red/node_modules/@ncd-io/node-red-enterprise-sensors/wireless.js"
    if grep -q "sp\.list()" "$WIRELESS"; then
        sed -i 's/sp\.list()/sp.SerialPort.list()/' "$WIRELESS"
        echo "  ✓ Serialport patch applied"
    fi

    sudo usermod -a -G dialout "$USER"
    sudo systemctl enable nodered.service 2>/dev/null || true
    echo "  ✓ Node-RED autostart enabled"

fi

# Clean up rc.local
sudo bash -c 'echo "#!/bin/bash
exit 0" > /etc/rc.local'

# Done
echo ""
echo "============================================="
echo " Setup Complete!"
echo "============================================="
echo ""
if [ "$INSTALL_NODERED" = true ]; then
    echo " Node-RED starts automatically on every boot."
    echo " Open browser: http://localhost:1880"
    echo " In gateway config type port: /dev/ttyUSB0"
fi
echo "============================================="
echo ""
echo "Reboot now to activate all settings? (yes/no):"
read -r REBOOT_CONFIRM
if [ "$REBOOT_CONFIRM" = "yes" ] || [ "$REBOOT_CONFIRM" = "YES" ] || [ "$REBOOT_CONFIRM" = "y" ] || [ "$REBOOT_CONFIRM" = "Y" ]; then
    echo "Rebooting in 5 seconds..."
    for i in 5 4 3 2 1; do echo "  $i..."; done
    sudo reboot
else
    echo "Reboot skipped. Run 'sudo reboot' when ready."
fi
