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

---

## ✅ Ce que je VEUX

- ✅ Commandes exactes, prêtes à coller (pas de pseudocode)
- ✅ Chemins de fichiers absolus ou relatifs au workspace
- ✅ Références aux fichiers existants quand pertinent
- ✅ Diagrammes mermaid pour les workflows complexes (sans `"` ni `()` dans `[]`)
- ✅ Tableaux de comparaison quand il y a des alternatives
- ✅ Justification technique pour chaque décision non triviale
- ✅ Critères de validation mesurables par phase

---

## 📐 Format de réponse

```markdown
# Plan — Gestion partagée GPU Calypso

## Synthèse exécutive (5 lignes max)

## Architecture cible (diagramme mermaid)

## Phase 0 — [Nom] (priorité: critique)
### Objectif
### Décisions techniques
### Étapes
### Validation
### Risques

## Phase 1 — [Nom]
...

## Annexes
### A. Commandes de référence
### B. Schéma JSON audit log
### C. Topics MQTT
### D. Références fichiers existants
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

---

## 🎬 Démarre maintenant

Produis le plan complet. Sois exhaustif sur les phases 0 et 1 (stabilisation + partage GPU), détaillé sur les phases 2-4 (monitoring, audit, scheduling). N'hésite pas à challenger mes choix si tu vois une meilleure approche — je veux un **plan senior**, pas une validation.
