# File: drumbrain-setup.sh
#!/bin/bash
set -e

# ------------------------------
#  ASCII HEADER + PROGRESS UI
# ------------------------------
print_header() {
  echo "//////////////////////////////////////"
  echo "//       DrumBrain Pi Setup         //"
  echo "// JACK + DrumGizmo Autostart v1.0  //"
  echo "//////////////////////////////////////"
  echo "Step / Task status will be shown below."
  echo
}

print_step() {
  local step="$1"
  local total="$2"
  local message="$3"
  local percent=$(( step * 100 / total ))
  printf "[%2d/%2d] %-45s (%3d%% complete)\n" "$step" "$total" "$message" "$percent"
}

TOTAL_STEPS=9
CURRENT_STEP=0

next_step() {
  CURRENT_STEP=$(( CURRENT_STEP + 1 ))
  print_step "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

# ------------------------------
#  BASIC SAFETY CHECKS
# ------------------------------
print_header

if [ "$(whoami)" != "pi" ]; then
  echo "ERROR: Please run this script as user 'pi' (not with sudo directly)."
  echo "Example: pi@drumbrain:~$ bash drumbrain-setup.sh"
  exit 1
fi

# ------------------------------
#  STEP 1: Install packages
# ------------------------------
next_step "Updating apt and installing required packages..."

sudo apt-get update -y
sudo apt-get install -y \
  jackd2 \
  jack-tools \
  drumgizmo \
  alsa-utils

# ------------------------------
#  STEP 2: Disable PipeWire / PulseAudio user services
# ------------------------------
next_step "Disabling PipeWire / WirePlumber / PulseAudio user services..."

# Disable and stop PipeWire + WirePlumber + PipeWire-Pulse for user 'pi'
systemctl --user disable --now pipewire.service pipewire.socket wireplumber.service pipewire-pulse.service 2>/dev/null || true
systemctl --user mask pipewire.service pipewire.socket wireplumber.service pipewire-pulse.service 2>/dev/null || true

# Best-effort disable PulseAudio user services if present
systemctl --user disable --now pulseaudio.service pulseaudio.socket 2>/dev/null || true

# ------------------------------
#  STEP 3: Ensure pi is in audio + realtime groups
# ------------------------------
next_step "Ensuring user 'pi' is in audio and realtime groups..."

sudo usermod -aG audio pi || true
sudo usermod -aG realtime pi || true

# ------------------------------
#  STEP 4: Realtime + memlock limits
# ------------------------------
next_step "Configuring realtime priority and memlock limits..."

sudo tee /etc/security/limits.d/audio.conf >/dev/null <<'EOF'
@audio   -  rtprio     95
@audio   -  memlock    unlimited
@realtime - rtprio     95
@realtime - memlock    unlimited
EOF

# ------------------------------
#  STEP 5: JACK start script
# ------------------------------
next_step "Creating /usr/local/bin/jackd_start.sh..."

sudo tee /usr/local/bin/jackd_start.sh >/dev/null <<'EOF'
#!/bin/bash
set -e

echo "[jackd_start] Waiting for ALSA cards to appear..."

# Wait up to ~10 seconds for ALSA to enumerate devices
for i in {1..50}; do
    CARD_LIST=$(aplay -l 2>/dev/null || true)
    if echo "${CARD_LIST}" | grep -qE 'USB Audio|USB Audio CODEC|Headphones'; then
        break
    fi
    sleep 0.2
done

# Re-grab the final card list after the wait
CARD_LIST=$(aplay -l 2>/dev/null || true)
echo "[jackd_start] ALSA card list:"
echo "${CARD_LIST}"

# Prefer USB audio interface (e.g. UMC22, “USB Audio CODEC”)
USB_CARD_INDEX=$(printf "%s\n" "${CARD_LIST}" | awk '/USB Audio|USB Audio CODEC/ {print $2; exit}' | tr -d ':')

if [ -n "${USB_CARD_INDEX}" ]; then
  CARD_NAME="hw:${USB_CARD_INDEX}"
  echo "[jackd_start] Using USB audio device: ${CARD_NAME}"
else
  # Fallback to bcm2835 Headphones if no USB audio found
  HP_CARD_INDEX=$(printf "%s\n" "${CARD_LIST}" | awk '/Headphones/ {print $2; exit}' | tr -d ':')
  if [ -n "${HP_CARD_INDEX}" ]; then
    CARD_NAME="hw:${HP_CARD_INDEX}"
    echo "[jackd_start] Using fallback Headphones device: ${CARD_NAME}"
  else
    echo "[jackd_start] No suitable audio device found (no USB Audio / USB Audio CODEC / Headphones)." >&2
    exit 1
  fi
fi

# Start JACK on the chosen device: 48kHz, 512 frames, 3 periods
exec /usr/bin/jackd -P75 -dalsa -d"${CARD_NAME}" -r48000 -p512 -n3
EOF

sudo chmod +x /usr/local/bin/jackd_start.sh

# ------------------------------
#  STEP 6: drumbrain-jackd.service
# ------------------------------
next_step "Configuring systemd service drumbrain-jackd.service..."

sudo tee /etc/systemd/system/drumbrain-jackd.service >/dev/null <<'EOF'
[Unit]
Description=DrumBrain JACK Audio Server
After=sound.target
Wants=sound.target

[Service]
Type=simple
User=pi
Environment=JACK_NO_AUDIO_RESERVATION=1
LimitRTPRIO=95
LimitMEMLOCK=infinity
ExecStart=/usr/local/bin/jackd_start.sh
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------
#  STEP 7: DrumGizmo start script
# ------------------------------
next_step "Creating /usr/local/bin/drumbrain_start.sh..."

sudo tee /usr/local/bin/drumbrain_start.sh >/dev/null <<'EOF'
#!/bin/bash
set -e

echo "[drumbrain_start] Waiting for JACK..."

# Wait up to ~10 seconds for JACK to expose playback ports
for i in {1..50}; do
    if /usr/bin/jack_lsp 2>/dev/null | grep -q "system:playback_1"; then
        echo "[drumbrain_start] JACK is up."
        break
    fi
    sleep 0.2
done

# Final check: if JACK still isn't exposing playback ports, bail
if ! /usr/bin/jack_lsp 2>/dev/null | grep -q "system:playback_1"; then
    echo "[drumbrain_start] JACK did not become ready, giving up." >&2
    exit 1
fi

DRUMKIT_DIR="/home/pi/drumkits/CrocellKit_Stereo_MIX"
KIT_XML="${DRUMKIT_DIR}/CrocellKit_full.xml"
MIDIMAP_XML="${DRUMKIT_DIR}/Midimap_full.xml"

echo "[drumbrain_start] Starting DrumGizmo with kit: ${KIT_XML} and midimap: ${MIDIMAP_XML}"

/usr/bin/drumgizmo -i jackmidi -I midimap="${MIDIMAP_XML}" -o jackaudio "${KIT_XML}"
EOF

sudo chmod +x /usr/local/bin/drumbrain_start.sh

# ------------------------------
#  STEP 8: drumbrain-drumgizmo.service
# ------------------------------
next_step "Configuring systemd service drumbrain-drumgizmo.service..."

sudo tee /etc/systemd/system/drumbrain-drumgizmo.service >/dev/null <<'EOF'
[Unit]
Description=DrumBrain DrumGizmo Engine
After=drumbrain-jackd.service
Requires=drumbrain-jackd.service
# Only start if the kit XML exists
ConditionPathExists=/home/pi/drumkits/CrocellKit_Stereo_MIX/CrocellKit_full.xml

[Service]
Type=simple
User=pi
LimitRTPRIO=90
LimitMEMLOCK=infinity
ExecStart=/usr/local/bin/drumbrain_start.sh
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------
#  STEP 9: JACK plumbing (auto-connect)
# ------------------------------
next_step "Creating JACK plumbing rules and service..."

# Connection rules: DrumGizmo stereo out -> system playback L/R
sudo tee /etc/jack-plumbing >/dev/null <<'EOF'
( connect "DrumGizmo:0-Left"  "system:playback_1" )
( connect "DrumGizmo:1-Right" "system:playback_2" )
EOF

sudo tee /etc/systemd/system/jack-plumbing.service >/dev/null <<'EOF'
[Unit]
Description=JACK Plumbing Autoconnect
After=drumbrain-jackd.service
Requires=drumbrain-jackd.service

[Service]
Type=simple
User=pi
ExecStart=/usr/bin/jack-plumbing /etc/jack-plumbing
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------
#  FINAL: reload systemd + enable services
# ------------------------------
echo
echo "Reloading systemd and enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable drumbrain-jackd.service jack-plumbing.service drumbrain-drumgizmo.service

echo
echo "════════════════════════════════════════"
echo "  DrumBrain setup complete (100% done)  "
echo "════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1) Ensure your drumkit files exist at:"
echo "       /home/pi/drumkits/CrocellKit_Stereo_MIX/CrocellKit_full.xml"
echo "       /home/pi/drumkits/CrocellKit_Stereo_MIX/Midimap_full.xml"
echo "  2) Reboot the Pi:"
echo "       sudo reboot"
echo "  3) After reboot, check status from SSH:"
echo "       systemctl status drumbrain-jackd"
echo "       systemctl status jack-plumbing"
echo "       systemctl status drumbrain-drumgizmo"
echo
echo "When the Teensy is built and sending MIDI to JACK,"
echo "DrumGizmo should already be running and auto-connected."
