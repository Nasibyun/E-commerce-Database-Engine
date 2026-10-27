-- =========================================================
-- Security & Access Control
-- Role-based access, row-level security, audit logging
-- =========================================================
-- This addresses the "still to do" section from the README.
-- Run this AFTER schema.sql has been applied.
--
-- Roles:
--   analyst_ro   — read-only access to all tables (data analysts)
--   app_rw       — read/write to transactional tables (application)
--   dba_admin    — full access (DBA)
-- =========================================================

-- ---------------------------------------------------------
-- 1. Create roles
-- ---------------------------------------------------------

-- Read-only analyst role
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analyst_ro') THEN
    CREATE ROLE analyst_ro WITH LOGIN PASSWORD 'analyst_secure_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

-- Application read/write role
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_rw') THEN
    CREATE ROLE app_rw WITH LOGIN PASSWORD 'app_secure_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END $$;

-- DBA admin role
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'dba_admin') THEN
    CREATE ROLE dba_admin WITH LOGIN PASSWORD 'dba_secure_pw' SUPERUSER CREATEDB CREATEROLE;
  END IF;
END $$;

-- ---------------------------------------------------------
-- 2. Grant privileges
-- ---------------------------------------------------------

-- Analyst: SELECT on all current and future tables
GRANT CONNECT ON DATABASE ecommerce_dba TO analyst_ro;
GRANT USAGE ON SCHEMA public TO analyst_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO analyst_ro;

-- App: full CRUD on transactional tables, SELECT on reference tables
GRANT CONNECT ON DATABASE ecommerce_dba TO app_rw;
GRANT USAGE ON SCHEMA public TO app_rw;

-- Reference tables: read-only for the app
GRANT SELECT ON categories, products, warehouses TO app_rw;

-- Transactional tables: full CRUD
GRANT SELECT, INSERT, UPDATE, DELETE ON
  customers, orders, order_items, order_status_history,
  payments, returns, inventory
TO app_rw;

-- App needs sequence access to insert rows
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_rw;

-- DBA: everything (already superuser, but be explicit)
GRANT ALL PRIVILEGES ON DATABASE ecommerce_dba TO dba_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO dba_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO dba_admin;

-- ---------------------------------------------------------
-- 3. Row-Level Security (RLS) — example on customers table
-- ---------------------------------------------------------
-- Scenario: analysts can only see active customers.
-- The app role can see all customers (it needs to handle deactivation).

ALTER TABLE customers ENABLE ROW LEVEL SECURITY;

-- Policy: analysts see only active customers
CREATE POLICY analyst_active_only ON customers
  FOR SELECT
  TO analyst_ro
  USING (is_active = TRUE);

-- Policy: app role sees all customers
CREATE POLICY app_full_access ON customers
  FOR ALL
  TO app_rw
  USING (TRUE)
  WITH CHECK (TRUE);

-- Superusers and table owners bypass RLS by default, which is what we want for dba_admin.

-- ---------------------------------------------------------
-- 4. Audit logging table
-- ---------------------------------------------------------

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    table_name      TEXT NOT NULL,
    operation       TEXT NOT NULL CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE')),
    row_id          BIGINT,
    old_data        JSONB,
    new_data        JSONB,
    changed_by      TEXT NOT NULL DEFAULT current_user,
    changed_at      TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_table ON audit_log(table_name, changed_at);
CREATE INDEX idx_audit_log_time ON audit_log(changed_at);

-- ---------------------------------------------------------
-- 5. Audit trigger function
-- ---------------------------------------------------------

CREATE OR REPLACE FUNCTION fn_audit_trigger()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO audit_log (table_name, operation, row_id, new_data)
    VALUES (TG_TABLE_NAME, 'INSERT',
            CASE WHEN TG_TABLE_NAME = 'customers' THEN NEW.customer_id
                 WHEN TG_TABLE_NAME = 'orders' THEN NEW.order_id
                 ELSE NULL END,
            to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO audit_log (table_name, operation, row_id, old_data, new_data)
    VALUES (TG_TABLE_NAME, 'UPDATE',
            CASE WHEN TG_TABLE_NAME = 'customers' THEN NEW.customer_id
                 WHEN TG_TABLE_NAME = 'orders' THEN NEW.order_id
                 ELSE NULL END,
            to_jsonb(OLD), to_jsonb(NEW));
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    INSERT INTO audit_log (table_name, operation, row_id, old_data)
    VALUES (TG_TABLE_NAME, 'DELETE',
            CASE WHEN TG_TABLE_NAME = 'customers' THEN OLD.customer_id
                 WHEN TG_TABLE_NAME = 'orders' THEN OLD.order_id
                 ELSE NULL END,
            to_jsonb(OLD));
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ---------------------------------------------------------
-- 6. Attach audit triggers to critical tables
-- ---------------------------------------------------------

CREATE TRIGGER trg_audit_customers
  AFTER INSERT OR UPDATE OR DELETE ON customers
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

CREATE TRIGGER trg_audit_orders
  AFTER INSERT OR UPDATE OR DELETE ON orders
  FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger();

-- ---------------------------------------------------------
-- 7. Prevent the app role from truncating tables
-- ---------------------------------------------------------

REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM app_rw;

-- ---------------------------------------------------------
-- 8. Verification queries
-- ---------------------------------------------------------

-- Check role privileges
-- SELECT grantee, table_name, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE grantee IN ('analyst_ro', 'app_rw')
-- ORDER BY grantee, table_name;

-- Check RLS policies
-- SELECT tablename, policyname, permissive, roles, qual
-- FROM pg_policies
-- WHERE tablename = 'customers';

-- Test audit log
-- INSERT INTO customers (first_name, last_name, email, phone, signup_date, city, state)
-- VALUES ('Audit', 'Test', 'audit-test@example.com', '9876543210', CURRENT_DATE, 'Mumbai', 'Maharashtra');
-- SELECT * FROM audit_log ORDER BY audit_id DESC LIMIT 5;
