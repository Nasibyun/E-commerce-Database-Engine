# Backup & Recovery Plan

> **Environment**: PostgreSQL 16 on Docker, database `ecommerce_dba`,
> ~600 000 orders, ~1.2 M order items, total DB size ~350 MB.

This documents a real backup/restore cycle I ran, including a
simulated disaster (dropping a critical table) and full recovery.

---

## 1. Backup Strategy

### Tooling

I used `pg_dump` in **custom format** (`-Fc`) — it produces a
compressed, reorderable archive that lets you restore individual tables
without extracting the entire dump first. For a database this size
that's more than enough; I'd switch to `pg_basebackup` + WAL archiving
for anything larger or where point-in-time recovery matters.

### Taking the backup

```bash
# From the host machine (Docker container exposes port 5432)
pg_dump -h localhost -p 5432 -U postgres -d ecommerce_dba \
  -Fc --verbose -f ecommerce_dba_backup.dump
```

**Output**:
```
pg_dump: dumping contents of table "public.customers"
pg_dump: dumping contents of table "public.categories"
pg_dump: dumping contents of table "public.products"
pg_dump: dumping contents of table "public.warehouses"
pg_dump: dumping contents of table "public.inventory"
pg_dump: dumping contents of table "public.orders"
pg_dump: dumping contents of table "public.order_items"
pg_dump: dumping contents of table "public.order_status_history"
pg_dump: dumping contents of table "public.payments"
pg_dump: dumping contents of table "public.returns"
```

**Backup file size**: 41 MB (compressed custom format).
The uncompressed data is roughly 350 MB, so the compression ratio is
about 8.5:1 — custom format uses zlib internally.

### Verifying the backup

Before simulating the disaster, I verified the backup file was
readable:

```bash
pg_restore --list ecommerce_dba_backup.dump | head -20
```

This lists all objects in the archive — tables, indexes, constraints,
sequences. If the file were corrupt, `pg_restore --list` would fail
immediately.

---

## 2. Simulating a Disaster

### Pre-drop row counts

```sql
SELECT 'orders' AS table_name, COUNT(*) FROM orders
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL
SELECT 'payments', COUNT(*) FROM payments
UNION ALL
SELECT 'order_status_history', COUNT(*) FROM order_status_history;
```

```
     table_name      |  count
---------------------+---------
 orders              |  600000
 order_items         | 1230169
 payments            |  600000
 order_status_history| 1140018
```

### Dropping the table

```sql
-- This is what you'd never want to do in production.
-- CASCADE takes out foreign key references too.
DROP TABLE order_items CASCADE;
```

### What broke

After the drop:
- `order_items` is gone (obviously)
- The `line_total` generated column — gone
- Any indexes on `order_items` — gone
- The `returns` table lost its FK reference to `order_items.order_item_id`
  (CASCADE dropped the constraint, not the `returns` table itself)
- The `orders.total_amount` column still exists but its values are now
  orphaned — no line items to recalculate from

### Confirming the damage

```sql
\dt order_items
-- "Did not find any relation named "order_items"."

SELECT * FROM returns LIMIT 1;
-- Still works — the table exists, but the FK constraint is gone.
-- Data integrity is now silently broken.
```

---

## 3. Recovery

### Step 1: Restore just the `order_items` table

Since I used custom format, I can restore a single table without
touching the rest of the database:

```bash
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --data-only --table=order_items \
  --verbose ecommerce_dba_backup.dump
```

Wait — that won't work. The table itself was dropped (not just
truncated), so I need to restore the table definition first:

```bash
# Step 1a: Restore the table structure (DDL only)
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --schema-only --table=order_items \
  --verbose ecommerce_dba_backup.dump

# Step 1b: Restore the data
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --data-only --table=order_items \
  --verbose ecommerce_dba_backup.dump
```

### Step 2: Rebuild indexes and constraints

The `--schema-only` restore recreated the table and its `GENERATED
ALWAYS AS` column, but indexes and foreign keys need to be restored
too. `pg_restore` handles this automatically when you restore the full
table:

```bash
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --clean --if-exists --table=order_items \
  --verbose ecommerce_dba_backup.dump
```

Actually, let me be honest — I ended up doing a full clean restore
because the CASCADE had also dropped the FK constraint on `returns`.
The surgical single-table approach is possible but fiddly when CASCADE
has rippled:

```bash
# Full restore (what I actually did)
# Drop and recreate everything from the backup
psql -h localhost -p 5432 -U postgres -c "DROP DATABASE ecommerce_dba;"
psql -h localhost -p 5432 -U postgres -c "CREATE DATABASE ecommerce_dba;"
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --verbose ecommerce_dba_backup.dump
```

**Restore time**: ~50 seconds for the full database.

### Step 3: Verify recovery

```sql
SELECT 'orders' AS table_name, COUNT(*) FROM orders
UNION ALL
SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL
SELECT 'payments', COUNT(*) FROM payments
UNION ALL
SELECT 'order_status_history', COUNT(*) FROM order_status_history;
```

```
     table_name      |  count
---------------------+---------
 orders              |  600000
 order_items         | 1230169
 payments            |  600000
 order_status_history| 1140018
```

**All 1,230,169 rows in `order_items` recovered. Zero data loss.**

### Step 4: Confirm FK constraints are back

```sql
SELECT conname, conrelid::regclass, confrelid::regclass
FROM   pg_constraint
WHERE  conrelid = 'returns'::regclass AND contype = 'f';
```

```
       conname        | conrelid | confrelid
----------------------+----------+------------
 returns_order_item_id_fkey | returns | order_items
```

FK constraint restored.

---

## 4. What This Setup Does NOT Cover

This is a portfolio project, not a production runbook. Here's what
I'd add for a real system:

### Point-in-time recovery (PITR)

`pg_dump` gives you a snapshot at a single point in time. If someone
runs a bad `UPDATE` at 3:47 PM, I can only restore to "whenever the
last dump was taken." For production, I'd set up:

- **Continuous WAL archiving** (`archive_mode = on`, `archive_command`
  shipping WAL segments to S3/GCS)
- **`pg_basebackup`** for periodic base backups
- Recovery to any arbitrary timestamp: `recovery_target_time = '2024-01-15 15:46:00'`

### Off-host / off-site backup storage

The backup file sits on the same Docker host as the database. If the
host dies, the backup dies with it. Production needs:

- Backups shipped to object storage (S3, GCS, Azure Blob)
- A tool like **pgBackRest** or **Barman** to manage retention,
  compression, encryption, and parallel restore
- Cross-region replication of the backup bucket

### Backup encryption

The dump file is unencrypted. For any database with PII (and this one
has customer names, emails, phone numbers), the backup should be
encrypted at rest — either via the storage layer (S3 SSE) or
application-level (GPG, age).

### Automated backup schedule

Right now I'm running `pg_dump` manually. Production needs:

- A cron job or Kubernetes CronJob running backups on schedule
- Alerting if a backup fails or is older than expected
- Retention policy (e.g., keep daily for 7 days, weekly for 4 weeks,
  monthly for 12 months)

### Restore testing

I did one restore test. Production should have **automated restore
tests** — take the latest backup, restore it to a scratch instance,
run a row-count sanity check, and alert if anything is off. Backups
that have never been tested aren't backups.

---

## 5. Quick Reference Commands

```bash
# Take a backup
pg_dump -h localhost -p 5432 -U postgres -d ecommerce_dba \
  -Fc --verbose -f "ecommerce_dba_$(date +%Y%m%d_%H%M%S).dump"

# List contents of a backup
pg_restore --list ecommerce_dba_backup.dump

# Restore a single table (data only, table must exist)
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --data-only --table=TABLE_NAME ecommerce_dba_backup.dump

# Full restore (destructive — drops and recreates the database)
psql -h localhost -p 5432 -U postgres -c "DROP DATABASE ecommerce_dba;"
psql -h localhost -p 5432 -U postgres -c "CREATE DATABASE ecommerce_dba;"
pg_restore -h localhost -p 5432 -U postgres -d ecommerce_dba \
  --verbose ecommerce_dba_backup.dump

# Verify row counts after restore
psql -h localhost -p 5432 -U postgres -d ecommerce_dba -c "
  SELECT relname, n_live_tup
  FROM pg_stat_user_tables
  ORDER BY n_live_tup DESC;"
```
