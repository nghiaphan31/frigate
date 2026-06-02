#!/usr/bin/env bash
# debug-mqtt.sh — diagnose why Frigate can't stay connected to Mosquitto
# Run as a normal user from the Calypso host. Exits 0 if everything checks out.

set -uo pipefail

MQTT_HOST="${MQTT_HOST:-192.168.50.125}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"
CONTAINER="${CONTAINER:-frigate}"

echo "═══════════════════════════════════════════════════════════════════════"
echo "  Frigate ↔ Mosquitto diagnostic"
echo "  $(date -u +'%Y-%m-%dT%H:%M:%SZ')  host=$(hostname)"
echo "═══════════════════════════════════════════════════════════════════════"

PASS=0
FAIL=0
WARN=0
note() {
    local status="$1" msg="$2"
    case "$status" in
        PASS) PASS=$((PASS+1)); printf "  [  OK  ] %s\n" "$msg" ;;
        FAIL) FAIL=$((FAIL+1)); printf "  [ FAIL ] %s\n" "$msg" ;;
        WARN) WARN=$((WARN+1)); printf "  [ WARN ] %s\n" "$msg" ;;
    esac
}

# 1) Host → broker reachability
echo
echo "── 1/5  Broker reachable from Calypso host ──"
if timeout 3 bash -c ">/dev/tcp/$MQTT_HOST/$MQTT_PORT" 2>/dev/null; then
    note PASS "$MQTT_HOST:$MQTT_PORT TCP open"
else
    note FAIL "$MQTT_HOST:$MQTT_PORT unreachable (firewall? wrong IP?)"
fi

# 2) Host → broker with same creds (subscribe to a wildcard for 5s)
echo
echo "── 2/5  Host → broker with user/pass (subscribe # for 5s) ──"
SUB_OUT=$(timeout 5 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" -t '#' -W 5 2>&1 || true)
if echo "$SUB_OUT" | grep -qiE '(not authorised|connection refused|error|errno)'; then
    note FAIL "host subscribe FAILED:"
    echo "$SUB_OUT" | sed 's/^/         /'
elif echo "$SUB_OUT" | grep -q '^$'; then
    note PASS "host subscribe connected (no msgs in 5s = no publish; connection worked)"
else
    note PASS "host subscribe: $SUB_OUT"
fi

# 3) Frigate container log: actual disconnect reason
echo
echo "── 3/5  Frigate container log: MQTT details ──"
DOCKER_LOGS=$(docker logs --tail=500 "$CONTAINER" 2>&1)
RC_LINES=$(echo "$DOCKER_LOGS" | grep -iE 'rc=[0-9]|not author|bad user|connection refused|server unavailable|identifier rejected' | tail -10)
if [ -n "$RC_LINES" ]; then
    echo "         (root cause likely here)"
    echo "$RC_LINES" | sed 's/^/         /'
    if echo "$RC_LINES" | grep -qi 'rc=5'; then
        note FAIL "rc=5: not authorised — Mosquitto ACL denies this user"
    elif echo "$RC_LINES" | grep -qi 'rc=4'; then
        note FAIL "rc=4: bad user/pass — username or password wrong"
    elif echo "$RC_LINES" | grep -qi 'rc=3'; then
        note FAIL "rc=3: server unavailable — broker offline or wrong port"
    elif echo "$RC_LINES" | grep -qi 'rc=2'; then
        note FAIL "rc=2: identifier rejected — invalid client_id"
    fi
else
    note WARN "no paho-mqtt rc= codes in log; reason unclear"
    echo "         (last 5 MQTT-related log lines):"
    echo "$DOCKER_LOGS" | grep -iE 'mqtt' | tail -5 | sed 's/^/         /'
fi

# 4) Frigate container: can it reach the broker?
echo
echo "── 4/5  Frigate container → broker reachability ──"
CONTAINER_PROBE=$(docker exec "$CONTAINER" sh -c \
    "wget -qO- http://$MQTT_HOST:$MQTT_PORT --timeout=2 2>&1; echo exit=\$?" 2>&1 | tail -1)
if [ -n "$CONTAINER_PROBE" ] && ! echo "$CONTAINER_PROBE" | grep -q 'exit=4'; then
    note PASS "container can reach $MQTT_HOST:$MQTT_PORT (HTTP probe got a response)"
else
    note FAIL "container CANNOT reach $MQTT_HOST:$MQTT_PORT — network issue"
fi

# 5) Mosquitto broker ACL inspect (best-effort — try via SNMP / RPC if available)
echo
echo "── 5/5  Mosquitto broker introspection ──"
ACL_OUT=$(timeout 3 mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" -t '\$SYS/broker/log/N' -W 3 2>&1 | head -5 || true)
if [ -n "$ACL_OUT" ]; then
    echo "         (broker log access via \$SYS works — ACL is permissive for this user)"
    echo "$ACL_OUT" | sed 's/^/         /'
else
    note WARN "could not read \$SYS/broker/log/N — ACL likely restrictive"
fi

echo
echo "───────────────────────────────────────────────────────────────────────"
echo "  SUMMARY: $PASS PASS, $WARN WARN, $FAIL FAIL"
echo "───────────────────────────────────────────────────────────────────────"
echo
echo "If FAIL on step 2 (host subscribe), the broker is blocking the credentials."
echo "    Check on the NAS: /etc/mosquitto/mosquitto.conf and mosquitto_passwd -l /etc/mosquitto/passwd"
echo
echo "If FAIL on step 3 (rc=5), the user is fine but the ACL denies the topic pattern."
echo "    Check on the NAS: cat /etc/mosquitto/acl.conf"
echo
echo "If FAIL on step 4 (container reach), it's a network problem between"
echo "    Calypso and the NAS. Check routing, firewall, Tailscale state."
echo

[ "$FAIL" -eq 0 ]
