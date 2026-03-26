#!/bin/bash
# =============================================================================
# NCD.io Wireless Sensor — Raspberry Pi CM5 Full Setup Script
# Tested: Raspberry Pi OS Bookworm (Wayland/labwc), Node-RED v4.x,
#         Node.js v18, @ncd-io/node-red-enterprise-sensors v1.4.7
#
# This script:
#   1. Clones the running USB OS to the internal eMMC
#   2. Sets eMMC as primary boot device
#   3. Installs Node.js v18, Node-RED, NCD package + fixes
#   4. Configures screenshot shortcuts
#   5. Writes a ready-to-import NCD flow JSON
#
# Usage: bash ncd_setup.sh
# =============================================================================

set -e
LOGFILE="$HOME/ncd_setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "============================================="
echo " NCD.io CM5 Full Setup Script"
echo " User: $USER  |  Home: $HOME"
echo " Date: $(date)"
echo "============================================="

# =============================================================================
# STEP 1 — Detect USB source and eMMC target, then clone OS to eMMC
# =============================================================================
echo ""
echo "[1/7] Detecting storage devices..."

# Find the device we are currently booted from
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//' | sed 's/[0-9]*$//')
echo "  Currently booted from: $ROOT_DEV"

# Find the eMMC (internal storage on CM5)
EMMC_DEV=""
for dev in /dev/mmcblk0 /dev/mmcblk1; do
    if [ -b "$dev" ]; then
        # Check if it's eMMC (not SD)
        TYPE=$(cat /sys/block/$(basename $dev)/device/type 2>/dev/null || echo "unknown")
        NAME=$(cat /sys/block/$(basename $dev)/device/name 2>/dev/null || echo "unknown")
        echo "  Found block device: $dev (type=$TYPE name=$NAME)"
        if echo "$NAME $TYPE" | grep -qi "MMC\|emmc\|EMMC"; then
            EMMC_DEV="$dev"
        elif [ "$dev" != "$ROOT_DEV" ]; then
            # If we can't determine type, use whichever isn't the boot device
            EMMC_DEV="$dev"
        fi
    fi
done

if [ -z "$EMMC_DEV" ]; then
    echo ""
    echo "  ERROR: Could not auto-detect eMMC device."
    echo "  Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,MODEL
    echo ""
    echo "  Please enter the eMMC device path (e.g. /dev/mmcblk0):"
    read -r EMMC_DEV
fi

echo ""
echo "  Source (USB):    $ROOT_DEV"
echo "  Target (eMMC):   $EMMC_DEV"
echo ""
echo "  WARNING: All data on $EMMC_DEV will be erased."
echo "  Press ENTER to continue or Ctrl+C to abort..."
read -r

echo ""
echo "[2/7] Cloning OS from USB to eMMC ($ROOT_DEV -> $EMMC_DEV)..."
echo "  This will take several minutes..."

# Use rpi-clone if available, otherwise use dd
if command -v rpi-clone &>/dev/null; then
    echo "  Using rpi-clone..."
    sudo rpi-clone "$EMMC_DEV" -f -U
else
    echo "  rpi-clone not found, installing..."
    sudo apt install -y git
    git clone https://github.com/billw2/rpi-clone.git /tmp/rpi-clone
    sudo cp /tmp/rpi-clone/rpi-clone /usr/local/sbin/
    echo "  Using rpi-clone..."
    sudo rpi-clone "$EMMC_DEV" -f -U
fi

echo "  ✓ OS cloned to eMMC successfully"

# =============================================================================
# STEP 2 — Set eMMC as primary boot device
# =============================================================================
echo ""
echo "[3/7] Setting eMMC as primary boot device..."

# Update EEPROM boot order: eMMC (1) first, then USB (4), then network (2)
BOOTCONF=$(sudo rpi-eeprom-config)
if echo "$BOOTCONF" | grep -q "BOOT_ORDER"; then
    sudo rpi-eeprom-config --edit << 'EEPROMEOF'
BOOT_ORDER=0xf14
EEPROMEOF
    echo "  ✓ Boot order set: eMMC first, USB fallback"
else
    echo "  ⚠ Could not update EEPROM boot order automatically"
    echo "    After reboot run: sudo raspi-config -> Advanced -> Boot Order -> eMMC/SD"
fi

# =============================================================================
# STEP 3 — System packages
# =============================================================================
echo ""
echo "[4/7] Installing system dependencies..."
sudo apt update -y
sudo apt install -y build-essential python3 git curl grim slurp wl-clipboard

# =============================================================================
# STEP 4 — NVM + Node.js v18 system-wide
# =============================================================================
echo ""
echo "[5/7] Installing NVM and Node.js v18..."
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
echo "  Node: $(node --version)  npm: $(npm --version)"

# =============================================================================
# STEP 5 — Node-RED + NCD package + serialport fix + dialout
# =============================================================================
echo ""
echo "[6/7] Installing Node-RED and NCD package..."
bash <(curl -sL https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered) \
    --confirm-install --confirm-pi

cd "$HOME/.node-red"
npm install @ncd-io/node-red-enterprise-sensors

WIRELESS="$HOME/.node-red/node_modules/@ncd-io/node-red-enterprise-sensors/wireless.js"
if grep -q "sp\.list()" "$WIRELESS"; then
    sed -i 's/sp\.list()/sp.SerialPort.list()/' "$WIRELESS"
    echo "  ✓ Patched sp.list() -> sp.SerialPort.list()"
else
    echo "  ✓ serialport patch not needed"
fi

sudo usermod -a -G dialout "$USER"
echo "  ✓ Added $USER to dialout group"

# =============================================================================
# STEP 6 — Screenshot shortcuts (Wayland/labwc)
# =============================================================================
echo ""
echo "[7/7] Configuring screenshot shortcuts and NCD flow..."
mkdir -p "$HOME/.config/labwc"

cat > "$HOME/screenshot-clip.sh" << 'EOF'
#!/bin/bash
grim -g "$(slurp)" - | wl-copy --type image/png
sleep 15
wl-copy --clear
EOF
chmod +x "$HOME/screenshot-clip.sh"

cat > "$HOME/.config/labwc/rc.xml" << LABWCEOF
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
        <command>bash \${HOME}/screenshot-clip.sh</command>
      </action>
    </keybind>
  </keyboard>
</openbox_config>
LABWCEOF
echo "  ✓ Print Screen       → PNG to Desktop"
echo "  ✓ Shift+Print Screen → region to clipboard (clears after 15s)"

# --- Auto-detect NCD USB modem serial port ---
SERIAL_PORT=""
FTDI_PORT=$(dmesg 2>/dev/null | grep -i "FTDI\|ftdi_sio" | grep -oP 'ttyUSB\d+' | tail -1 || true)
if [ -n "$FTDI_PORT" ]; then
    SERIAL_PORT="/dev/$FTDI_PORT"
    echo "  ✓ FTDI modem detected: $SERIAL_PORT"
fi
if [ -z "$SERIAL_PORT" ]; then
    FTDI_LINK=$(ls /dev/serial/by-id/ 2>/dev/null | grep -i "FTDI\|ftdi" | head -1 || true)
    if [ -n "$FTDI_LINK" ]; then
        SERIAL_PORT=$(readlink -f "/dev/serial/by-id/$FTDI_LINK")
        echo "  ✓ FTDI modem via serial/by-id: $SERIAL_PORT"
    fi
fi
if [ -z "$SERIAL_PORT" ]; then
    FIRST_USB=$(ls /dev/ttyUSB* 2>/dev/null | head -1 || true)
    if [ -n "$FIRST_USB" ]; then
        SERIAL_PORT="$FIRST_USB"
        echo "  ⚠ Using first ttyUSB: $SERIAL_PORT"
    fi
fi
if [ -z "$SERIAL_PORT" ]; then
    SERIAL_PORT="/dev/ttyUSB0"
    echo "  ⚠ No modem detected, defaulting to $SERIAL_PORT"
fi

CSV_PATH="$HOME/Desktop/vibration_data.csv"
FLOW_OUT="$HOME/ncd_flow_patched.json"

python3 - "$SERIAL_PORT" "$CSV_PATH" "$FLOW_OUT" << 'PYEOF'
import json, sys

serial_port = sys.argv[1]
csv_path    = sys.argv[2]
output_path = sys.argv[3]

flow_json = r'''[{"id":"fb2d99fb28f6bd92","type":"tab","label":"Regular Raw Request + CSV","disabled":false,"info":""},{"id":"1e571cd7d03bf56d","type":"junction","z":"fb2d99fb28f6bd92","x":1440,"y":180,"wires":[["e1b3681f77ffd761","d543d624a90b9781"]]},{"id":"f47d6c920243eb93","type":"function","z":"fb2d99fb28f6bd92","name":"build-command","func":"/*\n    Regular Raw Request command for type 110\n*/\nlet addr = msg.payload.addr;\nmsg.payload = {};\nmsg.payload.address = addr;\nmsg.payload.data = [0xF4, 0x4F, 0x00, 0x00, 0x50, 0x13, 0x01];\nreturn msg;","outputs":1,"timeout":"","noerr":0,"initialize":"","finalize":"","libs":[],"x":1620,"y":80,"wires":[["75dd254e7213776b"]]},{"id":"970c71f401a6bd1b","type":"switch","z":"fb2d99fb28f6bd92","name":"type 110","property":"payload.sensor_type","propertyType":"msg","rules":[{"t":"eq","v":"110","vt":"num"}],"checkall":"true","repair":false,"outputs":1,"x":1070,"y":220,"wires":[["6c28b4732172a3b3"]]},{"id":"75dd254e7213776b","type":"delay","z":"fb2d99fb28f6bd92","name":"","pauseType":"delay","timeout":"100","timeoutUnits":"milliseconds","rate":"1","nbRateUnits":"1","rateUnits":"second","randomFirst":"1","randomLast":"5","randomUnits":"seconds","drop":false,"allowrate":false,"outputs":1,"x":1775,"y":100,"wires":[["843ba970b1e41779"]],"l":false},{"id":"c216830331262e52","type":"debug","z":"fb2d99fb28f6bd92","name":"Processed Data","active":true,"tosidebar":true,"console":false,"tostatus":false,"complete":"payload","targetType":"msg","statusVal":"","statusType":"auto","x":1740,"y":180,"wires":[]},{"id":"58bc4be060ac636f","type":"switch","z":"fb2d99fb28f6bd92","name":"sensor-data","property":"topic","propertyType":"msg","rules":[{"t":"eq","v":"sensor_data","vt":"str"}],"checkall":"true","repair":false,"outputs":1,"x":930,"y":220,"wires":[["970c71f401a6bd1b"]]},{"id":"6c28b4732172a3b3","type":"switch","z":"fb2d99fb28f6bd92","name":"mac","property":"payload.addr","propertyType":"msg","rules":[{"t":"eq","v":"00:13:a2:00:42:30:75:68","vt":"str"}],"checkall":"true","repair":false,"outputs":1,"x":1190,"y":220,"wires":[["49bcb7ea82f1c9d7"]]},{"id":"755d3c9521429333","type":"switch","z":"fb2d99fb28f6bd92","name":"condition","property":"payload","propertyType":"msg","rules":[{"t":"nempty"}],"checkall":"true","repair":false,"outputs":1,"x":1500,"y":140,"wires":[["f47d6c920243eb93","c216830331262e52"]]},{"id":"49bcb7ea82f1c9d7","type":"switch","z":"fb2d99fb28f6bd92","name":"mode","property":"payload.sensor_data.mode","propertyType":"msg","rules":[{"t":"eq","v":"0","vt":"num"},{"t":"eq","v":"2","vt":"num"},{"t":"eq","v":"3","vt":"num"},{"t":"eq","v":"1","vt":"num"}],"checkall":"true","repair":false,"outputs":4,"x":1330,"y":180,"wires":[["755d3c9521429333"],["755d3c9521429333"],["755d3c9521429333"],["1e571cd7d03bf56d"]]},{"id":"13ee05c476445526","type":"link in","z":"fb2d99fb28f6bd92","name":"link in","links":["843ba970b1e41779"],"x":475,"y":280,"wires":[["592d8829822452ac"]]},{"id":"e1b3681f77ffd761","type":"debug","z":"fb2d99fb28f6bd92","name":"Time Domain Data","active":true,"tosidebar":true,"console":false,"tostatus":false,"complete":"payload","targetType":"msg","statusVal":"","statusType":"auto","x":930,"y":460,"wires":[]},{"id":"843ba970b1e41779","type":"link out","z":"fb2d99fb28f6bd92","name":"link out","mode":"link","links":["13ee05c476445526"],"x":475,"y":100,"wires":[]},{"id":"d1f2e16aeb742fa2","type":"debug","z":"fb2d99fb28f6bd92","name":"All Data","active":false,"tosidebar":true,"console":false,"tostatus":false,"complete":"payload","targetType":"msg","statusVal":"","statusType":"auto","x":740,"y":180,"wires":[]},{"id":"d543d624a90b9781","type":"function","z":"fb2d99fb28f6bd92","name":"Format to CSV rows","func":"var d = msg.payload;\nvar sd = d.sensor_data;\nvar now = new Date();\nvar date = now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0');\nvar time_ms = String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0') + ':' + String(now.getSeconds()).padStart(2, '0') + '.' + String(now.getMilliseconds()).padStart(3, '0');\nvar headerWritten = flow.get('csvHeaderWritten') || false;\nvar rows = '';\nif (!headerWritten) {\n    rows = 'date,time_ms,addr,battery_percent,temperature_c,odr_hz,fft_confidence,sample_index,x_g,y_g,z_g\\n';\n    flow.set('csvHeaderWritten', true);\n}\nvar xData = sd.data.x;\nvar yData = sd.data.y;\nvar zData = sd.data.z;\nvar temp = (sd.device_temp !== undefined) ? sd.device_temp : (sd.temperature !== undefined ? sd.temperature : '');\nvar odr = sd.odr || '';\nvar fft = sd.fft_confidence || '';\nfor (var i = 0; i < xData.length; i++) {\n    rows += date + ',' + time_ms + ',' + d.addr + ',' + d.battery_percent + ',' + temp + ',' + odr + ',' + fft + ',' + i + ',' + xData[i] + ',' + yData[i] + ',' + zData[i] + '\\n';\n}\nmsg.payload = rows;\nmsg.filename = 'PLACEHOLDER_CSV';\nmsg.flags = { append: true };\nreturn msg;","outputs":1,"noerr":0,"initialize":"","finalize":"","libs":[],"x":1380,"y":380,"wires":[["fd98b503aad8e90c"]]},{"id":"fd98b503aad8e90c","type":"file","z":"fb2d99fb28f6bd92","name":"Write to CSV","filename":"PLACEHOLDER_CSV","filenameType":"str","appendNewline":false,"createDir":true,"overwriteFile":"false","encoding":"utf8","x":1650,"y":320,"wires":[["ab048ccb112fc397"]]},{"id":"ab048ccb112fc397","type":"debug","z":"fb2d99fb28f6bd92","name":"CSV saved","active":true,"tosidebar":true,"console":false,"tostatus":true,"complete":"payload.length","targetType":"msg","statusVal":"","statusType":"auto","x":1810,"y":320,"wires":[]},{"id":"a848f0ea372974ec","type":"function","z":"fb2d99fb28f6bd92","name":"Config Status","func":"var topic = msg.topic || '';\nvar payload = msg.payload || {};\nvar mode = payload.mode || '';\nif (topic === 'sensor_mode') {\n    if (mode === 'RUN') { node.status({fill:'green',shape:'dot',text:'RUNNING'}); }\n    else if (mode === 'FLY') { node.status({fill:'blue',shape:'ring',text:'FLY - checking config'}); }\n    else if (mode === 'PGM') { node.status({fill:'yellow',shape:'ring',text:'CONFIG MODE'}); }\n    else if (mode === 'ACK') { node.status({fill:'blue',shape:'dot',text:'ACK - parameter received'}); }\n    else if (mode === 'MOFF') { node.status({fill:'grey',shape:'dot',text:'MOTOR OFF'}); }\n}\nelse if (topic === 'Config Results') {\n    var allOk = true;\n    for (var key in payload) {\n        if (key==='addr'||key==='time'||key==='_msgid') continue;\n        if (typeof payload[key]==='boolean' && !payload[key]) allOk=false;\n    }\n    node.status(allOk ? {fill:'green',shape:'dot',text:'CONFIG COMPLETE'} : {fill:'red',shape:'dot',text:'CONFIG PARTIAL'});\n}\nelse if (topic === 'OTN Request Results') { node.status({fill:'blue',shape:'ring',text:'OTN - config window extended'}); }\nelse if (topic === 'sensor_data') {\n    var sd = payload.sensor_data || {};\n    node.status({fill:'green',shape:'dot',text:'DATA: ODR='+(sd.odr||'?')});\n}\nreturn msg;","outputs":1,"timeout":"","noerr":0,"initialize":"","finalize":"","libs":[],"x":530,"y":340,"wires":[["6477cdc59e76f51a"]]},{"id":"6477cdc59e76f51a","type":"debug","z":"fb2d99fb28f6bd92","name":"Config Log","active":true,"tosidebar":true,"console":false,"tostatus":false,"complete":"true","targetType":"full","statusVal":"","statusType":"auto","x":760,"y":340,"wires":[]},{"id":"537f632755853b18","type":"ncd-wireless-node","z":"fb2d99fb28f6bd92","name":"Sensor","connection":"bd2072265d713085","config_comm":"bd2072265d713085","addr":"00:13:a2:00:42:30:75:68","sensor_type":"110","auto_config":true,"on_the_fly_enable":true,"node_id_delay_active":"","node_id":0,"delay":300,"form_network":"","destination_active":"","destination":"0000FFFF","power_active":"","power":4,"retries_active":"","retries":10,"pan_id_active":"","pan_id":"7FFF","mode_110_active":true,"mode_110":"2","odr_p1_110_active":true,"odr_p1_110":"14","sampling_duration_p1_110_active":true,"sampling_duration_p1_110":"99","full_scale_range_101_active":true,"full_scale_range_101":"3","payload_length_80_active":true,"payload_length_80":3,"max_raw_sample_110_active":true,"max_raw_sample_110":"8100","sampling_interval_110_active":true,"sampling_interval_110":"0","x":290,"y":340,"wires":[["a848f0ea372974ec"]]},{"id":"592d8829822452ac","type":"ncd-gateway-node","z":"fb2d99fb28f6bd92","name":"Wireless Gateway","connection":"bd2072265d713085","unknown_devices":0,"outputs":1,"x":400,"y":200,"wires":[["58bc4be060ac636f","d1f2e16aeb742fa2"]]},{"id":"bd2072265d713085","type":"ncd-gateway-config","name":"MODEM","comm_type":"serial","ip_address":"","tcp_port":2101,"tcp_inactive_timeout_active":false,"tcp_inactive_timeout":1200,"port":"PLACEHOLDER_PORT","baudRate":115200,"pan_id":"7fff","rssi":false},{"id":"b9613d4faf0e214a","type":"global-config","env":[],"modules":{"@ncd-io/node-red-enterprise-sensors":"1.4.7"}}]'''

flow = json.loads(flow_json)
for node in flow:
    if node.get('type') == 'ncd-gateway-config':
        node['port'] = serial_port
    if node.get('type') == 'file':
        node['filename'] = csv_path
    if node.get('type') == 'function' and 'PLACEHOLDER_CSV' in node.get('func',''):
        node['func'] = node['func'].replace('PLACEHOLDER_CSV', csv_path)

with open(output_path, 'w') as f:
    json.dump(flow, f, indent=4)
print(f"  ✓ Flow saved to: {output_path}")
PYEOF

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================="
echo " Setup Complete!"
echo "============================================="
echo ""
echo " NEXT STEPS:"
echo " 1. Remove the USB stick"
echo " 2. Reboot:              sudo reboot"
echo " 3. CM5 will now boot from eMMC"
echo " 4. After reboot:"
echo "    a. Start Node-RED:   node-red-start"
echo "    b. Open browser:     http://localhost:1880"
echo "    c. Menu → Import → select:"
echo "       $HOME/ncd_flow_patched.json"
echo "    d. Click Deploy"
echo ""
echo " Serial port:  $SERIAL_PORT"
echo " CSV saves to: $HOME/Desktop/vibration_data.csv"
echo " Flow file:    $HOME/ncd_flow_patched.json"
echo " Setup log:    $LOGFILE"
echo ""
echo " Screenshots (after reboot):"
echo "   Print Screen         → PNG to Desktop"
echo "   Shift+Print Screen   → region to clipboard (15s)"
echo ""
echo " FACTORY RESET (anytime — back to this state):"
echo "   1. Flash Raspberry Pi OS to USB stick using Raspberry Pi Imager"
echo "   2. Plug USB into CM5, power on (boots USB automatically as fallback)"
echo "   3. Run:  bash ncd_setup.sh"
echo "   4. Remove USB, reboot"
echo "============================================="
