# Backup GenieACS

Repo ini berisi **backup penuh** instalasi GenieACS dari server lama, termasuk:

- Program GenieACS yang sudah dimodifikasi
- File service systemd
- Backup database MongoDB
- Script installer otomatis

---

## Struktur Folder & File

- `config/`  
  Berisi file konfigurasi GenieACS  
  - `genieacs.env` / `genieacs.env.example`  
  - `*.json` (config lain)

- `scripts/`  
  Berisi script helper, terutama:
  - `scripts/genieacs_install_restore.sh` → installer + restore otomatis.

- `genieacs_program.tar.gz`  
  Arsip **/opt/genieacs** dari server lama  
  (kode GenieACS + `node_modules` versi yang sudah dimodif).

- `genieacs_systemd.tar.gz`  
  Arsip file service systemd:
  - `genieacs-cwmp.service`
  - `genieacs-nbi.service`
  - `genieacs-fs.service`
  - `genieacs-ui.service`

- `backup_mongo_dump_genieacs.tar.gz`  
  Backup database MongoDB (hasil `mongodump` dari server lama).

> Catatan: folder `mongo_dump/` hanya dipakai sementara saat backup/restore, dan **tidak di-commit** ke Git.

---

## Cara Install + Restore (OTOMATIS) – Direkomendasikan

### 1. Siapkan server baru

- OS: Ubuntu Server (disarankan 22.04 / jammy)
- Login sebagai `root` atau user dengan `sudo`

### 2. Install Git & clone repo

```bash
apt update && apt install -y git

git clone https://github.com/addysetiawan19041996-cmd/genieacs-backup.git
cd genieacs-backup
