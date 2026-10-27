# Streaming Replication Setup

> **Environment**: PostgreSQL 16 on Docker Compose.
> Primary on port 5432, replica on port 5433.

This documents how I set up streaming replication for this project,
including the actual bug I hit and how I fixed it.

---

## Architecture

```
┌─────────────┐     WAL stream      ┌─────────────┐
│  Primary    │ ──────────────────>  │  Replica     │
│  (db:5432)  │   replicator user   │  (replica:5433) │
│             │                     │  read-only    │
└─────────────┘                     └─────────────┘
```

- **Primary** runs normally with `wal_level = replica` and allows the
  `replicator` role to connect via the replication protocol
- **Replica** was bootstrapped from a `pg_basebackup` of the primary
  and runs in standby mode, continuously streaming WAL changes

---

## Setup Steps

### 1. Create the replication role on the primary

This is done by [02-setup-replication.sh](02-setup-replication.sh)
on first boot, but here are the manual commands:

```sql
-- On the primary
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pw';
```

```bash
# Allow the replicator role to connect via replication protocol
echo "host replication replicator all md5" >> "$PGDATA/pg_hba.conf"
pg_ctl reload  # or SELECT pg_reload_conf();
```

### 2. Verify `wal_level` on the primary

```sql
SHOW wal_level;
--  wal_level
-- -----------
--  replica
```

PostgreSQL 16's default `wal_level` is already `replica`, so no
change needed. If it were `minimal`, you'd set it in `postgresql.conf`
and restart.

### 3. Take a base backup (replica side)

This is automated in [replica-entrypoint.sh](replica-entrypoint.sh):

```bash
PGPASSWORD="replicator_pw" pg_basebackup \
  -h db -p 5432 -U replicator \
  -D /var/lib/postgresql/data \
  -Fp -Xs -P -R
```

Flags:
- `-Fp` — plain format (write directly to the data directory)
- `-Xs` — stream WAL during the backup (no separate `pg_receivewal` needed)
- `-P` — show progress
- `-R` — automatically write `standby.signal` and `primary_conninfo` in
  `postgresql.auto.conf`

### 4. Start the replica

The `replica-entrypoint.sh` script handles this with `gosu postgres postgres -D "$DATA_DIR"`.
The presence of `standby.signal` tells PostgreSQL to start in standby mode.

---

## Verification

### Test 1: Check replication status on the primary

```sql
-- On the primary (port 5432)
SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;
```

```
 client_addr |   state   |  sent_lsn   | write_lsn   | flush_lsn   | replay_lsn
-------------+-----------+-------------+-------------+-------------+-------------
 172.18.0.3  | streaming | 0/1A000D48  | 0/1A000D48  | 0/1A000D48  | 0/1A000D48
```

All four LSN values match → replica is fully caught up.

### Test 2: Write on primary, read on replica

```sql
-- On the primary (port 5432)
INSERT INTO customers (first_name, last_name, email, phone, signup_date, city, state)
VALUES ('Replication', 'Test', 'repl-test@example.com', '9999999999', CURRENT_DATE, 'Bengaluru', 'Karnataka');
```

```sql
-- On the replica (port 5433), within 1-2 seconds
SELECT customer_id, first_name, last_name, email
FROM customers
WHERE email = 'repl-test@example.com';
```

```
 customer_id | first_name  | last_name | email
-------------+-------------+-----------+------------------------
       50001 | Replication | Test      | repl-test@example.com
```

Row appeared on the replica within ~1 second.

### Test 3: Confirm replica rejects writes

```sql
-- On the replica (port 5433)
INSERT INTO customers (first_name, last_name, email) VALUES ('Should', 'Fail', 'fail@test.com');
-- ERROR:  cannot execute INSERT in a read-only transaction
```

This confirms the replica is genuinely in standby mode, not just a
stale copy that happens to have the same data.

### Test 4: Check replication lag

```sql
-- On the replica
SELECT CASE
  WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
  ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())
END AS replication_lag_seconds;
```

```
 replication_lag_seconds
-------------------------
                       0
```

---

## The Bug I Hit

When I first ran the replica, `pg_basebackup` ran as `root` inside the
container (the default user for the postgres:16 image before
`docker-entrypoint.sh` drops privileges). This meant the entire data
directory — including `postgresql.conf` — was owned by `root:root`.

When the `replica-entrypoint.sh` script then tried to start Postgres
as the `postgres` user, it failed with:

```
FATAL:  could not open configuration file "/var/lib/postgresql/data/postgresql.conf": Permission denied
```

### The fix

Added ownership correction after the base backup completes:

```bash
chown -R postgres:postgres "$DATA_DIR"
chmod 700 "$DATA_DIR"
```

This is already in the current version of `replica-entrypoint.sh`.
It's a one-liner fix, but it cost me 30 minutes of debugging because
the error message points at the config file, not at the ownership —
you'd expect a "wrong owner" message if that were the issue.

---

## Replication Monitoring Queries

```sql
-- Replication status (run on primary)
SELECT pid, usename, client_addr, state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes,
       sync_state
FROM pg_stat_replication;

-- WAL receiver status (run on replica)
SELECT status, received_lsn, latest_end_lsn,
       last_msg_send_time, last_msg_receipt_time
FROM pg_stat_wal_receiver;

-- Check for replication slots (if used)
SELECT slot_name, active, restart_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots;
```

---

## What This Setup Does NOT Cover

- **Automatic failover** — if the primary goes down, someone has to
  manually promote the replica (`pg_ctl promote` or `SELECT pg_promote()`).
  For production, use Patroni, repmgr, or a managed service.
- **Synchronous replication** — this is async, so there's a (tiny)
  window where a committed transaction on the primary hasn't reached
  the replica yet. For zero-data-loss requirements, switch to
  synchronous mode (at the cost of write latency).
- **Multiple replicas** — this is a single-replica setup. Production
  might want 2+ replicas for read scaling and redundancy.
- **Connection routing** — no automatic read/write splitting. An
  application would need a proxy (PgBouncer, HAProxy) or connection
  logic to route reads to the replica.
