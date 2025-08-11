#!/usr/bin/env bash
# nuc_status.sh — Quick posture check for a Home-Automation NUC (Ubuntu/Debian)
# Usage: sudo ./nuc_status.sh [output_file]
# If no output_file is provided, a timestamped file will be created in the current directory.

set -Eeuo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "⚠️  This script works best with root privileges (sudo) to see firewall/ports/services."
  echo "    Continuing anyway..."
fi

OUT="${1:-nuc_status_$(hostname)_$(date +%F_%H%M%S).txt}"
mkdir -p "$(dirname "$OUT")"
# Tee all output to the file
exec > >(tee -a "$OUT") 2>&1

has() { command -v "$1" >/dev/null 2>&1; }

hdr() {
  printf "\n\n############################## %s ##############################\n" "$1"
}

ts() { date '+%F %T %Z'; }

echo "NUC Status Report — $(ts)"
echo "Host: $(hostnamectl --static 2>/dev/null || hostname)"
echo "User: $(id -un)    Kernel: $(uname -r)    Arch: $(uname -m)"
if has lsb_release; then
  echo "OS:   $(lsb_release -ds)"
elif [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "OS:   ${PRETTY_NAME:-unknown}"
fi
echo "Uptime: $(uptime -p 2>/dev/null || true)"
echo "Load:   $(cut -d' ' -f1-3 /proc/loadavg)"
echo "Temps:  $(sensors 2>/dev/null | sed -n '1,10p' || true)"

hdr "Time & Sync"
timedatectl 2>/dev/null || true
has chronyc && chronyc tracking 2>/dev/null || true

hdr "Network — Interfaces, IPs, Routes, DNS"
has ip && ip -br addr 2>/dev/null || true
echo
has ip && ip route show 2>/dev/null || true
echo
if has resolvectl; then
  resolvectl status 2>/dev/null | sed -n '1,120p' || true
else
  echo "/etc/resolv.conf:"
  sed -n '1,80p' /etc/resolv.conf 2>/dev/null || true
fi

if has tailscale; then
  hdr "Tailscale"
  tailscale status 2>/dev/null || true
  echo "Tailscale IPs: $(tailscale ip -4 2>/dev/null || true) $(tailscale ip -6 2>/dev/null || true)"
fi

if has nmcli; then
  hdr "NetworkManager — device summary"
  nmcli -g GENERAL.DEVICE,GENERAL.TYPE,IP4.ADDRESS,IP4.GATEWAY,IP.DNS device show 2>/dev/null | sed -n '1,200p' || true
fi

hdr "Firewall"
FW_DETECTED=0
if has ufw; then
  echo "### UFW"
  systemctl is-enabled ufw >/dev/null 2>&1 && echo "UFW unit: enabled" || echo "UFW unit: disabled"
  systemctl is-active ufw >/dev/null 2>&1 && echo "UFW service: active" || echo "UFW service: inactive"
  ufw status verbose 2>/dev/null || true
  FW_DETECTED=1
fi
if has firewall-cmd; then
  echo "### firewalld"
  firewall-cmd --state 2>/dev/null || true
  firewall-cmd --get-active-zones 2>/dev/null || true
  firewall-cmd --list-all 2>/dev/null || true
  FW_DETECTED=1
fi
if has nft; then
  echo "### nftables ruleset (first 200 lines)"
  nft list ruleset 2>/dev/null | sed -n '1,200p' || true
  FW_DETECTED=1
fi
if has iptables; then
  echo "### iptables (filter & nat — first 120 lines each)"
  iptables -L -n -v --line-numbers 2>/dev/null | sed -n '1,120p' || true
  iptables -t nat -L -n -v --line-numbers 2>/dev/null | sed -n '1,120p' || true
  FW_DETECTED=1
fi
if [[ "$FW_DETECTED" -eq 0 ]]; then
  echo "No firewall tooling detected (ufw/firewalld/nft/iptables not found)."
fi

hdr "Listening Ports & Owning Processes"
PORT_TOOL=0
if has ss; then
  echo "### ss (TCP/UDP listeners)"
  ss -tulpen 2>/dev/null | sort -k5 || true
  PORT_TOOL=1
fi
if has netstat && [[ $PORT_TOOL -eq 0 ]]; then
  echo "### netstat (fallback)"
  netstat -tulpen 2>/dev/null | sort -k4 || true
  PORT_TOOL=1
fi
if has lsof; then
  echo
  echo "### lsof (who owns the ports — first 200 lines)"
  lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null | sed -n '1,200p' || true
  PORT_TOOL=1
fi
if [[ $PORT_TOOL -eq 0 ]]; then
  echo "No port tools found (ss/netstat/lsof). Consider: sudo apt install iproute2 net-tools lsof"
fi

hdr "Host Services (failed + enabled)"
systemctl --failed 2>/dev/null || true
echo
systemctl list-unit-files --state=enabled 2>/dev/null | sed -n '1,120p' || true

hdr "Shares & Discovery"
if has testparm; then
  echo "Samba (smb.conf) — effective settings:"
  testparm -s 2>/dev/null | sed -n '1,200p' || true
  echo
  has smbstatus && smbstatus -S 2>/dev/null || true
else
  echo "Samba utilities not found (install: sudo apt install samba smbclient)."
fi
if has exportfs; then
  echo "NFS exports:"
  exportfs -v 2>/dev/null || true
else
  echo "NFS server utilities not found (install: sudo apt install nfs-kernel-server)."
fi
echo
echo "Current NFS/CIFS mounts:"
grep -E ' nfs4? | cifs ' /proc/mounts | awk '{print $1, "on", $2, $3, $4}' || true
echo
if has avahi-browse; then
  echo "mDNS/Bonjour services (snapshot):"
  avahi-browse -at 2>/dev/null | sed -n '1,120p' || true
else
  echo "avahi-browse not found (install: sudo apt install avahi-utils)."
fi

hdr "Storage — Disks, Filesystems, Mounts"
if has lsblk; then
  lsblk -e7 -o NAME,MODEL,SIZE,TYPE,FSTYPE,FSUSED,FSUSE%,MOUNTPOINTS,LABEL
fi
echo
df -hT -x tmpfs -x devtmpfs || true
echo
findmnt -rno SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null | sed -n '1,200p' || true

hdr "Docker — Engine"
if has docker; then
  docker info 2>/dev/null | sed -n '1,120p' || true
  echo
  echo "Docker images (top 15 by size):"
  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}' | head -n 15 || true

  hdr "Docker — Running Containers (name, image, status, ports)"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true

  echo
  echo "Per-container details (networks, IPs, mounts, restart policy):"
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    echo "→ $c"
    docker inspect -f '  Image: {{.Config.Image}}' "$c" 2>/dev/null || true
    docker inspect -f '  Networks: {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}' "$c" 2>/dev/null || true
    docker inspect -f '  PublishedPorts: {{range .NetworkSettings.Ports}}{{println .}} {{end}}' "$c" 2>/dev/null | sed 's/^/    /' || true
    docker inspect -f '  Mounts: {{range .Mounts}}{{.Source}}:{{.Destination}} ({{.Type}}) {{end}}' "$c" 2>/dev/null || true
    docker inspect -f '  RestartPolicy: {{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || true
  done < <(docker ps --format '{{.Names}}')
  
  echo
  echo "Docker networks:"
  docker network ls || true
  echo
  if docker compose version >/dev/null 2>&1; then
    echo "Docker Compose projects:"
    docker compose ls || true
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose projects:"
    docker-compose ls || true
  fi
else
  echo "Docker not found."
fi

hdr "Containers of Interest (Frigate, Mosquitto, Zigbee2MQTT, Home Assistant)"
if has docker; then
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -Ei 'frigate|mosquitto|zigbee2mqtt|home[-_ ]assistant' || true
fi

hdr "Security — SSH, Fail2ban, AppArmor/SELinux"
if has sshd; then
  echo "OpenSSH server config (effective – subset):"
  sshd -T 2>/dev/null | egrep -i '^(port|addressfamily|listenaddress|passwordauthentication|permitrootlogin|pubkeyauthentication|kexalgorithms|ciphers|macs) ' || true
else
  echo "sshd binary not found (OpenSSH server likely not installed)."
fi
if has fail2ban-client; then
  fail2ban-client status 2>/dev/null || true
else
  echo "Fail2ban not found."
fi
if has aa-status; then
  aa-status 2>/dev/null || true
elif has apparmor_status; then
  apparmor_status 2>/dev/null || true
else
  echo "AppArmor tools not found."
fi
if has getenforce; then
  getenforce 2>/dev/null || true
elif [[ -f /etc/selinux/config ]]; then
  echo "SELinux config present:"
  sed -n '1,40p' /etc/selinux/config || true
else
  echo "SELinux not detected."
fi

hdr "CPU/Memory Snapshot"
echo "CPU: $(lscpu 2>/dev/null | egrep -i 'Model name|CPU\\(s\\)|Thread|Socket|Vendor ID' | sed -e 's/^[ \t]*//' || true)"
free -h 2>/dev/null || true
echo
ps -eo pid,ppid,cmd,%cpu,%mem --sort=-%cpu | head -n 15

hdr "DMI/Hardware (short)"
if has dmidecode; then
  dmidecode -t 1 2>/dev/null | egrep -i 'Manufacturer|Product Name|Version|Serial Number' || true
else
  echo "dmidecode not found."
fi

echo
echo "✅ Report saved to: $OUT"
