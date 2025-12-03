#!/usr/bin/env bash
set -e

# ==== Versi lingkungan yang diharapkan (sesuai server lama) ====
NODE_MAJOR=20
MONGO_MAJOR=4.4
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_DIR="$REPO_ROOT/config"
BACKUP_TAR="$REPO_ROOT/backup_mongo_dump_genieacs.tar.gz"
PROGRAM_TAR="$REPO_ROOT/genieacs_program.tar.gz"
SYSTEMD_TAR="$REPO_ROOT/genieacs_systemd.tar.gz"

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
apt install -y curl gnupg ca-certificates lsb-release build-essential git openssl || true

# -------------------------
# Helper: pastikan libssl1.1 ada (untuk Mongo 4.4 di jammy)
# -------------------------
ensure_libssl11() {
  if dpkg -s libssl1.1 >/dev/null 2>&1; then
    echo "    -> libssl1.1 sudah terpasang"
    return 0
  fi

  echo "    -> libssl1.1 belum ada, mencoba download dari security.ubuntu.com ..."
  local FILE="libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb"

  cd /root
  if [ ! -f "$FILE" ]; then
    wget "http://security.ubuntu.com/ubuntu/pool/main/o/openssl/$FILE"
  fi

  dpkg -i "$FILE" || apt -f install -y || true

  if dpkg -s libssl1.1 >/dev/null 2>&1; then
    echo "    -> libssl1.1 terpasang"
  else
    echo "    !! Gagal memasang libssl1.1, MongoDB $MONGO_MAJOR mungkin tidak bisa dipasang"
  fi
}

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

echo "[*] Versi Node.js:"
node -v || echo "  ! Node.js tidak terpasang dengan benar"

# =========================
# 2) Install MongoDB
# =========================
echo
echo "[*] Install MongoDB $MONGO_MAJOR dari repo resmi MongoDB"

MONGO_OS_CODENAME="$UBUNTU_CODENAME"
if [ "$MONGO_MAJOR" = "4.4" ] && [ "$UBUNTU_CODENAME" = "jammy" ]; then
  echo "    -> Ubuntu jammy + Mongo 4.4: pakai repo focal + libssl1.1"
  MONGO_OS_CODENAME="focal"
fi

curl -fsSL "https://pgp.mongodb.com/server-$MONGO_MAJOR.asc" \
  | gpg --dearmor -o "/usr/share/keyrings/mongodb-server-$MONGO_MAJOR.gpg"

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_MAJOR.gpg ] https://repo.mongodb.org/apt/ubuntu $MONGO_OS_CODENAME/mongodb-org/$MONGO_MAJOR multiverse" \
  > "/etc/apt/sources.list.d/mongodb-org-$MONGO_MAJOR.list"

apt update

# Khusus jammy + 4.4, pastikan libssl1.1 ada sebelum install
if [ "$MONGO_MAJOR" = "4.4" ] && [ "$UBUNTU_CODENAME" = "jammy" ]; then
  ensure_libssl11
fi

if ! apt install -y mongodb-org; then
  echo "  ! apt install mongodb-org gagal. Cek log di atas."
fi

systemctl enable mongod || true
systemctl start mongod || true

echo "[*] Versi MongoDB:"
mongod --version | head -n 3 || echo "  ! mongod tidak berjalan!"

# =========================
# 3) Siapkan user & /opt/genieacs dari TAR program
# =========================
echo
echo "[*] Siapkan user & /opt/genieacs dari bundle program lama"

id -u genieacs >/dev/null 2>&1 || useradd -r -s /bin/false genieacs

if [ ! -f "$PROGRAM_TAR" ]; then
  echo "  ! $PROGRAM_TAR tidak ditemukan di repo. Tidak bisa lanjut."
  exit 1
fi

mkdir -p /opt
# backup kalau sudah ada
if [ -d /opt/genieacs ]; then
  mv /opt/genieacs "/opt/genieacs_backup_$(date +%F-%H%M%S)"
fi

tar -xzf "$PROGRAM_TAR" -C /opt
chown -R genieacs:genieacs /opt/genieacs

# =========================
# 4) Copy config dari repo (override env lama kalau perlu)
# =========================
echo
echo "[*] Copy konfigurasi dari repo ke /opt/genieacs"

if [ -f "$CONFIG_DIR/genieacs.env" ]; then
  cp "$CONFIG_DIR/genieacs.env" /opt/genieacs/genieacs.env
  echo "    -> /opt/genieacs/genieacs.env disalin dari repo"
fi

if [ -d "$CONFIG_DIR" ]; then
  if ls "$CONFIG_DIR"/*.json 1>/dev/null 2>&1; then
    mkdir -p /opt/genieacs/config
    cp "$CONFIG_DIR"/*.json /opt/genieacs/config/ 2>/dev/null || true
    echo "    -> JSON config disalin ke /opt/genieacs/config/"
  fi
fi

chown -R genieacs:genieacs /opt/genieacs

# =========================
# 5) Pastikan GENIEACS_UI_JWT_SECRET ada di env
# =========================
echo
echo "[*] Pastikan GENIEACS_UI_JWT_SECRET ada di /opt/genieacs/genieacs.env"

if [ ! -f /opt/genieacs/genieacs.env ]; then
  echo "  ! /opt/genieacs/genieacs.env tidak ada. Buat file baru."
  touch /opt/genieacs/genieacs.env
fi

if ! grep -q 'GENIEACS_UI_JWT_SECRET=' /opt/genieacs/genieacs.env; then
  SECRET=$(openssl rand -hex 32)
  sed -i '/GENIEACS_UI_JWT_SECRET/d;/UI_JWT_SECRET/d' /opt/genieacs/genieacs.env
  cat >> /opt/genieacs/genieacs.env <<EOS
GENIEACS_UI_JWT_SECRET=$SECRET
UI_JWT_SECRET=$SECRET
EOS
  echo "    -> GENIEACS_UI_JWT_SECRET ditambahkan"
fi

chown genieacs:genieacs /opt/genieacs/genieacs.env
chmod 600 /opt/genieacs/genieacs.env

# =========================
# 6) Extract systemd service dari TAR systemd
# =========================
echo
echo "[*] Extract systemd service dari bundle lama"

if [ ! -f "$SYSTEMD_TAR" ]; then
  echo "  ! $SYSTEMD_TAR tidak ditemukan di repo."
else
  tar -xzf "$SYSTEMD_TAR" -C /
fi

systemctl daemon-reload

# Pastikan service di-enable
systemctl enable genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui || true

# =========================
# 7) Siapkan folder log + logrotate
# =========================
echo
echo "[*] Siapkan /var/log/genieacs dan file log + logrotate"

LOG_DIR="/var/log/genieacs"
mkdir -p "$LOG_DIR"
chown genieacs:genieacs "$LOG_DIR"

for f in genieacs-cwmp-access.log genieacs-nbi-access.log genieacs-fs-access.log genieacs-ui-access.log genieacs-debug.yaml; do
  touch "$LOG_DIR/$f"
  chown genieacs:genieacs "$LOG_DIR/$f"
done

# logrotate config untuk mencegah log menumpuk
cat >/etc/logrotate.d/genieacs <<'EOLR'
/var/log/genieacs/genieacs-*.log /var/log/genieacs/genieacs-debug.yaml {
    weekly
    rotate 12
    size 50M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOLR

chmod 644 /etc/logrotate.d/genieacs

# =========================
# 8) Restore MongoDB dari backup
# =========================
echo
echo "[*] Restore MongoDB dari $BACKUP_TAR"

if [ ! -f "$BACKUP_TAR" ]; then
  echo "  ! $BACKUP_TAR tidak ditemukan, lewati restore Mongo."
else
  TMP_DIR="$REPO_ROOT/tmp_restore_mongo"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  tar -xzf "$BACKUP_TAR" -C "$TMP_DIR"

  # Deteksi DB_NAME dari MONGODB_URI di env
  MONGO_URI_LINE=$(grep -E '^MONGODB_URI=' /opt/genieacs/genieacs.env || true)
  DB_NAME=$(printf '%s\n' "$MONGO_URI_LINE" | sed 's/.*\///; s/\?.*//')
  if [ -z "$DB_NAME" ]; then
    DB_NAME="genieacs"
  fi
  echo "    -> DB_NAME: $DB_NAME"

  # Cari folder dump untuk DB tersebut
  if [ -d "$TMP_DIR/mongo_migrate_latest/$DB_NAME" ]; then
    RESTORE_DIR="$TMP_DIR/mongo_migrate_latest/$DB_NAME"
  else
    RESTORE_DIR=$(find "$TMP_DIR" -maxdepth 4 -type d -name "$DB_NAME" | head -n1 || true)
  fi

  if [ -n "$RESTORE_DIR" ] && [ -d "$RESTORE_DIR" ]; then
    echo "    -> Restore dari $RESTORE_DIR"
    mongorestore --drop --db "$DB_NAME" "$RESTORE_DIR"
    echo "    -> Restore MongoDB selesai"
  else
    echo "  ! Folder dump DB $DB_NAME tidak ditemukan di dalam backup."
  fi

  rm -rf "$TMP_DIR"
fi

# =========================
# 9) Start semua service GenieACS
# =========================
echo
echo "[*] Restart semua service GenieACS"
systemctl restart genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui || true

echo
echo "[*] Status singkat genieacs-ui:"
systemctl status genieacs-ui --no-pager | sed -n '1,15p'

echo
echo "[*] Cek port 3000:"
ss -tulpn | grep 3000 || echo "  ! Tidak ada yang listen di port 3000"

echo
echo "====================================================="
echo "INSTALL + RESTORE GENIEACS SELESAI"
echo "Program & service berasal dari bundle server lama,"
echo "MongoDB direstore dari backup, dan logrotate sudah di-setup."
echo "====================================================="
