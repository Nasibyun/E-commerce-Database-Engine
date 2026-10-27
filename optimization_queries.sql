-- =========================================================
-- Query Optimization Case Study — runnable SQL
-- Run schema.sql + generate_data.py first.
-- See case_study.md for the full before/after write-up and numbers.
-- =========================================================

-- Always start with fresh stats before measuring.
VACUUM ANALYZE;

-- -------------------------------------------------------
-- Query 1: Top 10 customers by lifetime order value
-- -------------------------------------------------------
-- Business question: Who are our most valuable customers?
-- Expected behavior: sequential scan because we aggregate ~90%
-- of the orders table — indexes can't help much here.
EXPLAIN ANALYZE
SELECT c.customer_id, c.first_name, c.last_name, SUM(o.total_amount) AS lifetime_value
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
WHERE o.status <> 'CANCELLED'
GROUP BY c.customer_id, c.first_name, c.last_name
ORDER BY lifetime_value DESC
LIMIT 10;

-- Index (aggregation touches most of the table, so expect a small gain)
CREATE INDEX IF NOT EXISTS idx_orders_customer_active_total
  ON orders(customer_id, total_amount) WHERE status <> 'CANCELLED';

-- -------------------------------------------------------
-- Query 2: Low-stock products across warehouses
-- -------------------------------------------------------
-- Business question: Which products need restocking, and where?
-- Expected behavior: small result set, fast even without the index
-- at this scale — but the partial index is the right design.
EXPLAIN ANALYZE
SELECT p.product_id, p.product_name, w.warehouse_name, i.quantity, i.reorder_level
FROM inventory i
JOIN products p ON p.product_id = i.product_id
JOIN warehouses w ON w.warehouse_id = i.warehouse_id
WHERE i.quantity < i.reorder_level
ORDER BY i.quantity ASC;

-- Index (useful mainly at larger inventory scale — see case_study.md)
CREATE INDEX IF NOT EXISTS idx_inventory_low_stock
  ON inventory(warehouse_id, quantity) WHERE quantity < reorder_level;

-- -------------------------------------------------------
-- Query 3: Monthly revenue by category
-- -------------------------------------------------------
-- Business question: How does each product category perform month over month?
-- Expected behavior: the big win — covering index eliminates heap
-- lookups, expression index avoids per-row date_trunc recomputation.
EXPLAIN ANALYZE
SELECT date_trunc('month', o.order_date) AS month, c.category_name, SUM(oi.line_total) AS revenue
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p ON p.product_id = oi.product_id
JOIN categories c ON c.category_id = p.category_id
WHERE o.status NOT IN ('CANCELLED')
GROUP BY 1, 2
ORDER BY 1, revenue DESC;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_orders_month ON orders (date_trunc('month', order_date));
CREATE INDEX IF NOT EXISTS idx_order_items_order_covering
  ON order_items(order_id) INCLUDE (product_id, line_total);

-- -------------------------------------------------------
-- Query 4: Orders stuck in a status too long (>3 days)
-- -------------------------------------------------------
-- Business question: Which orders are potentially stuck and need ops attention?
-- Expected behavior: composite index on (status, order_date) lets the
-- planner seek directly instead of scanning all 600K orders.
EXPLAIN ANALYZE
SELECT o.order_id, o.status, o.order_date,
       (SELECT MAX(h.changed_at) FROM order_status_history h WHERE h.order_id = o.order_id) AS last_status_change
FROM orders o
WHERE o.status IN ('PLACED','CONFIRMED')
  AND o.order_date < NOW() - INTERVAL '3 days';

-- Index
CREATE INDEX IF NOT EXISTS idx_orders_status_date ON orders(status, order_date);

-- -------------------------------------------------------
-- Query 5: Payment method breakdown with revenue share
-- -------------------------------------------------------
-- Business question: Which payment methods drive the most revenue?
-- Useful for negotiating payment gateway fees.
EXPLAIN ANALYZE
SELECT
    p.payment_method,
    COUNT(*)                                              AS transaction_count,
    SUM(p.amount)                                         AS total_amount,
    ROUND(100.0 * SUM(p.amount) / SUM(SUM(p.amount)) OVER (), 2) AS pct_of_revenue,
    ROUND(AVG(p.amount), 2)                               AS avg_transaction
FROM payments p
WHERE p.payment_status = 'SUCCESS'
GROUP BY p.payment_method
ORDER BY total_amount DESC;

-- Index for payment analytics
CREATE INDEX IF NOT EXISTS idx_payments_method_status
  ON payments(payment_method, payment_status) INCLUDE (amount);

-- -------------------------------------------------------
-- Query 6: Customer cohort analysis (by signup month)
-- -------------------------------------------------------
-- Business question: How do newer vs. older customer cohorts
-- compare in terms of order volume and spend?
EXPLAIN ANALYZE
SELECT
    date_trunc('quarter', c.signup_date)    AS signup_cohort,
    COUNT(DISTINCT c.customer_id)           AS customers,
    COUNT(o.order_id)                       AS total_orders,
    ROUND(AVG(o.total_amount), 2)           AS avg_order_value,
    ROUND(SUM(o.total_amount)
          / NULLIF(COUNT(DISTINCT c.customer_id), 0), 2) AS revenue_per_customer
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id AND o.status <> 'CANCELLED'
GROUP BY 1
ORDER BY 1;

-- Index
CREATE INDEX IF NOT EXISTS idx_customers_signup ON customers(signup_date);

-- -------------------------------------------------------
-- Query 7: Return rate by product category
-- -------------------------------------------------------
-- Business question: Which categories have quality/fit problems?
EXPLAIN ANALYZE
SELECT
    cat.category_name,
    COUNT(DISTINCT oi.order_item_id)    AS items_sold,
    COUNT(DISTINCT r.return_id)         AS items_returned,
    ROUND(100.0 * COUNT(DISTINCT r.return_id)
          / NULLIF(COUNT(DISTINCT oi.order_item_id), 0), 2) AS return_rate_pct,
    ROUND(COALESCE(SUM(r.refund_amount), 0), 2) AS total_refunded
FROM order_items oi
JOIN products p   ON p.product_id = oi.product_id
JOIN categories cat ON cat.category_id = p.category_id
LEFT JOIN returns r ON r.order_item_id = oi.order_item_id
GROUP BY cat.category_name
ORDER BY return_rate_pct DESC;

-- -------------------------------------------------------
-- Query 8: Warehouse utilization and low-stock alerts
-- -------------------------------------------------------
-- Business question: Which warehouses are overstocked vs. understocked?
EXPLAIN ANALYZE
SELECT
    w.warehouse_name,
    w.city,
    COUNT(i.inventory_id)                                       AS sku_count,
    SUM(i.quantity)                                              AS total_units,
    SUM(CASE WHEN i.quantity < i.reorder_level THEN 1 ELSE 0 END) AS low_stock_skus,
    ROUND(100.0 * SUM(CASE WHEN i.quantity < i.reorder_level THEN 1 ELSE 0 END)
          / NULLIF(COUNT(i.inventory_id), 0), 1)                AS low_stock_pct
FROM warehouses w
JOIN inventory i ON i.warehouse_id = w.warehouse_id
GROUP BY w.warehouse_id, w.warehouse_name, w.city
ORDER BY low_stock_pct DESC;

-- -------------------------------------------------------
-- Re-run all EXPLAIN ANALYZE statements above after the
-- VACUUM ANALYZE below to capture your own "after" numbers.
-- -------------------------------------------------------
VACUUM ANALYZE;
