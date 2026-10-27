# E-Commerce Order Management Database

> A PostgreSQL database engineering project focused on query optimization, replication, backup and recovery, security, and monitoring — with measured performance experiments and hands-on DBA workflows.

Built around a realistic e-commerce workload, this project demonstrates how database design and administration decisions affect transactional workloads, analytical queries, reliability, and access control.

**Tech stack:** PostgreSQL 16 · Docker Compose · Python · Faker · NumPy

---

## Architecture

```text
                    WAL Streaming
              ┌─────────────────────────┐
              │                         ▼
┌─────────────────────┐      ┌─────────────────────┐
│     Primary DB      │      │     Read Replica    │
│                     │      │                     │
│ PostgreSQL 16       │      │ PostgreSQL 16       │
│ Port: 5432          │      │ Port: 5433          │
│ Read / Write        │      │ Read Only           │
└──────────┬──────────┘      └─────────────────────┘
           │
           ├── Schema and SQL analytics
           ├── Query optimization
           ├── Backup and recovery
           ├── Security and audit logging
           │
           ▼
┌─────────────────────┐
│      pgAdmin        │
│   Optional Web UI   │
│     Port: 8080      │
└─────────────────────┘
```

The architecture separates the primary database, which handles writes, from a streaming replica intended for read workloads. pgAdmin provides an optional graphical interface for database administration.

## Project Highlights

- Designed a normalized, 10-table relational schema for an e-commerce platform.
- Generated a configurable dataset containing up to 600,000 orders.
- Implemented eight business-oriented SQL queries with targeted indexes.
- Analyzed query execution plans using `EXPLAIN ANALYZE`.
- Documented four query optimization experiments with before-and-after timings.
- Implemented PostgreSQL streaming replication and verification procedures.
- Documented a backup and restore experiment involving a simulated table-deletion incident.
- Implemented role-based access control, row-level security, and audit logging.
- Created monitoring queries for database health, locks, index usage, and replication.

**Experimental results:** The performance and recovery figures below are the reported results of the project's local experiments. Hardware, PostgreSQL settings, dataset configuration, and test procedures should be documented when reproducing the results.

---

## Repository Structure

| File | Description |
| --- | --- |
| [`schema.sql`](schema.sql) | Normalized schema, constraints, triggers, views, and column documentation |
| [`docker-compose.yml`](docker-compose.yml) | Primary database, replica, optional pgAdmin, and health checks |
| [`generate_data.py`](generate_data.py) | Configurable synthetic data generator using Faker and NumPy |
| [`optimization_queries.sql`](optimization_queries.sql) | Eight business queries, indexes, and execution-plan analysis |
| [`case_study.md`](case_study.md) | Detailed query optimization experiments and reported timings |
| [`recovery_plan.md`](recovery_plan.md) | Backup, restore, and simulated data-loss recovery procedure |
| [`REPLICATION.md`](REPLICATION.md) | Streaming replication setup, verification, and troubleshooting |
| [`security_roles.sql`](security_roles.sql) | Database roles, permissions, row-level security, and audit logging |
| [`monitoring_queries.sql`](monitoring_queries.sql) | Twelve database health and performance monitoring queries |
| [`02-setup-replication.sh`](02-setup-replication.sh) | Primary-side replication configuration |
| [`replica-entrypoint.sh`](replica-entrypoint.sh) | Replica initialization and startup |
| [`.env.example`](.env.example) | Environment variable template |
| [`.gitignore`](.gitignore) | Excludes configured files and other files from version control |

---

## Prerequisites

- Docker Engine or Docker Desktop
- Docker Compose
- Python 3.8+
- Git

## Getting Started

### 1. Clone the repository

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd ecommerce-dba-project
```

Replace the repository URL and directory name with your actual GitHub repository details.

### 2. Configure environment variables

If the repository includes `.env.example`, create your local environment file:

```bash
cp .env.example .env
```

Review the variables in `.env` and configure the database credentials, ports, and other settings supported by the Compose configuration.

Do not commit `.env` or production credentials to version control.

### 3. Start the database environment

```bash
docker compose up -d
```

Check the running containers:

```bash
docker compose ps
```

Inspect the logs if a service fails to start:

```bash
docker compose logs
```

The initial startup and replication initialization depend on the repository's Docker Compose configuration and entrypoint scripts. Follow [`REPLICATION.md`](REPLICATION.md) if replication requires an additional initialization step.

### 4. Install Python dependencies

```bash
python -m pip install faker psycopg2-binary numpy
```

### 5. Generate the dataset

For the larger workload:

```bash
python generate_data.py \
  --dsn "dbname=ecommerce_dba user=postgres password=postgres host=localhost port=5432" \
  --customers 50000 \
  --products 2000 \
  --orders 600000
```

The data generator uses configurable parameters to populate the database with synthetic e-commerce data.

The full dataset can take approximately 15–30 minutes to generate, depending on hardware, database configuration, and insertion strategy.

**Important:** Confirm that the database name, credentials, ports, and command-line arguments match your actual configuration before running the command.

### 6. Generate a smaller dataset

For quicker development and testing:

```bash
python generate_data.py \
  --customers 5000 \
  --products 500 \
  --orders 50000
```

### 7. Start pgAdmin (optional)

If pgAdmin is configured under the `tools` profile:

```bash
docker compose --profile tools up -d
```

Open:

```text
http://localhost:8080
```

Use the configured pgAdmin credentials and database connection settings.

### 8. Connect to PostgreSQL

For the default local primary port:

```bash
psql -h localhost -p 5432 -U postgres -d ecommerce_dba
```

For the read replica:

```bash
psql -h localhost -p 5433 -U postgres -d ecommerce_dba
```

The replica connection command assumes that the replica exposes port `5433` and permits the specified role to connect. Use the actual credentials configured for the environment.

---

## Query Optimization Case Study

The project examines four business queries to understand how indexing, query execution plans, aggregation costs, and caching affect performance.

The reported measurements are:

| Query | Before | After | Reported improvement |
| --- | ---: | ---: | ---: |
| Top customers by lifetime value | 270 ms | 265 ms | ~2% |
| Low-stock products | 4 ms | 3.5 ms | ~12% |
| Monthly revenue by category | 2,217 ms | 875 ms | ~60% |
| Stuck orders | 643 ms | 554 ms | ~14% |

These timings are environment-specific observations, not universal performance guarantees.

### 1. Top customers by lifetime value

**Observation:** 270 ms → 265 ms.

The query aggregates order information across a large portion of the dataset. An index on a filtering column may provide little benefit when most rows must still be processed.

**Key takeaway:** Indexes are not automatically beneficial for every analytical query. A materialized view or pre-aggregated summary may be more appropriate for repeatedly requested lifetime-value metrics.

### 2. Low-stock products

**Observation:** 4 ms → 3.5 ms.

The query targets products whose inventory falls below a threshold. A partial index can be useful when the indexed subset is small and matches the query predicate.

**Key takeaway:** The value of an index depends on selectivity, table size, query shape, and the cost of maintaining the index.

### 3. Monthly revenue by category

**Observation:** 2,217 ms → 875 ms.

This query showed the largest reported improvement. The optimization experiment identified a disk spill during aggregation, and the selected index reduced execution time.

**Key takeaway:** Query performance depends on more than lookup speed. Aggregation strategy, memory usage, data access patterns, and intermediate result sizes can all affect execution time.

### 4. Stuck orders

**Observation:** 643 ms → 554 ms.

The query identifies orders that remain in an intermediate state longer than expected. The experiment also highlighted how cold-cache effects can complicate comparisons after creating an index.

**Key takeaway:** Performance comparisons should control for cache state, data volume, and other environmental differences.

### Reproducing the experiments

The complete SQL statements, index definitions, and execution-plan analysis are documented in [`optimization_queries.sql`](optimization_queries.sql) and [`case_study.md`](case_study.md).

For reliable comparisons:

1. Load the same dataset before each experiment.
2. Capture the baseline execution plan using `EXPLAIN ANALYZE`.
3. Create the intended index.
4. Run `ANALYZE` when appropriate to refresh planner statistics.
5. Repeat the query several times under documented cache conditions.
6. Compare execution time, scan type, estimated versus actual rows, and disk spills.

Use consistent conditions when comparing timings, and retain the raw execution plans alongside the summary table.

The project also covers four additional business queries:

- Payment-method breakdown
- Customer cohort analysis
- Product return rates
- Warehouse utilization

---

## Backup and Recovery

The recovery experiment documents a backup-and-restore workflow using PostgreSQL's `pg_dump` and restore tools.

### Reported experiment

- Backup format: PostgreSQL custom format
- Reported backup size: 41 MB
- Simulated incident: `DROP TABLE order_items CASCADE`
- Reported restored row count: 1,230,169
- Reported restore duration: approximately 50 seconds

The reported recovery test restored the documented data without observed row loss.

### Why this matters

A backup is useful only if it can be restored successfully. The recovery procedure therefore focuses on more than creating a dump: it also documents the simulated incident, restoration process, and validation of recovered data.

### Typical backup command

```bash
pg_dump \
  -h localhost \
  -p 5432 \
  -U postgres \
  -d ecommerce_dba \
  -Fc \
  -f ecommerce_backup.dump
```

### Typical restore workflow

Restore into a separate test database when possible:

```bash
createdb \
  -h localhost \
  -p 5432 \
  -U postgres \
  ecommerce_restore_test
```

```bash
pg_restore \
  -h localhost \
  -p 5432 \
  -U postgres \
  -d ecommerce_restore_test \
  ecommerce_backup.dump
```

These are standard example commands. Use the actual credentials, database settings, and backup path for your environment.

Validate the restored tables, row counts, constraints, and relevant relationships before declaring recovery successful.

**Known limitations:** A basic dump-and-restore workflow does not by itself provide point-in-time recovery or off-host disaster protection. Production deployments would need an appropriate backup retention policy, secure external storage, and tested recovery procedures.

See [`recovery_plan.md`](recovery_plan.md) for the project's detailed procedure.

---

## PostgreSQL Streaming Replication

The project configures a primary database and a read replica using PostgreSQL write-ahead log (WAL) streaming.

The primary handles writes, while the replica is intended for read-only workloads.

### Reported verification tests

| Test | Reported result |
| --- | --- |
| Insert a row on the primary | Row appeared on the replica in approximately one second |
| Attempt an insert on the replica | Rejected because the transaction was read-only |
| Observe replication lag during normal load | Reported as 0 bytes |

These are observations from the documented test conditions. Replication delay can vary with workload, network conditions, and database configuration.

### Troubleshooting experience

The replication setup encountered a permissions problem when `pg_basebackup` ran as `root`. The PostgreSQL server process, running under the `postgres` user, could not access a required configuration file.

The documented fix involved correcting file ownership with `chown`.

This illustrates an important operational lesson: successful data copying does not guarantee that the replica will start correctly. File permissions, authentication, server configuration, and recovery state must also be checked.

### What the experiment demonstrates

- Initializing a replica from a base backup
- Configuring a standby to receive WAL records
- Verifying that primary writes reach the replica
- Confirming read-only behavior
- Inspecting replication status and troubleshooting startup failures

See [`REPLICATION.md`](REPLICATION.md) for the implementation and verification steps.

---

## Security and Access Control

The project demonstrates separation of database responsibilities using three PostgreSQL roles.

| Role | Intended access | Purpose |
| --- | --- | --- |
| `analyst_ro` | Read-only access, restricted by row-level security | Analytics and reporting |
| `app_rw` | Application-level CRUD permissions on designated tables | Backend application access |
| `dba_admin` | Administrative privileges as configured | Database administration |

### Implemented security controls

- **Role-based access control:** Grant only the permissions required by each role.
- **Row-level security:** Restrict analyst visibility to eligible customer records.
- **Audit logging:** Record changes to customers and orders using audit triggers and JSONB snapshots.
- **Restricted destructive operations:** Revoke `TRUNCATE` permission from the application role.
- **Privilege separation:** Keep application access distinct from database administration.

### Security considerations

Row-level security must be tested using the actual roles that will access the tables. Table owners, superusers, and roles with `BYPASSRLS` can have different behavior from ordinary application users.

Similarly, audit triggers cover the operations for which they are defined; they should not be treated as a complete record of every possible database-level change.

The `dba_admin` role should receive superuser privileges only if explicitly required and configured. In production, prefer narrowly scoped administrative roles and avoid using a superuser account for routine application operations.

Database passwords should be supplied through an appropriate secrets mechanism rather than committed to source control.

See [`security_roles.sql`](security_roles.sql) for the SQL implementation.

---

## Database Monitoring

The project includes twelve SQL monitoring queries in [`monitoring_queries.sql`](monitoring_queries.sql).

They cover:

- Database and table sizes
- Estimated table and index bloat
- Index usage statistics
- Cache hit ratio
- Active connections
- Lock contention
- Replication status and lag
- Long-running transactions
- Tables requiring vacuum
- Checkpoint statistics
- WAL activity
- Other database health indicators

These queries provide a foundation for understanding database behavior and investigating performance issues.

### Example: Inspect index usage

PostgreSQL maintains statistics that can help identify indexes with little observed usage.

```sql
SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC;
```

An index with a low scan count is not automatically unnecessary. Evaluate its purpose, workload history, uniqueness constraints, and impact on write performance before removing it.

### Example: Inspect active queries

```sql
SELECT
    pid,
    usename,
    state,
    wait_event_type,
    wait_event,
    query_start,
    query
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY query_start ASC;
```

Monitoring results depend on permissions, PostgreSQL configuration, and the workload observed during collection.

The SQL queries can serve as a starting point for scheduled health checks or integration with a monitoring dashboard.

---

## Schema Design

The database models a typical e-commerce order-management workflow.

```text
customers ───────────────┐
                         │
categories ── products ──┼── orders ── order_items ── returns
                │        │      │
                │        │      ├── payments
                │        │      └── order_status_history
                │        │
                └── inventory ── warehouses
```

The diagram illustrates the major entities conceptually. Refer to `schema.sql` for the actual foreign keys and cardinalities.

### Schema features

- **10 relational tables:** Organize customers, categories, products, orders, order items, payments, inventory, warehouses, returns, and order status history.
- **Third normal form:** The schema is designed to reduce unnecessary duplication and update anomalies.
- **Three triggers:** Automate selected status-history and inventory-timestamp operations.
- **Two views:** `v_customer_ltv` and `v_daily_revenue` provide convenient access to analytical data.
- **Generated column:** `order_items.line_total` stores a computed line-total value.
- **Hierarchical categories:** A self-referencing foreign key supports parent-child category relationships.
- **Data integrity:** Primary keys, foreign keys, and other constraints enforce relationships and validity rules.

The exact behavior and constraints are defined in [`schema.sql`](schema.sql).

---

## Engineering Decisions and Lessons Learned

This project explores several practical database engineering trade-offs.

### Indexing is workload-dependent

Indexes can reduce lookup costs, but they consume storage and add maintenance overhead to writes. Broad aggregations may still need to process most of a table.

### Execution plans matter

Query text alone does not explain performance. Scan methods, join strategies, row estimates, sorting, aggregation, and temporary disk usage all influence execution time.

### Backups must be restored and validated

Creating a dump is not enough. Restoration and data-integrity checks are necessary to demonstrate that a backup can support recovery.

### Replication requires operational verification

A configured standby is not proof of successful replication. Validate data propagation, read-only behavior, connection health, and lag.

### Security is more than granting permissions

Roles, row-level security, auditing, and restrictions on destructive operations need to be tested against realistic access patterns.

---

## Future Improvements

If extended toward a production-style environment, the next steps would include:

- **Partitioning:** Evaluate monthly range partitioning for `orders` to improve time-based maintenance and archival workflows.
- **Workload analysis:** Enable `pg_stat_statements` to identify expensive queries from observed workloads.
- **Connection pooling:** Add PgBouncer to manage connection overhead.
- **Automated backups:** Integrate scheduled backups, external storage, retention policies, and automated restore verification.
- **Schema migrations:** Introduce Flyway or Sqitch for version-controlled database changes.
- **Monitoring dashboards:** Integrate selected health metrics with Grafana and an appropriate PostgreSQL exporter.
- **Failure testing:** Test replica interruption, reconnection, recovery, and failover procedures.
- **Continuous integration:** Run SQL integration tests and configuration checks automatically.

These are proposed improvements, not claims that the corresponding production infrastructure is already implemented.

---

## Learning Outcomes

Through this project, I explored:

- Relational schema design and normalization
- Complex SQL queries for business analytics
- Index selection and execution-plan interpretation
- PostgreSQL administration and monitoring
- Backup and restore procedures
- Streaming replication concepts
- Role-based access control and row-level security
- Audit logging and database integrity
- Docker-based database environments
- Performance measurement and operational troubleshooting

## Conclusion

The E-Commerce Order Management Database combines SQL development with practical database administration. Its focus is not simply on creating tables, but on examining how query optimization, security, replication, backup recovery, and monitoring affect the reliability and performance of a database system.

The project serves as a portfolio demonstration of database engineering concepts relevant to backend development, database administration, and software engineering.

## Author

**Nasib**

B.Tech, Information Technology  
National Institute of Technology, Kurukshetra

GitHub: [Nasibyun](https://github.com/Nasibyun)

Portfolio: [nasibyun.vercel.app](https://nasibyun.vercel.app)
