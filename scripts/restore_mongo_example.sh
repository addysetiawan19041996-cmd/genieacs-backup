#!/usr/bin/env bash
set -e
echo "Restore database 'genieacs' dari folder mongo_dump/genieacs"
mongorestore --db genieacs mongo_dump/genieacs
