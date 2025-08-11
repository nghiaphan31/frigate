#!/usr/bin/env bash
# nuc_audit_commit.sh — Run NUC audit, produce raw + stable reports, and commit to Git.

set -Eeuo pipefail

REPO="${REPO:-/opt/sys-audit}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-/usr/local/sbin/nuc_status.sh}"

mkdir -p "$REPO/reports/history"
RAW="$REPO/reports/history/nuc_status_$(hostname)_$(date +%F_%H%M%S).txt"
STABLE="$REPO/reports/latest.txt"

# 1) Run the full audit (best with sudo, but not required)
if [[ ! -x "$AUDIT_SCRIPT" ]]; then
  echo "ERROR: audit script not found or not executable at $AUDIT_SCRIPT" >&2
  exit 1
fi
if [[ "${EUID:-$(id -u)}" -ne 0 ]] && sudo -n true 2>/dev/null; then
  sudo "$AUDIT_SCRIPT" "$RAW"
else
  "$AUDIT_SCRIPT" "$RAW"
fi

# 2) Build a stable, diff-friendly summary (tolerate benign failures)
tmp="$(mktemp)"
(
  set +e  # don't fail this block on minor command exits or pipefail
  echo "Stable NUC summary — $(date -u '+%F %T UTC')"
  echo "Host: $(hostnamectl --static 2>/dev/null || hostname)"
  if [[ -f /etc/os-release ]]; then . /etc/os-release; echo "OS:   ${PRETTY_NAME:-}"; fi

  echo; echo "## Network (addr/route/DNS)"
  command -v ip >/dev/null && ip -br addr 2>/dev/null | sort
  echo
  command -v ip >/dev/null && ip route show 2>/dev/null | sort
  echo; echo "DNS:"
  if command -v resolvectl >/dev/null; then
    resolvectl dns 2>/dev/null | sort
    resolvectl domain 2>/dev/null | sort
  elif [[ -f /etc/resolv.conf ]]; then
    sed -n '1,80p' /etc/resolv.conf 2>/dev/null | sed 's/[ \t]\+/ /g'
  fi

  echo; echo "## Firewall (UFW + nft/iptables)"
  command -v ufw >/dev/null && ufw status verbose 2>/dev/null
  if command -v nft >/dev/null; then
    nft list ruleset 2>/dev/null | awk '/^table/ || /^chain/'
  elif command -v iptables >/dev/null; then
    iptables -S 2>/dev/null
  fi

  echo; echo "## Listening ports (numeric, no PIDs)"
  if command -v ss >/dev/null; then
    ss -tulnH 2>/dev/null | sort -k5
  elif command -v netstat >/dev/null; then
    netstat -tuln 2>/dev/null | sed '1,2d' | sort -k4
  fi

  echo; echo "## Shares"
  command -v testparm  >/dev/null && testparm -s 2>/dev/null
  command -v exportfs  >/dev/null && exportfs -v 2>/dev/null

  echo; echo "## Mounts (fstab + active)"
  echo "/etc/fstab:"
  [[ -r /etc/fstab ]] && sed 's/#.*$//' /etc/fstab | sed '/^\s*$/d' | sed -E 's/[ \t]+/ /g'
  echo
  command -v findmnt >/dev/null && findmnt -rno SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null | sort

  echo; echo "## Docker (containers, ports, mounts, restart)"
  if command -v docker >/dev/null; then
    docker ps --format ' - {{.Names}}  {{.Image}}  {{.Ports}}  {{.Status}}' 2>/dev/null | sort
    while read -r c; do
      [[ -z "$c" ]] && continue
      echo "   [$c]"
      docker inspect -f '     Ports: {{range $k,$v := .NetworkSettings.Ports}}{{printf "%s " $k}}{{end}}' "$c" 2>/dev/null || true
      docker inspect -f '     Mounts: {{range .Mounts}}{{.Destination}}<{{.Type}}> {{end}}' "$c" 2>/dev/null || true
      docker inspect -f '     Restart: {{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null || true
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)
  else
    echo "(docker not installed)"
  fi

  echo; echo "## SSH (effective subset)"
  if command -v sshd >/dev/null; then
    sshd -T 2>/dev/null | egrep '^(port|addressfamily|listenaddress|passwordauthentication|permitrootlogin|pubkeyauthentication) ' || true
  fi

  echo; echo "## Key config file checksums (sha256)"
  shopt -s nullglob
  files=(/etc/nftables.conf /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ssh/sshd_config /etc/samba/smb.conf /etc/fstab /etc/docker/daemon.json /etc/netplan/*.yaml)
  for f in "${files[@]}"; do [[ -f "$f" ]] && sha256sum "$f"; done
  for f in /opt/*/docker-compose*.yml /srv/*/docker-compose*.yml; do [[ -f "$f" ]] && sha256sum "$f"; done
) > "$tmp"
mv "$tmp" "$STABLE"
chmod 0644 "$STABLE"

echo "Report (raw):    $RAW"
echo "Report (stable): $STABLE"

# 3) Commit (and optionally push) — never fail the job on push
cd "$REPO"
if [[ ! -d .git ]]; then
  git init
  git add .
  git -c user.name='NUC Audit Bot' -c user.email='nuc@local' commit -m "init: sys-audit repo on $(date -u +%F)"
fi

git add "reports/history/$(basename "$RAW")" "reports/latest.txt"
if git diff --cached --quiet; then
  echo "No material changes detected in stable summary; skipping commit."
else
  git -c user.name='NUC Audit Bot' -c user.email='nuc@local' commit -m "audit: $(hostname) $(date '+%F %T %Z')"
  if [[ -n "${GIT_PUSH:-}" ]]; then
    git push || echo "WARN: push failed (non-fatal)" >&2
  fi
fi

exit 0
