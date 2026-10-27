#!/bin/bash
# replica-entrypoint.sh
# Runs once when the replica container's data directory is empty:
# takes a base backup from the primary and configures it as a
# streaming replication standby. On every restart after that, it just
# starts Postgres normally against the already-cloned data directory.
set -e

DATA_DIR="/var/lib/postgresql/data"

if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
  echo "[replica-entrypoint] Data directory is empty — cloning from primary..."

  until PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
      -h "$PRIMARY_HOST" -p 5432 -U "$REPLICATION_USER" \
      -D "$DATA_DIR" -Fp -Xs -P -R; do
    echo "[replica-entrypoint] Primary not ready yet, retrying in 3s..."
    sleep 3
  done

  echo "[replica-entrypoint] Base backup complete. standby.signal and primary_conninfo were written automatically by -R."
  chown -R postgres:postgres "$DATA_DIR"
  chmod 700 "$DATA_DIR"
fi

echo "[replica-entrypoint] Starting Postgres as a standby..."
exec gosu postgres postgres -D "$DATA_DIR"
