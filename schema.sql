-- =========================================================
-- E-Commerce Order Management Database
-- DBA Portfolio Project — Schema (PostgreSQL 16)
-- =========================================================
--
-- Design notes:
--  - Normalized to 3NF.
--  - order_status_history exists separately from orders.status
--    so we can show state-transition queries and audit trails
--    (a common real-world DBA/reporting requirement).
--  - inventory is per (product, warehouse) to model multi-warehouse
--    stock, which is what makes "low stock" queries non-trivial.
--  - Indexes are added deliberately AFTER you've run the "before"
--    EXPLAIN ANALYZE in step 4 of the project — don't create them
--    all up front, or you lose your before/after story.
--  - Triggers auto-populate order_status_history on INSERT so the
--    initial "PLACED" record is always present even if the app
--    forgets to insert it.
--
-- Table count: 10 (customers, categories, products, warehouses,
--   inventory, orders, order_items, order_status_history,
--   payments, returns)
-- =========================================================

DROP TABLE IF EXISTS returns CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS order_status_history CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS categories CASCADE;
DROP TABLE IF EXISTS warehouses CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

-- =========================================================
-- Reference / dimension tables
-- =========================================================

CREATE TABLE customers (
    customer_id     BIGSERIAL PRIMARY KEY,
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(150) NOT NULL UNIQUE,
    phone           VARCHAR(20),
    signup_date     DATE NOT NULL DEFAULT CURRENT_DATE,
    city            VARCHAR(80),
    state           VARCHAR(80),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- Useful for filtering/analytics by city or state
COMMENT ON TABLE customers IS 'End-user accounts; one row per registered customer.';
COMMENT ON COLUMN customers.is_active IS 'FALSE = soft-deleted or suspended account.';

CREATE TABLE categories (
    category_id     SERIAL PRIMARY KEY,
    category_name   VARCHAR(100) NOT NULL UNIQUE,
    parent_category_id INTEGER REFERENCES categories(category_id)
);

COMMENT ON TABLE categories IS 'Product categories with optional self-referencing hierarchy.';

CREATE TABLE products (
    product_id      BIGSERIAL PRIMARY KEY,
    sku             VARCHAR(30) NOT NULL UNIQUE,
    product_name    VARCHAR(200) NOT NULL,
    category_id     INTEGER NOT NULL REFERENCES categories(category_id),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    weight_kg       NUMERIC(6,2),  -- useful for shipping cost calculations
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE products IS 'Product catalog; unit_price is the current list price (order_items captures the price-at-time-of-purchase).';

CREATE TABLE warehouses (
    warehouse_id    SERIAL PRIMARY KEY,
    warehouse_name  VARCHAR(100) NOT NULL,
    city            VARCHAR(80) NOT NULL,
    state           VARCHAR(80) NOT NULL,
    capacity        INTEGER DEFAULT 100000  -- max units the warehouse can hold
);

COMMENT ON TABLE warehouses IS 'Physical fulfillment centers; inventory is tracked per-warehouse.';

-- =========================================================
-- Inventory (per product, per warehouse)
-- =========================================================

CREATE TABLE inventory (
    inventory_id    BIGSERIAL PRIMARY KEY,
    product_id      BIGINT NOT NULL REFERENCES products(product_id),
    warehouse_id    INTEGER NOT NULL REFERENCES warehouses(warehouse_id),
    quantity        INTEGER NOT NULL CHECK (quantity >= 0),
    reorder_level   INTEGER NOT NULL DEFAULT 20,
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    UNIQUE (product_id, warehouse_id)
);

COMMENT ON TABLE inventory IS 'Current stock levels per product per warehouse. Reorder alerts fire when quantity < reorder_level.';

-- =========================================================
-- Orders and line items
-- =========================================================

CREATE TABLE orders (
    order_id        BIGSERIAL PRIMARY KEY,
    customer_id     BIGINT NOT NULL REFERENCES customers(customer_id),
    order_date      TIMESTAMP NOT NULL DEFAULT NOW(),
    status          VARCHAR(20) NOT NULL DEFAULT 'PLACED'
                        CHECK (status IN ('PLACED','CONFIRMED','SHIPPED','DELIVERED','CANCELLED','RETURNED')),
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    shipping_city   VARCHAR(80),
    shipping_state  VARCHAR(80),
    notes           TEXT  -- internal ops notes, delivery instructions, etc.
);

COMMENT ON TABLE orders IS 'One row per customer order. total_amount is backfilled from order_items after insertion.';
COMMENT ON COLUMN orders.status IS 'Current status. Full transition history is in order_status_history.';

CREATE TABLE order_items (
    order_item_id   BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id      BIGINT NOT NULL REFERENCES products(product_id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    line_total      NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);

COMMENT ON COLUMN order_items.unit_price IS 'Price at time of purchase — may differ from products.unit_price if the product price changed.';
COMMENT ON COLUMN order_items.line_total IS 'Generated column: quantity × unit_price. Stored for index/aggregation performance.';

CREATE TABLE order_status_history (
    history_id      BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    status          VARCHAR(20) NOT NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    changed_by      VARCHAR(50) DEFAULT current_user  -- who/what made the change
);

COMMENT ON TABLE order_status_history IS 'Append-only audit trail of every status change for every order.';

-- =========================================================
-- Payments and returns
-- =========================================================

CREATE TABLE payments (
    payment_id      BIGSERIAL PRIMARY KEY,
    order_id        BIGINT NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    amount          NUMERIC(12,2) NOT NULL CHECK (amount >= 0),
    payment_method  VARCHAR(20) NOT NULL CHECK (payment_method IN ('CARD','UPI','NETBANKING','COD','WALLET')),
    payment_status  VARCHAR(20) NOT NULL DEFAULT 'SUCCESS'
                        CHECK (payment_status IN ('SUCCESS','FAILED','REFUNDED','PENDING')),
    paid_at         TIMESTAMP NOT NULL DEFAULT NOW(),
    transaction_ref VARCHAR(100)  -- external payment gateway reference ID
);

COMMENT ON TABLE payments IS 'One or more payment attempts per order. Most orders have exactly one SUCCESS payment.';

CREATE TABLE returns (
    return_id       BIGSERIAL PRIMARY KEY,
    order_item_id   BIGINT NOT NULL REFERENCES order_items(order_item_id),
    reason          VARCHAR(200),
    return_date     TIMESTAMP NOT NULL DEFAULT NOW(),
    refund_amount   NUMERIC(10,2) NOT NULL CHECK (refund_amount >= 0),
    refund_status   VARCHAR(20) NOT NULL DEFAULT 'PENDING'
                        CHECK (refund_status IN ('PENDING','PROCESSED','REJECTED'))
);

COMMENT ON TABLE returns IS 'Per-item returns. An order with status RETURNED may have returns for some or all of its items.';

-- =========================================================
-- Triggers
-- =========================================================

-- Auto-insert an order_status_history row when a new order is created
CREATE OR REPLACE FUNCTION fn_order_initial_status()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO order_status_history (order_id, status, changed_at)
    VALUES (NEW.order_id, NEW.status, NEW.order_date);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_initial_status
    AFTER INSERT ON orders
    FOR EACH ROW
    EXECUTE FUNCTION fn_order_initial_status();

-- Auto-insert an order_status_history row when an order status changes
CREATE OR REPLACE FUNCTION fn_order_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.order_id, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_status_change
    AFTER UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION fn_order_status_change();

-- Auto-update inventory.updated_at on quantity changes
CREATE OR REPLACE FUNCTION fn_inventory_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_inventory_updated_at
    BEFORE UPDATE ON inventory
    FOR EACH ROW
    WHEN (OLD.quantity IS DISTINCT FROM NEW.quantity)
    EXECUTE FUNCTION fn_inventory_updated_at();

-- =========================================================
-- Baseline indexes (foreign keys only — deliberately minimal)
-- Add tuning indexes later, after you've captured the "before"
-- EXPLAIN ANALYZE output for your case-study queries.
-- =========================================================

CREATE INDEX idx_products_category ON products(category_id);
CREATE INDEX idx_inventory_product ON inventory(product_id);
CREATE INDEX idx_inventory_warehouse ON inventory(warehouse_id);
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_date ON orders(order_date);
CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(product_id);
CREATE INDEX idx_payments_order ON payments(order_id);
CREATE INDEX idx_status_history_order ON order_status_history(order_id);
CREATE INDEX idx_returns_order_item ON returns(order_item_id);

-- =========================================================
-- Views (convenient for analysts)
-- =========================================================

-- Customer lifetime value (quick access without materialized view)
CREATE OR REPLACE VIEW v_customer_ltv AS
SELECT
    c.customer_id,
    c.first_name || ' ' || c.last_name AS customer_name,
    c.email,
    c.city,
    c.state,
    COUNT(o.order_id)        AS total_orders,
    SUM(o.total_amount)      AS lifetime_value,
    MIN(o.order_date)        AS first_order,
    MAX(o.order_date)        AS last_order,
    c.signup_date
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id AND o.status <> 'CANCELLED'
GROUP BY c.customer_id, c.first_name, c.last_name, c.email, c.city, c.state, c.signup_date;

-- Daily revenue summary
CREATE OR REPLACE VIEW v_daily_revenue AS
SELECT
    DATE(o.order_date)       AS order_day,
    COUNT(DISTINCT o.order_id) AS orders_placed,
    SUM(o.total_amount)      AS gross_revenue,
    COUNT(DISTINCT o.customer_id) AS unique_customers
FROM orders o
WHERE o.status NOT IN ('CANCELLED')
GROUP BY DATE(o.order_date)
ORDER BY order_day DESC;
