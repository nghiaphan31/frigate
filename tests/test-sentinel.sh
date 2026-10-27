#!/usr/bin/env bash
# ==============================================================================
# tests/test-sentinel.sh — Non-destructive verification test for Calypso Sentinel
# ==============================================================================
set -euo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "PASS: $desc"
        ((PASS++)) || true
    else
        echo "FAIL: $desc"
        ((FAIL++)) || true
    fi
}

echo "=== [TEST 1/5] Contrôle de Santé du Démon Sentinel ==="
check "calypso-sentinel.service is active" systemctl is-active calypso-sentinel.service

echo "=== [TEST 2/5] Validation du Payload MQTT (timeout 70s) ==="
PAYLOAD=$(mosquitto_sub -h 192.168.50.125 -u mosquitto -P mosquitto \
    -t "calypso/sentinel/state" -C 1 -W 70 2>/dev/null || true)
if echo "$PAYLOAD" | jq -e '.status and .gpu.vram_free_mib and .storage.nvme_free_gb' >/dev/null 2>&1; then
    echo "PASS: MQTT state payload conforms to schema."
    ((PASS++)) || true
else
    echo "FAIL: MQTT payload invalid or not received within 70s. Raw: $PAYLOAD"
    ((FAIL++)) || true
fi

echo "=== [TEST 3/5] Test Non-Bloquant du Healthcheck Frigate Découplé ==="
check "Frigate decoupled healthcheck (onnx1.pid + uptime)" \
    docker exec frigate sh -c \
    "curl -sf http://127.0.0.1:5000/api/stats | jq -e '(.detectors.onnx1.pid > 0) and ((.service.uptime // .uptime // 0) > 0)'"

echo "=== [TEST 4/5] Validation des Métriques VictoriaMetrics ==="
check "VictoriaMetrics scrape targets reachable and healthy" \
    bash -c "curl -sf http://127.0.0.1:8428/api/v1/targets | python3 -c \"import sys,json; d=json.load(sys.stdin); targets=d.get('data',{}).get('activeTargets',[]); exit(0 if len(targets)>=3 and all(t.get('health')=='up' for t in targets) else 1)\""

echo "=== [TEST 5/5] Validation des Portiers Pre-Flight ==="
check "cas-container-ready.sh returns 0 for healthy cas-core" \
    /usr/local/bin/cas-container-ready.sh cas-core 15.0
check "cas-gpu-gate.sh returns 0 with relaxed threshold (2000 MiB)" \
    /usr/local/bin/cas-gpu-gate.sh 2000 80

echo ""
echo "=== RÉSULTATS : ${PASS} tests réussis, ${FAIL} tests échoués ==="
[ "$FAIL" -eq 0 ] && echo "✅ TOUS LES TESTS SENTINEL ONT RÉUSSI AVEC SUCCÈS" || { echo "❌ DES TESTS ONT ÉCHOUÉ — Vérifier les logs ci-dessus"; exit 1; }

