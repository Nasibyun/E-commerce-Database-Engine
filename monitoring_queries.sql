-- =========================================================
-- DBA Monitoring & Health-Check Queries
-- =========================================================
-- A collection of production-grade monitoring queries for
-- PostgreSQL. Run these ad-hoc or wire them into a Grafana
-- dashboard / cron alerting job.
-- =========================================================

-- ---------------------------------------------------------
-- 1. Database size overview
-- ---------------------------------------------------------
SELECT
    pg_database.datname                          AS database,
    pg_size_pretty(pg_database_size(datname))    AS total_size
FROM pg_database
WHERE datname = 'ecommerce_dba';

-- ---------------------------------------------------------
-- 2. Table sizes (data + indexes + TOAST), sorted largest first
-- ---------------------------------------------------------
SELECT
    schemaname || '.' || relname                          AS table_name,
    pg_size_pretty(pg_total_relation_size(relid))         AS total_size,
    pg_size_pretty(pg_relation_size(relid))               AS table_data,
    pg_size_pretty(pg_total_relation_size(relid)
                   - pg_relation_size(relid))             AS indexes_toast,
    n_live_tup                                            AS live_rows,
    n_dead_tup                                            AS dead_rows,
    CASE WHEN n_live_tup > 0
         THEN round(100.0 * n_dead_tup / n_live_tup, 1)
         ELSE 0 END                                       AS dead_pct
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- ---------------------------------------------------------
-- 3. Index usage statistics — find unused indexes
-- ---------------------------------------------------------
-- Indexes that exist but are never (or rarely) scanned waste
-- disk and slow down writes. Safe to drop if idx_scan ≈ 0
-- for weeks in production.
SELECT
    schemaname || '.' || relname   AS table_name,
    indexrelname                   AS index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan                       AS times_used,
    idx_tup_read                   AS rows_read,
    idx_tup_fetch                  AS rows_fetched
FROM pg_stat_user_indexes
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC;

-- ---------------------------------------------------------
-- 4. Cache hit ratio — should be > 99% in production
-- ---------------------------------------------------------
SELECT
    'index hit rate' AS metric,
    round(
        sum(idx_blks_hit) * 100.0 /
        NULLIF(sum(idx_blks_hit + idx_blks_read), 0), 2
    ) AS ratio
FROM pg_statio_user_indexes
UNION ALL
SELECT
    'table hit rate',
    round(
        sum(heap_blks_hit) * 100.0 /
        NULLIF(sum(heap_blks_hit + heap_blks_read), 0), 2
    )
FROM pg_statio_user_tables;

-- ---------------------------------------------------------
-- 5. Slow query candidates (requires pg_stat_statements)
-- ---------------------------------------------------------
-- Uncomment after enabling pg_stat_statements in postgresql.conf:
--   shared_preload_libraries = 'pg_stat_statements'
--   CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- SELECT
--     round(total_exec_time::numeric, 2)                  AS total_ms,
--     calls,
--     round((total_exec_time / calls)::numeric, 2)        AS avg_ms,
--     round((rows / calls::numeric), 0)                   AS avg_rows,
--     left(query, 120)                                    AS query_preview
-- FROM pg_stat_statements
-- ORDER BY total_exec_time DESC
-- LIMIT 20;

-- ---------------------------------------------------------
-- 6. Active connections and their state
-- ---------------------------------------------------------
SELECT
    state,
    usename,
    datname,
    count(*)                                       AS connections,
    max(now() - state_change)                      AS longest_in_state
FROM pg_stat_activity
WHERE datname = 'ecommerce_dba'
GROUP BY state, usename, datname
ORDER BY connections DESC;

-- ---------------------------------------------------------
-- 7. Lock contention — who's blocking whom
-- ---------------------------------------------------------
SELECT
    blocked.pid         AS blocked_pid,
    blocked.usename     AS blocked_user,
    blocking.pid        AS blocking_pid,
    blocking.usename    AS blocking_user,
    blocked.query       AS blocked_query,
    blocking.query      AS blocking_query,
    now() - blocked.query_start AS blocked_duration
FROM pg_catalog.pg_locks bl
JOIN pg_catalog.pg_stat_activity blocked  ON bl.pid = blocked.pid
JOIN pg_catalog.pg_locks kl
    ON bl.transactionid = kl.transactionid AND bl.pid != kl.pid
JOIN pg_catalog.pg_stat_activity blocking ON kl.pid = blocking.pid
WHERE NOT bl.granted;

-- ---------------------------------------------------------
-- 8. Replication lag (run on primary)
-- ---------------------------------------------------------
SELECT
    client_addr,
    usename,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- ---------------------------------------------------------
-- 9. Tables that need vacuuming
-- ---------------------------------------------------------
SELECT
    schemaname || '.' || relname                          AS table_name,
    n_dead_tup,
    n_live_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 1) AS dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;

-- ---------------------------------------------------------
-- 10. Bloat estimation (simplified)
-- ---------------------------------------------------------
-- For a more accurate bloat check, use pgstattuple extension:
--   CREATE EXTENSION IF NOT EXISTS pgstattuple;
--   SELECT * FROM pgstattuple('orders');

SELECT
    relname                                        AS table_name,
    pg_size_pretty(pg_relation_size(oid))          AS current_size,
    reltuples::bigint                              AS estimated_rows,
    CASE WHEN reltuples > 0
         THEN pg_size_pretty(
                  (pg_relation_size(oid) / reltuples * 0.8)::bigint
                  * reltuples::bigint
              )
         ELSE '0 bytes'
    END                                            AS estimated_min_size
FROM pg_class
WHERE relkind = 'r'
  AND relnamespace = 'public'::regnamespace
ORDER BY pg_relation_size(oid) DESC;

-- ---------------------------------------------------------
-- 11. Long-running transactions (potential MVCC bloat source)
-- ---------------------------------------------------------
SELECT
    pid,
    usename,
    state,
    now() - xact_start   AS transaction_duration,
    now() - query_start  AS query_duration,
    left(query, 100)     AS query_preview
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
  AND state != 'idle'
  AND now() - xact_start > interval '5 minutes'
ORDER BY xact_start;

-- ---------------------------------------------------------
-- 12. Checkpoint and WAL statistics
-- ---------------------------------------------------------
SELECT
    checkpoints_timed,
    checkpoints_req,
    checkpoint_write_time,
    checkpoint_sync_time,
    buffers_checkpoint,
    buffers_clean,
    buffers_backend,
    stats_reset
FROM pg_stat_bgwriter;
