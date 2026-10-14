# Standard Operating Procedure (SOP): Frigate+ Model Field Testing & Benchmarking

**Date:** 2026-10-14  
**Target Environment:** Calypso Host (192.168.50.12) — NVIDIA RTX 5060 Ti (16 GB)  
**Baseline Model:** `plus://c1aa04320f389aa6c7702bf9ddd3fe6d` (`c1aa0432`)  
**Scope:** Procedure to capture baseline metrics, deploy a newly trained Frigate+ ONNX model, compile the TensorRT engine, execute physical walk tests, and verify end-to-end Home Assistant security escalations.

---

## 1. Pre-requisites & Baseline Capture (Before Upgrading)

Before modifying any configuration or model hash, capture the quantitative performance of the running baseline model (`c1aa0432`).

### 1.1 Run Training-Need Evaluator
Run the live statistical score evaluator against the local Frigate API:
```bash
cd /home/nghia-phan/AGENTIC_DEVELOPMENT_PROJECTS/APPLICATION-PROJECTS/frigate
make evaluate
```
* **Metrics to note**:
  * Percentile scores ($p_{10}, p_{25}, p_{50}, p_{75}, p_{90}$) per camera.
  * Count of events in the **borderline band** ($0.30 \le \text{top\_score} < 0.55$).
  * Any camera marked `[BORDER]` or `[NEED ]`.

### 1.2 Capture 14-Stage Pipeline State Snapshot
Record the live health state across all video streams, NVDEC decoders, and detect processes:
```bash
make pipeline-report-snapshot SNAPSHOT_PATH=tests/baselines/pipeline-pre-upgrade-c1aa0432.json
```

---

## 2. Model Retrieval & Configuration Update

### 2.1 Verify Frigate+ Credentials
Ensure your Frigate+ API key is active in the Calypso environment:
```bash
grep -E '^FRIGATE_PLUS_API_KEY=' .env
```

### 2.2 Obtain the New Model Hash
1. Log in to [plus.frigate.video](https://plus.frigate.video).
2. Go to your models dashboard and copy the Model ID of the latest completed training run (e.g. `plus://<NEW_MODEL_HASH>`).

### 2.3 Update `config.yml`
Edit [`config.yml`](../config.yml#L233) line 233:
```yaml
model:
  path: plus://<NEW_MODEL_HASH>
```

### 2.4 Validate Configuration Syntax
Run the static configuration linter:
```bash
make test-config
```
*Must return: `PASS: config.yml syntax & schema valid`.*

---

## 3. TensorRT Engine Recompilation on Calypso

Because Calypso runs an **NVIDIA RTX 5060 Ti**, Frigate downloads the raw ONNX model and compiles a hardware-optimized TensorRT `.engine` binary.

### 3.1 Stop Frigate Container
```bash
docker compose -f docker-compose.calypso.yml stop frigate
```

### 3.2 Purge Engine Cache
Remove the compiled TensorRT cache so the new model is compiled cleanly:
```bash
rm -rf trt-cache/tensorrt/ort/trt-engines/*
```
*(Note: Do not delete other cache folders to preserve embeddings and models).*

### 3.3 Start Frigate & Monitor Compilation
```bash
docker compose -f docker-compose.calypso.yml start frigate
docker logs -f frigate
```
* **Expected duration**: ~65 seconds on RTX 5060 Ti.
* **Look for**:
  ```text
  [INFO] Building new TensorRT engine for plus://...
  [INFO] TensorRT engine build completed successfully.
  [INFO] Detector started (inference speed ~5ms).
  ```

### 3.4 Verify Stack Bring-up & Geometric Math
```bash
./bring-up.sh
make test
```
*Both `test-config` and `test-math` must exit 0.*

---

## 4. Physical Walk-Test Protocol

Conduct a physical test walk across the property to validate real-world detection in outdoor conditions.

### 4.1 Test Vectors & Postures
Cover the 5 outdoor camera zones:
1. **`allee_sur_le_cote`**: Walk from far driveway gate ($20\,\text{m}$) down to house ($3\,\text{m}$).
2. **`jardin_devant`**: Cross front yard from fence line ($15\,\text{m}$) to porch.
3. **`vue_entree`**: Stand on doorstep directly in front of doorbell ($1.7\,\text{m}$ eye-level).
4. **`piscine_vue_toit`**: Walk across pool deck / terrace ($5\,\text{m} - 20\,\text{m}$).
5. **`jardin_arriere`**: Walk across back lawn toward shed.
6. **Postures to Test**:
   * Standard upright walking.
   * Brisk walking / running.
   * Crouching / bending over (verifies $H/W$ aspect ratio tolerance).
   * Carrying a bulky object / bag.

### 4.2 Inspect Walk Events Chronologically
Immediately following the walk test, run:
```bash
make walk WALK_MINUTES=10
```
* **Verification Checklist**:
  * Did each camera generate an event with `label: person`?
  * Was `top_score` consistently high ($\ge 0.85$)?
  * Did events in the private yard correctly overlap zone `prive`?
  * Open the snapshot URLs in a browser to inspect bounding-box tightness.

---

## 5. Statistical Comparison & Regression Audit

### 5.1 Re-evaluate Score Distribution
```bash
make evaluate
```
* Compare against the baseline captured in Step 1:
  * Has the median score ($p_{50}$) increased (e.g. from $\sim 0.80$ to $\ge 0.90$)?
  * Has the borderline band ($0.30 - 0.55$) dropped to 0 across all cameras?

### 5.2 Check for Pipeline Drift
```bash
make pipeline-report-diff BASE=tests/baselines/pipeline-pre-upgrade-c1aa0432.json
```
* **Criteria**: Exit code 0 (no unexpected stream failures, frame drops, or GPU throttling).

---

## 6. End-to-End Home Assistant Integration Verification

Verify the 2-layer notification architecture configured in Home Assistant Core (192.168.50.125):

### 6.1 Layer 1 Verification (Single Camera)
1. Walk into the field of view of **one camera only** (e.g. `allee_sur_le_cote`).
2. Check your iPhone:
   * **Result**: A standard, silent notification banner arrives (`⚠️ Présence détectée (Zone PRIVÉE)`).
   * **Media**: Snapshot thumbnail includes the red bounding box around you.
   * **Deterrence**: Confirm **no** sirens, floodlights, or loud indoor chimes are triggered.

### 6.2 Layer 2 Verification (Multi-Camera Confirmation)
1. Within 60 seconds of Step 6.1, walk into the view of a **second camera** (e.g. `vue_entree` or `jardin_devant`).
2. Check your iPhone:
   * **Result**: **Apple Critical Alert** fires at maximum volume (`🚨 INTRUSION CONFIRMÉE (2 Caméras)`), bypassing Do Not Disturb.
   * **Deterrence**: Reolink floodlights switch on, outdoor siren activates, and indoor salon chime rings.
   * **Logbook**: Home Assistant logbook displays:
     `🚨 Intrusion confirmée par 2 caméras (Allée sur le côté ➜ Vue Entrée en X s).`

---

## 7. Rollback Procedure

If the new model exhibits regressions (e.g. false positives on water reflections or missed person detections):

1. Revert `model.path` in [`config.yml`](../config.yml) back to baseline:
   ```yaml
   model:
     path: plus://c1aa04320f389aa6c7702bf9ddd3fe6d
   ```
2. Recompile engine:
   ```bash
   docker compose -f docker-compose.calypso.yml stop frigate
   rm -rf trt-cache/tensorrt/ort/trt-engines/*
   docker compose -f docker-compose.calypso.yml start frigate
   ./bring-up.sh
   ```
