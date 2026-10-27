#!/bin/bash
# 02-setup-replication.sh
# Runs automatically on the primary's first boot (after schema.sql).
# Creates a dedicated replication-only role and allows the replica
# container to connect to it over the replication protocol.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pw';
EOSQL

echo "host replication replicator all md5" >> "$PGDATA/pg_hba.conf"
