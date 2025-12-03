# Backup GenieACS

Folder ini berisi:
- config/          -> file konfigurasi (genieacs.env.example, *.json)
- systemd/         -> file service systemd GenieACS
- provisions/      -> provisions / script JS untuk GenieACS
- scripts/         -> script helper
- mongo_dump/      -> dump database MongoDB (TIDAK di-commit ke Git)

Langkah restore singkat:
1. Install Ubuntu + MongoDB + Node.js + GenieACS versi yang sama.
2. Salin isi config/, systemd/, provisions/ ke lokasi yang sesuai.
3. Restore MongoDB dari mongo_dump/ dengan:
   mongorestore --db genieacs mongo_dump/genieacs
4. systemctl daemon-reload && restart semua service genieacs.

Langkah Install
apt update && apt install -y git
git clone https://github.com/addysetiawan19041996-cmd/genieacs-backup.git
cd genieacs-backup
bash scripts/genieacs_install_restore.sh



