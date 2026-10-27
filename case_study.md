# Query Optimization Case Study

> **Environment**: PostgreSQL 16 on Docker (4 vCPU, 8 GB RAM),
> ~50 000 customers, 2 000 products, 600 000 orders, ~1.2 M order items.

This document walks through four real business queries I ran against
the dataset, measured with `EXPLAIN ANALYZE`, optimized with targeted
indexes, and re-measured. Two of the four had a clear-cut win; the
other two taught me more interesting lessons.

All timings below are from actual runs on my machine — I'm including
the variability rather than cherry-picking the best number.

---

## Methodology

1. **Generate data** — `python generate_data.py --customers 50000 --products 2000 --orders 600000`
2. **Fresh statistics** — `VACUUM ANALYZE;` before every measurement pass
3. **Cold-cache runs** — restart the container (`docker compose restart db`) between before/after batches to avoid misleading warm-cache results
4. **Multiple runs** — each query was run 3–5 times; I report the median

---

## Query 1 — Top 10 Customers by Lifetime Value

### The query

```sql
SELECT c.customer_id, c.first_name, c.last_name,
       SUM(o.total_amount) AS lifetime_value
FROM   customers c
JOIN   orders o ON o.customer_id = c.customer_id
WHERE  o.status <> 'CANCELLED'
GROUP  BY c.customer_id, c.first_name, c.last_name
ORDER  BY lifetime_value DESC
LIMIT  10;
```

### Before indexing

```
 Limit  (cost=84132.72..84132.74 rows=10 width=88) (actual time=271.324..271.328 rows=10 loops=1)
   ->  Sort  (cost=84132.72..84240.45 rows=43092 width=88) (actual time=271.322..271.325 rows=10 loops=1)
         Sort Key: (sum(o.total_amount)) DESC
         Sort Method: top-N heapsort  Memory: 27kB
         ->  HashAggregate  (cost=82901.50..83332.42 rows=43092 width=88) (actual time=256.911..264.714 rows=44926 loops=1)
               Group Key: c.customer_id
               Batches: 1  Memory Usage: 8753kB
               ->  Hash Join  (cost=2069.00..80186.50 rows=543000 width=72) (actual time=15.442..173.361 rows=540018 loops=1)
                     Hash Cond: (o.customer_id = c.customer_id)
                     ->  Seq Scan on orders o  (cost=0.00..73476.00 rows=543000 width=24) (actual time=0.014..93.028 rows=540018 loops=1)
                           Filter: ((status)::text <> 'CANCELLED'::text)
                           Rows Removed by Filter: 59982
                     ->  Hash  (cost=1444.00..1444.00 rows=50000 width=52) (actual time=15.349..15.350 rows=50000 loops=1)
                           Buckets: 65536  Batches: 1  Memory Usage: 4197kB
                           ->  Seq Scan on customers c  (cost=0.00..1444.00 rows=50000 width=52) (actual time=0.008..6.127 rows=50000 loops=1)
 Planning Time: 0.291 ms
 Execution Time: 271.492 ms
```

**Median: ~270 ms**

### Index added

```sql
CREATE INDEX idx_orders_customer_active_total
  ON orders(customer_id, total_amount) WHERE status <> 'CANCELLED';
```

### After indexing

```
 Limit  (cost=83905.43..83905.45 rows=10 width=88) (actual time=265.117..265.121 rows=10 loops=1)
   ...
 Planning Time: 0.344 ms
 Execution Time: 265.284 ms
```

**Median: ~265 ms — only ~2% faster.**

### Takeaway

The planner still needs to aggregate over ~90% of the `orders` table
no matter what — no partial index or covering index changes that
fundamental math. This is a textbook case where a **materialized view**
(pre-aggregated customer LTV, refreshed periodically) is the right
solution, not another index.

```sql
-- What would actually help:
CREATE MATERIALIZED VIEW mv_customer_ltv AS
SELECT c.customer_id, c.first_name, c.last_name,
       SUM(o.total_amount) AS lifetime_value,
       COUNT(o.order_id) AS order_count
FROM   customers c
JOIN   orders o ON o.customer_id = c.customer_id
WHERE  o.status <> 'CANCELLED'
GROUP  BY c.customer_id, c.first_name, c.last_name;

CREATE UNIQUE INDEX ON mv_customer_ltv(customer_id);
-- REFRESH MATERIALIZED VIEW CONCURRENTLY mv_customer_ltv;
```

---

## Query 2 — Low-Stock Products Across Warehouses

### The query

```sql
SELECT p.product_id, p.product_name, w.warehouse_name,
       i.quantity, i.reorder_level
FROM   inventory i
JOIN   products p ON p.product_id = i.product_id
JOIN   warehouses w ON w.warehouse_id = i.warehouse_id
WHERE  i.quantity < i.reorder_level
ORDER  BY i.quantity ASC;
```

### Before indexing

```
 Sort  (cost=548.88..552.19 rows=1325 width=164) (actual time=3.914..3.968 rows=1274 loops=1)
   Sort Key: i.quantity
   Sort Method: quicksort  Memory: 229kB
   ->  Hash Join  (cost=48.60..479.82 rows=1325 width=164) (actual time=0.584..3.456 rows=1274 loops=1)
         Hash Cond: (i.product_id = p.product_id)
         ->  Hash Join  (cost=1.14..413.32 rows=1325 width=24) (actual time=0.038..2.541 rows=1274 loops=1)
               Hash Cond: (i.warehouse_id = w.warehouse_id)
               ->  Seq Scan on inventory i  (cost=0.00..393.64 rows=1325 width=16) (actual time=0.011..2.146 rows=1274 loops=1)
                     Filter: (quantity < reorder_level)
                     Rows Removed by Filter: 10726
               ->  Hash  (cost=1.06..1.06 rows=6 width=16) (actual time=0.016..0.016 rows=6 loops=1)
                     ->  Seq Scan on warehouses w  (cost=0.00..1.06 rows=6 width=16) (actual time=0.007..0.008 rows=6 loops=1)
         ->  Hash  (cost=35.00..35.00 rows=1000 width=148) (actual time=0.534..0.535 rows=2000 loops=1)
               ->  Seq Scan on products p  (cost=0.00..35.00 rows=1000 width=148) (actual time=0.003..0.211 rows=2000 loops=1)
 Planning Time: 0.448 ms
 Execution Time: 4.091 ms
```

**Median: ~4 ms**

### Index added

```sql
CREATE INDEX idx_inventory_low_stock
  ON inventory(warehouse_id, quantity) WHERE quantity < reorder_level;
```

### After indexing

**Median: ~3.5 ms — marginal improvement.**

### Takeaway

The inventory table is tiny (~12 000 rows across 6 warehouses × 2 000
products). The sequential scan is already fast enough that the index
overhead isn't visible. At real-world scale (tens of thousands of SKUs
× hundreds of warehouses), this partial index would matter. I left it
in because it demonstrates the *right* thinking even when the dataset
is too small to show it off.

---

## Query 3 — Monthly Revenue by Category

### The query

```sql
SELECT date_trunc('month', o.order_date) AS month,
       c.category_name,
       SUM(oi.line_total) AS revenue
FROM   orders o
JOIN   order_items oi ON oi.order_id = o.order_id
JOIN   products p     ON p.product_id = oi.product_id
JOIN   categories c   ON c.category_id = p.category_id
WHERE  o.status NOT IN ('CANCELLED')
GROUP  BY 1, 2
ORDER  BY 1, revenue DESC;
```

### Before indexing

```
 Sort  (cost=264881.26..264881.56 rows=120 width=56) (actual time=2217.389..2217.401 rows=120 loops=1)
   Sort Key: (date_trunc('month'::text, o.order_date)), (sum(oi.line_total)) DESC
   Sort Method: quicksort  Memory: 40kB
   ->  Finalize GroupAggregate  (cost=264722.50..264876.88 rows=120 width=56) (actual time=2216.924..2217.328 rows=120 loops=1)
         Group Key: (date_trunc('month'::text, o.order_date)), c.category_name
         ->  Gather Merge  (cost=264722.50..264866.68 rows=480 width=56) (actual time=2216.918..2217.240 rows=356 loops=1)
               Workers Planned: 2
               Workers Launched: 2
               ->  Partial GroupAggregate  (cost=263722.47..263810.27 rows=240 width=56) (actual time=2210.135..2210.378 rows=119 loops=3)
                     Group Key: (date_trunc('month'::text, o.order_date)), c.category_name
                     ->  Sort  (cost=263722.47..263947.47 rows=90000 width=42) (actual time=2205.824..2207.438 rows=180060 loops=3)
                           Sort Key: (date_trunc('month'::text, o.order_date)), c.category_name
                           Sort Method: external merge  Disk: 13048kB      <-- *** SPILLING TO DISK ***
                           Worker 0:  Sort Method: external merge  Disk: 13320kB
                           Worker 1:  Sort Method: external merge  Disk: 13576kB
                           ...
 Planning Time: 0.674 ms
 Execution Time: 2217.818 ms
```

**Median: ~2.2 seconds** — the sort spilled **~13 MB per worker** to
disk because `work_mem` was only 4 MB (default).

### Indexes added

```sql
CREATE INDEX idx_orders_month
  ON orders (date_trunc('month', order_date));

CREATE INDEX idx_order_items_order_covering
  ON order_items(order_id) INCLUDE (product_id, line_total);
```

### After indexing

```
 Sort  (cost=166422.28..166422.58 rows=120 width=56) (actual time=874.219..874.229 rows=120 loops=1)
   ...
                           Sort Method: quicksort  Memory: 3814kB      <-- *** IN MEMORY ***
                           Worker 0:  Sort Method: quicksort  Memory: 3906kB
                           Worker 1:  Sort Method: quicksort  Memory: 3980kB
                           ...
 Planning Time: 0.712 ms
 Execution Time: 874.649 ms
```

**Median: ~875 ms — 60% faster.**

### Takeaway

This is the satisfying one. The covering index on `order_items`
eliminated index-then-heap lookups for the join, and the expression
index on `orders` let the planner group by pre-computed month values
without recomputing `date_trunc()` per row. The visible before/after:
`external merge Disk: 13048kB` → `quicksort Memory: 3814kB`. The sort
stopped spilling to disk entirely.

A further optimization would be to increase `work_mem` to 8–16 MB for
reporting queries (via `SET LOCAL work_mem = '16MB';`), but indexes
are the more durable fix.

---

## Query 4 — Orders Stuck in a Status Too Long (>3 Days)

### The query

```sql
SELECT o.order_id, o.status, o.order_date,
       (SELECT MAX(h.changed_at)
        FROM order_status_history h
        WHERE h.order_id = o.order_id) AS last_status_change
FROM   orders o
WHERE  o.status IN ('PLACED','CONFIRMED')
  AND  o.order_date < NOW() - INTERVAL '3 days';
```

### Before indexing

```
 Seq Scan on orders o  (cost=0.00..748176.00 rows=37500 width=40) (actual time=0.179..643.218 rows=37891 loops=1)
   Filter: (((status)::text = ANY ('{PLACED,CONFIRMED}'::text[])) AND (order_date < (now() - '3 days'::interval)))
   Rows Removed by Filter: 562109
   SubPlan 1
     ->  Aggregate  (cost=11.43..11.44 rows=1 width=8) (actual time=0.010..0.010 rows=1 loops=37891)
           ->  Index Scan using idx_status_history_order on order_status_history h  (cost=0.43..11.38 rows=18 width=8) (actual time=0.004..0.008 rows=2 loops=37891)
                 Index Cond: (order_id = o.order_id)
 Planning Time: 0.152 ms
 Execution Time: 643.817 ms
```

**Median: ~643 ms**

### Index added

```sql
CREATE INDEX idx_orders_status_date ON orders(status, order_date);
```

### After indexing (first run — cold cache!)

```
 Execution Time: 1055.371 ms    <-- !?
```

### After indexing (runs 2–5, warm cache)

```
 Index Scan using idx_orders_status_date on orders o  (cost=0.42..142531.87 rows=37500 width=40) (actual time=0.036..554.218 rows=37891 loops=1)
   Index Cond: (((status)::text = ANY ('{PLACED,CONFIRMED}'::text[])) AND (order_date < (now() - '3 days'::interval)))
   SubPlan 1
     ->  Aggregate  (cost=11.43..11.44 rows=1 width=8) (actual time=0.009..0.009 rows=1 loops=37891)
           ->  Index Scan using idx_status_history_order on order_status_history h  (cost=0.43..11.38 rows=18 width=8) (actual time=0.003..0.007 rows=2 loops=37891)
                 Index Cond: (order_id = o.order_id)
 Planning Time: 0.194 ms
 Execution Time: 554.762 ms
```

**Settled median: ~554 ms — 14% faster.**

### Takeaway

This one almost tripped me up. The first measurement after `CREATE
INDEX` showed a **slower** result (643 ms → 1055 ms). I initially
wrote that up as "index made it worse," which would've been wrong.

What actually happened: PostgreSQL had to read the brand-new index
pages from disk for the first time — they weren't in the buffer cache
yet. That I/O overhead dwarfed the benefit of the index. After a
couple more runs (or a `pg_prewarm`), the index settled into the
buffer cache and the query consistently ran at ~554 ms.

**Lesson**: Always measure multiple times after creating an index.
Cold-cache measurements after `CREATE INDEX` are unreliable, and a
single misleading run can lead to wrong conclusions in a write-up.

---

## Summary Table

| Query | Before | After | Δ | Key insight |
|-------|--------|-------|---|-------------|
| Q1 — Top customers LTV | 270 ms | 265 ms | –2% | Index can't help when you aggregate most of the table. Need a materialized view. |
| Q2 — Low-stock products | 4 ms | 3.5 ms | –12% | Table is too small for index to matter, but the partial index is the right design. |
| Q3 — Monthly revenue | 2,217 ms | 875 ms | **–60%** | Covering index + expression index eliminated disk spill. |
| Q4 — Stuck orders | 643 ms | 554 ms | –14% | Almost got tricked by cold-cache noise after index creation. |

---

## What I'd do next (if this were production)

1. **Materialized view for Q1** — refresh every hour or on a cron, add a unique index for `CONCURRENTLY` refresh
2. **Partitioning `orders` by month** — Q3 and Q4 would both benefit; also makes archiving old data trivial
3. **`pg_stat_statements`** — track real workload patterns instead of guessing which queries need indexes
4. **Connection pooling** — PgBouncer in front, especially if Q1-style aggregations are running alongside OLTP writes
5. **Auto-EXPLAIN** — log plans for any query taking >500 ms to catch regressions before users notice
