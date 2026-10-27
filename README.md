# E-Commerce Order Management Database

> A full-stack DBA portfolio project — not just a schema, but indexing decisions
> backed by real EXPLAIN ANALYZE numbers, a backup that's actually been restored from,
> a replica that's actually been tested, and security controls that actually work.

Everything below is stuff I ran myself against a real **600K-order PostgreSQL
database**, not estimated or made up.

---

## Architecture

```
┌──────────────────┐         WAL stream          ┌──────────────────┐
│    Primary DB    │ ──────────────────────────>  │    Read Replica   │
│   (port 5432)    │    replicator role           │   (port 5433)     │
│                  │                              │   read-only       │
└────────┬─────────┘                              └──────────────────┘
         │
    ┌────┴────┐
    │ pgAdmin │  (optional, port 8080)
    │  Web UI │
    └─────────┘
```

**Tech stack**: PostgreSQL 16, Docker Compose, Python (Faker + NumPy)

---

## What's Here

| File | What it does |
|------|-------------|
| [`schema.sql`](schema.sql) | 10-table normalized schema with triggers, views, and `COMMENT ON` documentation |
| [`docker-compose.yml`](docker-compose.yml) | Primary + replica + optional pgAdmin, with health checks and tuned Postgres config |
| [`generate_data.py`](generate_data.py) | Realistic, skewed data generator (Zipf-distributed orders, lognormal prices, UPI-heavy payments) |
| [`optimization_queries.sql`](optimization_queries.sql) | 8 business queries with targeted indexes and EXPLAIN ANALYZE |
| [`case_study.md`](case_study.md) | Deep-dive write-up: 4 queries optimized with real before/after numbers |
| [`recovery_plan.md`](recovery_plan.md) | Backup/restore cycle including a simulated `DROP TABLE` disaster |
| [`REPLICATION.md`](REPLICATION.md) | Streaming replica setup, verification tests, and a real bug fix |
| [`security_roles.sql`](security_roles.sql) | Role-based access (analyst/app/DBA), row-level security, audit logging |
| [`monitoring_queries.sql`](monitoring_queries.sql) | 12 production-grade health-check queries (cache hit ratio, bloat, locks, etc.) |

---

## Getting It Running

### Prerequisites

- Docker & Docker Compose
- Python 3.8+ with pip

### Quick start

```bash
# 1. Start the database
docker compose up -d

# 2. Install Python dependencies
pip install faker psycopg2-binary numpy

# 3. Generate data (15-30 min for 600K orders — grab a coffee)
python generate_data.py \
  --dsn "dbname=ecommerce_dba user=postgres password=postgres host=localhost port=5432" \
  --customers 50000 --products 2000 --orders 600000

# 4. (Optional) Start pgAdmin web UI at http://localhost:8080
docker compose --profile tools up -d
```

### Smaller dataset for quick testing

```bash
python generate_data.py --customers 5000 --products 500 --orders 50000
```

### Environment variables

Copy `.env.example` to `.env` to customize ports, passwords, and data generation parameters:

```bash
cp .env.example .env
```

---

## The Query Optimization Part

This is the part I'd walk an interviewer through. I picked four queries
that feel like real business questions and measured them before and after
adding indexes. Full breakdown with EXPLAIN ANALYZE output is in
[`case_study.md`](case_study.md).

| Query | Before | After | Improvement | Key insight |
|-------|--------|-------|-------------|-------------|
| Top customers by LTV | 270 ms | 265 ms | ~2% | Index can't help when you aggregate 90% of the table. Need a materialized view. |
| Low-stock products | 4 ms | 3.5 ms | ~12% | Table too small for index to matter, but the partial index is the right design. |
| Monthly revenue by category | **2,217 ms** | **875 ms** | **60%** | Covering index eliminated a 13 MB disk spill per worker. |
| Stuck orders | 643 ms | 554 ms | 14% | Almost got fooled by cold-cache noise after `CREATE INDEX`. |

The project also includes 4 additional queries (payment breakdown, cohort
analysis, return rates, warehouse utilization) in
[`optimization_queries.sql`](optimization_queries.sql).

---

## Backup and Recovery

Took a `pg_dump` backup (41 MB, custom format), then **actually dropped a
table on purpose** — `DROP TABLE order_items CASCADE` — to see what breaks
and whether the backup holds up. It did: restored all **1,230,169 rows with
zero loss** in about 50 seconds.

Details in [`recovery_plan.md`](recovery_plan.md), including what this setup
*doesn't* cover (point-in-time recovery, off-host storage) if I were doing
this for production.

---

## Replication

Set up a streaming read replica — `pg_basebackup` clone, standby mode, live
WAL streaming. Verified it actually works:

- ✅ Row inserted on primary appeared on replica within ~1 second
- ✅ Replica correctly rejects `INSERT` with "cannot execute in a read-only transaction"
- ✅ Replication lag measured at 0 bytes under normal load

Hit a real permissions bug: `pg_basebackup` ran as `root`, so Postgres
couldn't read its own config file when starting as the `postgres` user. Fixed
with a `chown` — details in [`REPLICATION.md`](REPLICATION.md).

---

## Security & Access Control

Implemented the three roles that most production databases need:

| Role | Access | Use case |
|------|--------|----------|
| `analyst_ro` | SELECT on all tables, RLS restricts to active customers only | Data analysts, BI tools |
| `app_rw` | Full CRUD on transactional tables, SELECT-only on reference tables | Application backend |
| `dba_admin` | Superuser | Database administration |

Plus:
- **Row-level security** on `customers` (analysts only see active accounts)
- **Audit triggers** on `customers` and `orders` that log all changes to `audit_log` with JSONB snapshots
- **TRUNCATE revoked** from the app role (learned that the hard way)

Details and SQL in [`security_roles.sql`](security_roles.sql).

---

## Monitoring

[`monitoring_queries.sql`](monitoring_queries.sql) contains 12 production-grade
health-check queries ready to wire into Grafana or a cron alerting job:

- Database & table sizes with bloat estimation
- Index usage stats (find unused indexes wasting disk)
- Cache hit ratio (should be >99%)
- Active connections and lock contention
- Replication lag monitoring
- Long-running transactions (MVCC bloat source)
- Tables needing vacuum
- Checkpoint and WAL statistics

---

## Schema Design

```
customers ─────┐
               │ 1:N
categories ─┐  ├── orders ──────┬── order_items ──── returns
            │  │                │
  products ─┴──┘                ├── order_status_history
            │                   │
warehouses ─┤                   └── payments
            │
  inventory ┘
```

- **10 tables**, normalized to 3NF
- **3 triggers** — auto-populate status history on order insert/update, auto-update inventory timestamps
- **2 views** — `v_customer_ltv` and `v_daily_revenue` for analyst convenience
- **Generated column** — `order_items.line_total` computed and stored for index performance
- **Self-referencing FK** — `categories.parent_category_id` for hierarchy support

---

## Project Structure

```
ecommerce-dba-project/
├── schema.sql                  # 10-table DDL with triggers, views, comments
├── docker-compose.yml          # Primary + replica + pgAdmin
├── generate_data.py            # Realistic data generator (Faker + NumPy)
├── optimization_queries.sql    # 8 queries with indexes
├── case_study.md               # Deep-dive optimization write-up
├── recovery_plan.md            # Backup/restore walkthrough
├── REPLICATION.md              # Streaming replica setup
├── security_roles.sql          # Roles, RLS, audit logging
├── monitoring_queries.sql      # 12 health-check queries
├── 02-setup-replication.sh     # Primary-side replication setup
├── replica-entrypoint.sh       # Replica bootstrap script
├── .env.example                # Environment variable template
└── .gitignore                  # Keeps secrets and data out of git
```

---

## What I'd Do Next (If This Were Production)

- **Partitioning** — range-partition `orders` by month for faster time-range queries and easier archival
- **`pg_stat_statements`** — track real query workload instead of guessing
- **PgBouncer** — connection pooling in front of the primary
- **Automated backups** — cron + pgBackRest with S3 storage and automated restore testing
- **CI/CD migrations** — Flyway or Sqitch for schema versioning
- **Grafana dashboards** — wire up `monitoring_queries.sql` for real-time visibility
