# Prompt Antigravity / Gemini — Architecte Senior GPU partagé

> **Usage** : copier-coller le bloc ci-dessous dans Antigravity ou Gemini.
> **Contexte** : incident GPU wedging sur Calypso (RTX 5060 Ti 16 GB) causé par 5 workloads concurrents.

---

## 🎯 Rôle

Tu es un **architecte senior systèmes** spécialisé en infrastructure GPU partagée (NVIDIA, CUDA, conteneurs Docker, systemd, observabilité). Tu as 15 ans d'expérience sur des plateformes ML/NVR multi-workloads. Tu produis des plans **actionnables**, **phasés**, et **justifiés** — pas du blabla générique.

---

## 📋 Contexte de la mission

### Incident racine (2026-10-10)

Le host **Calypso** (Linux 6.17, driver NVIDIA 570+, GPU **RTX 5060 Ti 16 GB**) a subi un wedging GPU complet. Diagnostic :

```
[Demucs ou Immich ML batch nuit]
    └─► CUDA error path → command queue dans un état invalide
        └─► GPU WEDGED → tous les cuInit() échouent
            ├─► Frigate : plus de détection
            ├─► Immich ML : embeddings échouent
            └─► gnome-shell (PID 4188, user gdm) : rendu écran échoue
                └─► nvidia_drm refcount > 0 → rmmod impossible
                    └─► Recovery = reboot obligatoire
```

**Cause aggravante** : GNOME desktop compositor (gnome-shell) tient le GPU ouvert pour le rendu. C'est lui qui a bloqué le `rmmod nvidia_drm`.

### Workloads en concurrence (5)

| Workload | Criticité | GPU mem | Comportement |
|---|---|---|---|
| **Frigate** (TRT, 3 caméras Reolink) | **P1 — temps réel** | ~4–6 GB | `docker-compose.calypso.yml`, `frigate-stack.service` |
| **cas-immich-ml** (CLIP embeddings) | P2 — background | ~2–4 GB | conteneur séparé |
| **cas-core** (OCR) | P2 — background | ~1–2 GB | conteneur séparé |
| **Demucs** (séparation audio) | P3 — idle | ~2–4 GB | batch manuel |
| **gnome-shell** (compositeur) | inutile | ~0.5 GB | session GDM locale |

### Repositories concernés (5 + host)

Chaque workload vit dans son **propre repository Git**. Le plan doit explicitement tagger chaque livrable avec son repo cible. Aucun changement transverse ne doit être proposé sans préciser dans quel repo il vit.

| Repo | Rôle | Chemin local假设 | Branche |
|---|---|---|---|
| **frigate** (ce repo) | NVR + détection TRT | `/home/nghia-phan/.../frigate` | `understanding_current_pipeline` |
| **cas-core** | OCR + logique métier | repo séparé | branche stable |
| **cas-immich-ml** | CLIP embeddings | repo séparé | branche stable |
| **cas-immich-server** | API Immich (GPU indirect) | repo séparé | branche stable |
| **demucs** | Séparation audio | repo séparé ou local-only | manuelle |
| **calypso-host** (pas un repo) | Config host : nvidia-ctk, DCGM, Prometheus, audit log, watchdog partagé | `/etc/`, `/usr/local/bin/`, `/var/log/` | n/a |

**Mécanisme de coordination inter-repos** :
- **MQTT** : `calypso_frigate/maintenance/gpu-state` (broadcast état GPU), `calypso_frigate/maintenance/throttle` (commandes)
- **Système de fichiers** : `/var/log/gpu-audit.jsonl` (audit partagé, append-only)
- **systemd dependencies** : `After=frigate-stack.service` sur les units P2/P3
- **Shared env file** : `/etc/calypso-gpu.env` (mémoire dispo, seuils, état current)

### Contraintes matérielles

- **GPU grand public** : pas de MIG (réservé A100/H100), pas de vGPU
- **16 GB total** : budget mémoire serré pour 4 workloads ML
- **Time-slicing NVIDIA** : disponible (Ampere+), partage le compute mais pas la mémoire
- **CUDA MPS** : disponible mais mono-utilisateur, complexe跨 conteneurs

### Infrastructure existante (à respecter / étendre)

- [`docker-compose.calypso.yml`](docker-compose.calypso.yml:1) — Frigate seul, `runtime: nvidia`, devices explicites
- [`frigate-stack.service`](frigate-stack.service:1) — systemd unit, `ExecStart=bring-up.sh`, `SuccessExitStatus=0`
- [`frigate-stack-watchdog.service`](frigate-stack-watchdog.service:1) + [`.timer`](frigate-stack-watchdog.timer:1) — toutes les 5 min
- [`frigate-cleanup.sh`](frigate-cleanup.sh:1) — retention NAS, MQTT `calypso_frigate/maintenance/cleanup`
- [`bring-up.sh`](bring-up.sh:1) — 14 étapes de validation pipeline
- MQTT broker : `192.168.50.125:1883` (Mosquitto sur Home Assistant)
- Accès : VS Code remote (SSH) sur Calypso, user `nghia-phan`, sudo via [`sudoers/nghia-phan-frigate`](sudoers/nghia-phan-frigate:1)

---

## 🎯 Exigences (non négociables)

1. **Frigate ne perd jamais une frame** à cause d'un autre workload
2. **Aucun wedging GPU non détecté** pendant > 2 min
3. **Recovery automatique** sans intervention humaine dans 90 % des cas
4. **Traçabilité complète** : qui utilise quoi, quand, combien (audit log)
5. **Pas de contention mémoire** : chaque workload a un budget plafonné
6. **GNOME n'utilise plus le GPU** (cause aggravante éliminée)

---

## 📦 Livrable attendu

Un **plan d'implémentation détaillé** structuré en phases, avec pour chaque phase :

- **Objectif** mesurable
- **Décisions techniques** justifiées (et alternatives rejetées avec rationale)
- **Étapes concrètes** (commandes, fichiers à créer/modifier, chemins exacts)
- **Critères de validation** (comment savoir que la phase est terminée)
- **Risques** et mitigations
- **Estimation de complexité** (S/M/L, pas de durée)
- **🏷️ Repo cible** : tag explicite par étape (frigate / cas-core / cas-immich-ml / cas-immich-server / demucs / calypso-host)

### Règle de mapping par repository (non négociable)

**Chaque livrable doit être tagué avec son repo cible.** Un changement qui touche plusieurs repos doit être découpé en sous-étapes, une par repo. Exemples :

```markdown
- [ ] **frigate** : modifier `frigate-stack.service` pour ajouter `Nice=-10`
- [ ] **cas-immich-ml** : créer `cas-immich-ml.service` avec `After=frigate-stack.service`
- [ ] **calypso-host** : installer DCGM via `apt install datacenter-gpu-manager`
```

Le plan doit inclure un **tableau récapitulatif** par phase :

| Étape | Repo cible | Fichiers touchés | Dépend de |
|---|---|---|---|
| ... | frigate | `docker-compose.calypso.yml`, `frigate-stack.service` | — |
| ... | cas-core | `docker-compose.yml`, `cas-core.service` | frigate phase 1 |
| ... | calypso-host | `/etc/nvidia/...`, `/usr/local/bin/gpu-watchdog.sh` | phase 1 |

Et un **diagramme de dépendances inter-repos** (mermaid) montrant l'ordre de déploiement.

Le plan doit couvrir **toutes** ces dimensions :

### A. Partage GPU
- Time-slicing NVIDIA : config, slices, impact perfs
- Plafonds mémoire par conteneur (mécanisme : `CUDA_MEMPOOL_SIZE`, cgroups, ou wrapper)
- Priorités : systemd `Nice=`, `IOSchedulingClass=`, `CPUQuota=`
- CUDA MPS : pertinent ou pas dans ce contexte ?

### B. Isolation & crash prevention
- Comment empêcher un workload de wedge le GPU pour les autres
- Memory limits pour éviter les OOM
- Watchdog GPU dédié (en plus du `frigate-stack-watchdog` actuel)
- Seuils : température, ECC, power, util stuck

### C. Recovery
- Procédure auto : stop conteneurs → rmmod → modprobe → restart progressif
- Procédure manuelle (SSH, pas de TTY)
- Cap sur les reboots auto (éviter boucle)

### D. Monitoring & observabilité
- DCGM : quelles métriques, quels seuils
- Prometheus + dcgm-exporter : scrape interval, retention
- Grafana : dashboards (overview, Frigate vs contention, historique incidents)
- Alertes MQTT vers HA : schéma JSON, topics, niveaux

### E. Traçabilité & audit
- Format audit log (JSON par ligne, champs minimaux)
- Rotation, retention, compression
- Requêtes utiles pour analyse post-incident
- Corrélation workload ↔ métriques GPU

### F. Scheduling intelligent
- Timers systemd pour P2/P3 (heures off-peak)
- Throttle dynamique basé sur `frigate_detection_fps`
- API de contrôle (optionnel)

### G. Maintenance long terme
- KPIs de succès
- Tâches récurrentes (quotidien/hebdo/mensuel)
- Évolution future (2e GPU, migration CPU, etc.)

---

## 🚫 Ce que je ne veux PAS

- ❌ Plan générique copié-collé d'un tiel "GPU sharing best practices"
- ❌ Recommandations vagues type "consider monitoring" ou "implement observability"
- ❌ Estimation de durée en heures/jours
- ❌ Sections "Future work" sans valeur immédiate
- ❌ Ignorer les contraintes matérielles (pas de MIG sur RTX 5060 Ti)
- ❌ Proposer des solutions qui cassent l'infra existante (Frigate doit continuer à marcher)
- ❌ **Livrables non tagués par repo** — si je ne sais pas dans quel repo aller commit, le plan est inutilisable
- ❌ **Proposer un monorepo** ou une refacto transverse qui mélange les workloads
- ❌ **Ignorer les branches existantes** — chaque repo a sa branche stable, le plan doit préciser la stratégie de merge
- ❌ **Oublier le calypso-host** — les changements host (nvidia-ctk, DCGM, audit log) ne vivent dans aucun des 5 repos

---

## ✅ Ce que je VEUX

- ✅ Commandes exactes, prêtes à coller (pas de pseudocode)
- ✅ Chemins de fichiers absolus ou relatifs au workspace
- ✅ Références aux fichiers existants quand pertinent
- ✅ Diagrammes mermaid pour les workflows complexes (sans `"` ni `()` dans `[]`)
- ✅ Tableaux de comparaison quand il y a des alternatives
- ✅ Justification technique pour chaque décision non triviale
- ✅ Critères de validation mesurables par phase
- ✅ **Chaque étape taggée par repo** (frigate / cas-core / cas-immich-ml / cas-immich-server / demucs / calypso-host)
- ✅ **Tableau de mapping global** par phase (repo × livrables × dépendances)
- ✅ **Diagramme de dépendances inter-repos** (mermaid flowchart)
- ✅ **Ordre de déploiement** clair : phases 100 % host d'abord, puis frigate (le plus critique), puis P2/P3
- ✅ **Stratégie de merge** par repo : branche feature, PR, ordre de déploiement
- ✅ **Mécanisme de coordination explicite** : topics MQTT, fichier de shared env, audit log partagé

---

## 📐 Format de réponse

```markdown
# Plan — Gestion partagée GPU Calypso

## Synthèse exécutive (5 lignes max)

## Architecture cible (diagramme mermaid)

## Mapping par repository (tableau global)

| Phase | Repo | Livrables | Dépend de |
|---|---|---|---|
| 0 | calypso-host | désactiver GNOME GPU, gpu-recovery.sh | — |
| 0 | frigate | étendre watchdog avec health check GPU | — |
| 1 | calypso-host | activer time-slicing, créer /etc/calypso-gpu.env | phase 0 |
| 1 | frigate | plafonner mem 6 GB, Nice=-10 | phase 1 host |
| 1 | cas-immich-ml | plafonner mem 3 GB, Nice=0, After=frigate | phase 1 host + frigate |
| 1 | cas-core | plafonner mem 2 GB, Nice=0, After=frigate | phase 1 host + frigate |
| 1 | demucs | plafonner mem 2 GB, Nice=+10, déclenchement manuel | phase 1 host |
| 2 | calypso-host | DCGM, Prometheus, Grafana, alertes MQTT | phase 1 |
| 3 | calypso-host | audit log JSON, gpu-usage-logger.sh | phase 2 |
| 3 | frigate | intégrer audit logger dans frigate-stack.service | phase 3 host |
| 3 | cas-immich-ml | intégrer audit logger dans cas-immich-ml.service | phase 3 host |
| 4 | calypso-host | timers systemd, throttle dynamique | phase 3 |

## Diagramme de dépendances inter-repos (mermaid)

```mermaid
flowchart LR
  HOST0[calypso-host: phase 0] --> FRG0[frigate: phase 0]
  HOST0 --> HOST1[calypso-host: phase 1]
  HOST1 --> FRG1[frigate: phase 1]
  HOST1 --> IMM1[cas-immich-ml: phase 1]
  HOST1 --> CAS1[cas-core: phase 1]
  HOST1 --> DEM1[demucs: phase 1]
  FRG1 --> HOST2[calypso-host: phase 2]
  HOST2 --> HOST3[calypso-host: phase 3]
  HOST3 --> FRG3[frigate: phase 3]
  HOST3 --> IMM3[cas-immich-ml: phase 3]
  HOST3 --> CAS3[cas-core: phase 3]
  HOST3 --> HOST4[calypso-host: phase 4]
```

## Phase 0 — [Nom] (priorité: critique, repos: calypso-host, frigate)
### Objectif
### Décisions techniques
### Étapes
  - [ ] **[calypso-host]** commande ou fichier
  - [ ] **[frigate]** commande ou fichier
  - [ ] **[cas-immich-ml]** commande ou fichier
  - [ ] **[cas-core]** commande ou fichier
### Validation
### Risques

## Phase 1 — [Nom] (repos: ...)
...

## Annexes
### A. Commandes de référence
### B. Schéma JSON audit log
### C. Topics MQTT
### D. Références fichiers existants
### E. Stratégie de merge par repo (branche, PR, ordre de déploiement)
```

---

## 🔗 Contexte technique additionnel

### Pipeline Frigate (résumé)
- 3 caméras Reolink Duo 3 (RTSP/H.264/TCP sur 192.168.50.129:8554)
- Capture ffmpeg avec CUDA hwaccel → shm 5 GB → detect ffmpeg → TRT inference
- MQTT publish sur `calypso_frigate/#` vers HA
- Enregistrements sur NAS `/mnt/nas/video/frigate_calypso`
- TRT cache persistant dans `./trt-cache` (~65s build au premier run)

### Stack actuelle
- Docker + nvidia-container-toolkit
- systemd pour orchestration
- Mosquitto MQTT pour events + alertes
- Pas de Prometheus/Grafana/DCGM installé (à ajouter)

### Philosophie de l'operator
- Préfère les solutions simples et robustes aux solutions "clever"
- Veut de la traçabilité (logs JSON, pas du texte libre)
- Accepte les compromis (ex: GNOME sans GPU = OK si on peut le démarrer à la demande)
- Aime les scripts bash bien commentés (voir [`frigate-cleanup.sh`](frigate-cleanup.sh:1) comme référence de style)

### Fichiers existants par repo (à respecter / étendre)

| Repo | Fichiers clés à connaître | Hypothèses |
|---|---|---|
| **frigate** (ce repo) | [`docker-compose.calypso.yml`](docker-compose.calypso.yml:1), [`frigate-stack.service`](frigate-stack.service:1), [`frigate-stack-watchdog.service`](frigate-stack-watchdog.service:1), [`frigate-stack-watchdog.timer`](frigate-stack-watchdog.timer:1), [`frigate-cleanup.sh`](frigate-cleanup.sh:1), [`bring-up.sh`](bring-up.sh:1), [`config.yml`](config.yml:1) | single container, `runtime: nvidia`, devices explicites |
| **cas-core** | `docker-compose.yml`, `cas-core.service`, `ocr/` | conteneur Python, GPU via `runtime: nvidia` |
| **cas-immich-ml** | `docker-compose.yml`, `cas-immich-ml.service`, `ml/` | conteneur PyTorch, modèle CLIP |
| **cas-immich-server** | `docker-compose.yml`, `cas-immich-server.service` | API REST, GPU indirect (appels à cas-immich-ml) |
| **demucs** | `docker-compose.yml` ou script shell | batch manuel, pas de systemd unit |

### Mécanisme de coordination inter-repos (détails)

Le plan doit spécifier **exactement** comment les repos se coordonnent sans couplage fort :

1. **Shared env file** : `/etc/calypso-gpu.env` (lu par tous les services via `EnvironmentFile=` dans systemd)
   ```bash
   # /etc/calypso-gpu.env (géré par calypso-host, lu par tous les repos)
   GPU_TOTAL_MEM_MB=16384
   GPU_FRIGATE_BUDGET_MB=6144
   GPU_IMMICH_BUDGET_MB=3072
   GPU_CAS_CORE_BUDGET_MB=2048
   GPU_DEMUCS_BUDGET_MB=2048
   GPU_AUDIT_LOG=/var/log/gpu-audit.jsonl
   GPU_MQTT_HOST=192.168.50.125
   GPU_MQTT_STATE_TOPIC=calypso_frigate/maintenance/gpu-state
   GPU_MQTT_THROTTLE_TOPIC=calypso_frigate/maintenance/throttle
   ```

2. **Audit log partagé** : `/var/log/gpu-audit.jsonl` (append-only, rotation logrotate)
   - Chaque systemd unit P1/P2/P3 a un `ExecStartPost` qui écrit une ligne JSON
   - Le watchdog host lit ce log et publie les alertes MQTT

3. **Topics MQTT de coordination** :
   - `calypso_frigate/maintenance/gpu-state` : broadcast état GPU (libre, wedged, recovering)
   - `calypso_frigate/maintenance/throttle` : commandes (pause/resume par workload)
   - `calypso_frigate/maintenance/audit` : événements d'audit (mirror du JSON log)

4. **systemd dependencies** :
   - `frigate-stack.service` : pas de dépendance (démarre en premier)
   - `cas-immich-ml.service`, `cas-core.service` : `After=frigate-stack.service` (démarrent après)
   - `demucs.service` : `After=frigate-stack.service`, manual trigger only

5. **Wrapper de démarrage** : `/usr/local/bin/gpu-usage-logger.sh` (calypso-host)
   - Appelé par chaque service via `ExecStartPost`
   - Lit `/etc/calypso-gpu.env` pour connaître son budget
   - Vérifie `nvidia-smi --query-gpu=memory.free` avant de démarrer
   - Si mémoire insuffisante : exit 1 + log + MQTT alert
   - Sinon : écrit ligne `start` dans audit log

### Stratégie de merge par repo

| Repo | Branche feature | Ordre de merge | Validation |
|---|---|---|---|
| **calypso-host** (pas un repo) | n/a — `git` local dans `/etc` ou ansible | 1er | `nvidia-smi` OK après reboot |
| **frigate** | `feature/gpu-isolation-phase-X` | 2ème (le plus critique) | `detection_fps > 0` pendant 24h |
| **cas-immich-ml** | `feature/gpu-isolation-phase-X` | 3ème | embeddings OK, mem < 3 GB |
| **cas-core** | `feature/gpu-isolation-phase-X` | 3ème (parallèle de cas-immich-ml) | OCR OK, mem < 2 GB |
| **demucs** | `feature/gpu-isolation-phase-X` | 4ème (le moins critique) | batch test OK |

---

## 🎬 Démarre maintenant

Produis le plan complet. Sois exhaustif sur les phases 0 et 1 (stabilisation + partage GPU), détaillé sur les phases 2-4 (monitoring, audit, scheduling). N'hésite pas à challenger mes choix si tu vois une meilleure approche — je veux un **plan senior**, pas une validation.
