# CAS – Q3-PREP-GPHOTOS – Checkpoint du 2025-11-18

## 1. Contexte

Cette note documente l’état atteint au 2025-11-18 pour l’intégration de Google Photos dans le CAS, à partir du Takeout **photos_2025-11-09**.

Elle se place **après** les étapes :
- **W5** : Manifest FROZEN large pour photos (W5 manifest wide).
- **W6** : Ingestion des médias Google Photos dans le **POOL** (`/mnt/nas/truth/objects`).
- **W7** : Index SHA256 + infos Google Photos pour le snapshot `photos_2025-11-09`.
- **W8** : Construction des **Capsules** Google Photos pour `photos_2025-11-09` (meta.json alignés avec le schéma `cas.capsule.media.gphotos.v1`).

Objectif : servir de **préparation** à Q3-IDX-BOOTSTRAP / Q3-IDX-REBUILD et, plus tard, au nettoyage sélectif côté Google Photos cloud.

---

## 2. Résumé des étapes exécutées

### 2.1 W6 – Ingest Google Photos → POOL

- Script : `w6_ingest_photos_to_cas.sh`
- Manifest source :  
  `/mnt/nas/truth/ledger/cas/reports/w5_manifest_FROZEN_20251109T075852_20251112T230343_WIDE_4b7304c1c66d.tsv`
- POOL cible : `/mnt/nas/truth/objects/sha256`
- Ledger détaillé W6 :  
  `/mnt/nas/truth/ledger/cas/logs/w6_ingest_photos_20251116T160706Z.jsonl`
- Résumé W6 (ligne summary du ledger W6) :
  - `lines`: 205127  
  - `processed`: 205126  
  - `ok`: 129737  
  - `exists`: 75389  
  - `failed`: 0  
  - `dryrun`: 0  

Une entrée synthétique a été ajoutée au **macro-ledger** :

- Fichier : `/mnt/nas/truth/ledger/cas/ledger.jsonl`
- Dernier event W6 : `w6_ingest_photos_full`  
  avec `manifest`, `processed`, `ok`, `exists`, `failed=0`, `note` expliquant qu’il s’agit du full ingest du Takeout `photos_2025-11-09` dans le POOL.

Post-check W6 :
- Script : `w6_postcheck_counts.sh`
- Vérification : `processed == copy_ok + exists` ✅  
- Pas d’événement `failed` dans le ledger W6 ✅

---

### 2.2 W7 – Index SHA256 / Google Photos

- Script : `w7_build_gphotos_hash_index.py`
- Sortie principale (TSV) :  
  `/mnt/nas/truth/ledger/cas/reports/w7_gphotos_hash_index_photos_2025-11-09.tsv`
- Contenu :
  - 1 ligne de header.
  - 142431 lignes de données (`wc -l = 142432`).
- Colonnes clés (extrait) :
  - `sha256`
  - `pool_relpath` (relatif à `/mnt/nas/truth/objects`)
  - `size`
  - `ext`, `kind`, `album`, `year`
  - `media_path` (chemin flatten STAGING)
  - `relpath` (Takeout/Google Photos/…)
  - `sidecar_json`, `supp_json`
  - `takeout_snapshot_id` = `photos_2025-11-09`
  - `manifest_line_first`, `manifest_lines_all` (références vers W5 manifest)

Ce TSV W7 est la **vue tabulaire** de la relation :
> hash ↔ POOL ↔ chemin Google Photos ↔ métadonnées Takeout

---

### 2.3 W8 – Capsules Google Photos (meta.json)

- Script : `w8_build_gphotos_capsules.py`
- Snapshot ID : `photos_2025-11-09`
- Base des capsules (CAPS_ROOT) :  
  `/mnt/nas/truth/cas/med/_CAPSULES/gphotos/photos_2025-11-09`
- POOL : `/mnt/nas/truth/objects`

Pour chaque SHA256, une capsule est créée sous :

- `CAPS_ROOT/aa/<hash>/meta.json`  
  avec `aa` = les 2 premiers hex digits du hash.

Logs W8 :
- Global W8 JSONL :  
  `/mnt/nas/truth/ledger/cas/logs/w8_gphotos_capsules_photos_2025-11-09_20251118T075921Z.jsonl`  
  - events:
    - `start`
    - `capsule_written` (un par capsule)

Post-check W8 :
- Script : `w8_postcheck_gphotos_capsules.sh`
- Log postcheck :  
  `/mnt/nas/truth/ledger/cas/logs/w8_capsules_postcheck_photos_2025-11-09_YYYYMMDDTHHMMSSZ.jsonl`
- Résumé :
  - Lignes W7 (data, sans header) : **142431**
  - Capsules `meta.json` trouvées : **142431**
  - SHA W7 == SHA capsules ✅
  - `schema_version` attendu présent partout (`cas.capsule.media.gphotos.v1`) ✅
- Conclusion W8-POSTCHECK : **OK**

Entrée macro-ledger W8 :
- Fichier : `/mnt/nas/truth/ledger/cas/ledger.jsonl`
- Event : `w8_gphotos_capsules_photos_2025-11-09`
- Champs principaux :
  - `snapshot_id`: `photos_2025-11-09`
  - `w7_tsv`: chemin TSV
  - `caps_root`: CAPS_ROOT
  - `w7_lines_total`, `w7_lines_data`, `capsules`
  - `note`: W8 capsules built for Google Photos Takeout snapshot `photos_2025-11-09`

---

## 3. Invariants validés au 2025-11-18

1. **Single POOL** :  
   Tous les objets Google Photos du snapshot `photos_2025-11-09` sont maintenant:
   - soit **présents dans le POOL** (`copy_ok` W6),
   - soit déjà présents d’une exécution antérieure (`exists` W6).  
   Aucune ingestion W6 n’écrit en dehors de `/mnt/nas/truth/objects/sha256`.

2. **Lien POOL ↔ W7 ↔ Capsules** :
   - Pour chaque ligne de données W7 (`sha256`), on a :
     - un fichier `obj` dans le POOL (`pool_relpath`),
     - une capsule `meta.json` correspondante sous CAPS_ROOT.
   - W7 et W8-POSTCHECK confirment que l’ensemble de SHA est identique.

3. **Capsules auto-suffisantes (gphotos v1)** :
   - Chaque `meta.json` suit le schéma officiel `cas.capsule.media.gphotos.v1` :
     - bloc `object` (sha256, size, mime, pool_relpath)
     - bloc `media_core` (date, type, dimensions, etc.)
     - bloc `google_photos` (takeout_snapshot_id, relpaths, albums, labels…)
     - bloc `provenance`
     - bloc `relations`
     - bloc `audit`
   - Les relations nécessaires pour reconstruire les graphes (albums, libellés, etc.) sont portées par les capsules, indépendamment de la base SQLite.

4. **Traçabilité** :
   - Chaque étape W6, W7, W8 a :
     - un **ledger JSONL détaillé**,
     - une **entrée agrégée** dans le macro-ledger `ledger.jsonl`,
     - des scripts versionnés dans `~/git/nuc-docker-stack` (run cards W6/W7/W8).

---

## 4. Artefacts principaux à connaître

- POOL (objets uniques) :
  - `/mnt/nas/truth/objects/sha256/.../obj`

- Manifest W5 (source de W6) :
  - `/mnt/nas/truth/ledger/cas/reports/w5_manifest_FROZEN_20251109T075852_20251112T230343_WIDE_4b7304c1c66d.tsv`

- Ledger W6 :
  - `/mnt/nas/truth/ledger/cas/logs/w6_ingest_photos_20251116T160706Z.jsonl`

- Index W7 :
  - `/mnt/nas/truth/ledger/cas/reports/w7_gphotos_hash_index_photos_2025-11-09.tsv`

- Capsules W8 :
  - `/mnt/nas/truth/cas/med/_CAPSULES/gphotos/photos_2025-11-09/**/meta.json`

- Logs W8 :
  - `/mnt/nas/truth/ledger/cas/logs/w8_gphotos_capsules_photos_2025-11-09_*.jsonl`
  - `/mnt/nas/truth/ledger/cas/logs/w8_capsules_postcheck_photos_2025-11-09_*.jsonl`

- Macro-ledger CAS :
  - `/mnt/nas/truth/ledger/cas/ledger.jsonl`  
    (événements `w6_ingest_photos_full` et `w8_gphotos_capsules_photos_2025-11-09` présents).

---

## 5. Prochaines étapes (Q3-PREP-GPHOTOS)

1. **Q3-IDX-BOOTSTRAP (global)**  
   - Utiliser POOL + Capsules (gphotos + autres sources) pour construire l’index SQLite global (`cas_index_v1.sqlite`), en respectant le schéma figé pour `meta.json`.
   - W7/W8 servent de **référence** et de cas de test représentatif (volume significatif, Google Photos riche en métadonnées).

2. **Q3-IDX-REBUILD (procédure officielle)**  
   - Documenter et automatiser la reconstruction de l’index à partir de POOL + Capsules (sans dépendre du ledger).
   - Utiliser ce snapshot `photos_2025-11-09` comme mini-corpus pour valider les scripts de rebuild.

3. **Préparation du nettoyage Google Photos (cloud)**  
   - À moyen terme : définir une stratégie pour repérer **côté cloud** les éléments qui sont garantis comme capturés dans ce snapshot `photos_2025-11-09` (en tenant compte des limites de l’API/GUI Google Photos).
   - Objectif : ne jamais supprimer dans le cloud que ce qui est :
     - présent dans le POOL,
     - couvert par des capsules valides,
     - et clairement lié à un snapshot Takeout daté.

4. **Intégration dans le pipeline CAS global**  
   - Intégrer ce flux Google Photos dans le plan général CAS (U(T), manifests, UI pré-ingestion, etc.).
   - Faire de `photos_2025-11-09` un **cas témoin** pour tester les futures vues RAG (recherche sémantique, “photos de travaux”, etc.), à partir des capsules.

---

## 6. Résumé exécutif

- Le snapshot Google Photos **photos_2025-11-09** est désormais :
  - ingéré dans le **POOL**,
  - indexé dans un TSV W7,
  - encapsulé via des `meta.json` conformes au schéma gphotos v1,
  - contrôlé par W8-POSTCHECK,
  - et tracé dans le macro-ledger CAS.

Ce checkpoint Q3-PREP-GPHOTOS fixe une base solide pour :
- la construction/reconstruction de l’index CAS global (Q3-IDX-BOOTSTRAP / Q3-IDX-REBUILD),
- et, plus tard, un nettoyage contrôlé du cloud Google Photos à partir de snapshots bien identifiés.
