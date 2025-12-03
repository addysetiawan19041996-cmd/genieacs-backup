#!/usr/bin/env bash
set -e

# ==== VERSI DISAMAKAN DENGAN SERVER LAMA ====
NODE_MAJOR=20       # dari: node -v  -> v20.19.2 => 20
MONGO_MAJOR=4.4     # dari: mongod --version -> 4.4.29 => 4.4
# ============================================

# Deteksi root repo (script boleh dijalankan dari mana saja)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="$REPO_ROOT/config"
SYSTEMD_DIR="$REPO_ROOT/systemd"
PROVISIONS_DIR="$REPO_ROOT/provisions"
BACKUP_TAR="$REPO_ROOT/backup_mongo_dump_genieacs.tar.gz"

echo "[*] Repo root: $REPO_ROOT"

echo "[*] Deteksi Ubuntu codename..."
if command -v lsb_release >/dev/null 2>&1; then
  UBUNTU_CODENAME=$(lsb_release -sc)
else
  UBUNTU_CODENAME=$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
fi
echo "    Codename: $UBUNTU_CODENAME"

echo "[*] Update apt & install tools dasar"
apt update
apt install -y curl gnupg ca-certificates lsb-release build-essential git

# =========================
# 1) Install Node.js
# =========================
echo
echo "[*] Install Node.js $NODE_MAJOR.x dari NodeSource"

curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg

echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt update
apt install -y nodejs

echo "[*] Versi Node.js terpasang:"
node -v || echo "Node.js tidak terpasang dengan benar!"

# =========================
# 2) Install MongoDB
# =========================
echo
echo "[*] Install MongoDB $MONGO_MAJOR dari repo resmi MongoDB"

# Trik: untuk 4.4 di Ubuntu 22.04 (jammy), pakai repo 'focal'
MONGO_OS_CODENAME="$UBUNTU_CODENAME"
if [ "$MONGO_MAJOR" = "4.4" ] && [ "$UBUNTU_CODENAME" = "jammy" ]; then
  echo "    -> UBUNTU jammy + Mongo 4.4: pakai repo focal (trik kompatibilitas)"
  MONGO_OS_CODENAME="focal"
fi

curl -fsSL https://pgp.mongodb.com/server-$MONGO_MAJOR.asc \
  | gpg --dearmor -o /usr/share/keyrings/mongodb-server-$MONGO_MAJOR.gpg

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_MAJOR.gpg ] https://repo.mongodb.org/apt/ubuntu $MONGO_OS_CODENAME/mongodb-org/$MONGO_MAJOR multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-$MONGO_MAJOR.list

apt update
apt install -y mongodb-org

systemctl enable mongod
systemctl start mongod

echo "[*] Versi MongoDB:"
mongod --version | head -n 3 || echo "mongod tidak berjalan!"

# Pastikan mongorestore ada
apt install -y mongodb-database-tools || true
if ! command -v mongorestore >/dev/null 2>&1; then
  echo "  ! mongorestore tidak ditemukan. Pastikan mongodb-database-tools terinstall."
fi

# =========================
# 3) Install GenieACS
# =========================

echo
echo "[*] Membuat user & direktori untuk GenieACS"

id -u genieacs >/dev/null 2>&1 || useradd -r -s /bin/false genieacs
mkdir -p /opt/genieacs
chown genieacs:genieacs /opt/genieacs

echo "[*] Install GenieACS via npm (global)"
# Kalau mau lock versi, bisa diganti: npm install -g genieacs@VERSI
npm install -g genieacs

# Opsional: symlink source ke /opt/genieacs/app
if [ -d /usr/local/lib/node_modules/genieacs ]; then
  ln -sf /usr/local/lib/node_modules/genieacs /opt/genieacs/app
fi

# =========================
# 4) Copy config + provisions dari repo
# =========================

echo
echo "[*] Copy konfigurasi dari repo ke /opt/genieacs"

mkdir -p /opt/genieacs/config
mkdir -p /opt/genieacs/provisions

# genieacs.env full (dengan password) dari repo
if [ -f "$CONFIG_DIR/genieacs.env" ]; then
  cp "$CONFIG_DIR/genieacs.env" /opt/genieacs/genieacs.env
  chown genieacs:genieacs /opt/genieacs/genieacs.env
  echo "    -> /opt/genieacs/genieacs.env disalin dari repo (full, termasuk password)"
else
  echo "  ! $CONFIG_DIR/genieacs.env tidak ditemukan. Script tidak bisa lanjut full otomatis."
fi

# JSON config
if ls "$CONFIG_DIR"/*.json 1>/dev/null 2>&1; then
  cp "$CONFIG_DIR"/*.json /opt/genieacs/config/ 2>/dev/null || true
  chown -R genieacs:genieacs /opt/genieacs/config
  echo "    -> Menyalin JSON config ke /opt/genieacs/config/"
else
  echo "  ! Tidak ada *.json di $CONFIG_DIR (abaikan kalau memang tidak pakai)"
fi

# Provisions
if [ -d "$PROVISIONS_DIR" ]; then
  cp -a "$PROVISIONS_DIR"/* /opt/genieacs/provisions/ 2>/dev/null || true
  chown -R genieacs:genieacs /opt/genieacs/provisions
  echo "    -> Menyalin provisions ke /opt/genieacs/provisions/"
else
  echo "  ! Folder provisions tidak ditemukan di repo"
fi

# =========================
# 5) Systemd service
# =========================

echo
echo "[*] Menyalin systemd service dari repo"

if ls "$SYSTEMD_DIR"/genieacs-*.service 1>/dev/null 2>&1; then
  cp "$SYSTEMD_DIR"/genieacs-*.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui
  echo "    -> Service GenieACS di-enable"
else
  echo "  ! Tidak ada file genieacs-*.service di $SYSTEMD_DIR"
fi

# =========================
# 6) Restore MongoDB
# =========================

echo
echo "[*] Restore MongoDB database 'genieacs' dari backup di repo"

if [ -f "$BACKUP_TAR" ]; then
  TMP_DIR="$REPO_ROOT/tmp_restore_mongo"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  echo "    -> Ekstrak $BACKUP_TAR ke $TMP_DIR"
  tar -xzf "$BACKUP_TAR" -C "$TMP_DIR"

  if [ -d "$TMP_DIR/mongo_dump/genieacs" ]; then
    RESTORE_DIR="$TMP_DIR/mongo_dump/genieacs"
  elif [ -d "$TMP_DIR/genieacs" ]; then
    RESTORE_DIR="$TMP_DIR/genieacs"
  else
    RESTORE_DIR=$(find "$TMP_DIR" -maxdepth 3 -type d -name "genieacs" | head -n1 || true)
  fi

  if [ -n "$RESTORE_DIR" ] && [ -d "$RESTORE_DIR" ]; then
    echo "    -> Menjalankan: mongorestore --drop --db genieacs $RESTORE_DIR"
    mongorestore --drop --db genieacs "$RESTORE_DIR"
    echo "    -> Restore MongoDB selesai"
  else
    echo "  ! Folder data genieacs tidak ditemukan di dalam tar. Cek struktur arsip."
  fi

  rm -rf "$TMP_DIR"
else
  echo "  ! File backup Mongo $BACKUP_TAR tidak ditemukan di repo."
fi

# =========================
# 7) Start service
# =========================

echo
echo "[*] Restart semua service GenieACS"
systemctl restart genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui || true

echo
echo "====================================================="
echo "INSTALL + RESTORE GENIEACS SELESAI"
echo "Server ini sekarang seharusnya mirip dengan server lama."
echo
echo "Checklist:"
echo "  - Cek status Mongo:         systemctl status mongod"
echo "  - Cek status GenieACS:      systemctl status genieacs-*"
echo "  - Coba akses UI:            http://IP_SERVER_BARU:3000"
echo "  - Sesuaikan nginx/apache jika dipakai reverse proxy."
echo "====================================================="
