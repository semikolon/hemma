#!/usr/bin/env bash
# Generate firstrun.sh for RPi OS Trixie headless provisioning
# Called by hemma prepare-sd — not intended for direct use
#
# Args: <output_path> <hostname> <user> <pass_hash> <wifi_ssid> <wifi_password>
set -euo pipefail

output="$1"
hostname="$2"
user="$3"
pass_hash="$4"
wifi_ssid="$5"
wifi_password="$6"

cat > "$output" << 'FIRSTRUNEOF'
#!/bin/bash
set +e

# --- Hostname ---
CURRENT_HOSTNAME=$(cat /etc/hostname | tr -d " \t\n\r")
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_hostname __HOSTNAME__
else
   echo __HOSTNAME__ >/etc/hostname
   sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t__HOSTNAME__/g" /etc/hosts
fi

# --- User ---
FIRSTUSER=$(getent passwd 1000 | cut -d: -f1)
FIRSTUSERHOME=$(getent passwd 1000 | cut -d: -f6)
if [ -f /usr/lib/userconf-pi/userconf ]; then
   /usr/lib/userconf-pi/userconf '__USER__' '__PASS_HASH__'
else
   echo "$FIRSTUSER:'__PASS_HASH__'" | chpasswd -e
   if [ "$FIRSTUSER" != "__USER__" ]; then
      usermod -l "__USER__" "$FIRSTUSER"
      usermod -m -d "/home/__USER__" "__USER__"
      groupmod -n "__USER__" "$FIRSTUSER"
      if [ -f /etc/sudoers.d/010_pi-nopasswd ]; then
         sed -i "s/^$FIRSTUSER /__USER__ /" /etc/sudoers.d/010_pi-nopasswd
      fi
   fi
fi

# --- SSH ---
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom enable_ssh
else
   systemctl enable ssh
fi

# --- WiFi via NetworkManager ---
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan '__WIFI_SSID__' '__WIFI_PASSWORD__' 'SE'
else
   cat >/etc/NetworkManager/system-connections/__WIFI_SSID__.nmconnection <<'NMEOF'
[connection]
id=__WIFI_SSID__
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=__WIFI_SSID__

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=__WIFI_PASSWORD__

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
   chmod 600 /etc/NetworkManager/system-connections/__WIFI_SSID__.nmconnection
   rfkill unblock wifi
   for filename in /var/lib/systemd/rfkill/*:wlan ; do
      echo 0 > "$filename"
   done
fi

# --- Regulatory domain ---
if [ -f /usr/lib/raspberrypi-sys-mods/imager_custom ]; then
   /usr/lib/raspberrypi-sys-mods/imager_custom set_wlan_country 'SE'
else
   iw reg set SE
fi

# --- Locale ---
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- Cleanup ---
rm -f /boot/firmware/firstrun.sh
sed -i 's| systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target||g' /boot/firmware/cmdline.txt
exit 0
FIRSTRUNEOF

# Replace placeholders with actual values
# Use | as sed delimiter to avoid conflicts with / in paths and hashes
sed -i.bak "s|__HOSTNAME__|${hostname}|g" "$output"
sed -i.bak "s|__USER__|${user}|g" "$output"
sed -i.bak "s|__PASS_HASH__|${pass_hash}|g" "$output"
sed -i.bak "s|__WIFI_SSID__|${wifi_ssid}|g" "$output"
sed -i.bak "s|__WIFI_PASSWORD__|${wifi_password}|g" "$output"
rm -f "${output}.bak"
