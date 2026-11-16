-- ============================================================================
-- SUPPORT TICKETS RESOLUTION (PURE SQL)
-- ============================================================================

-- 1. Deduplicate customer accounts and reassign orders
BEGIN TRANSACTION;
UPDATE orders 
SET customer_id = (
    SELECT MIN(c2.customer_id) 
    FROM customers c2 
    WHERE LOWER(TRIM(c2.email)) = (
        SELECT LOWER(TRIM(c1.email)) 
        FROM customers c1 
        WHERE c1.customer_id = orders.customer_id
    )
)
WHERE customer_id NOT IN (SELECT MIN(customer_id) FROM customers GROUP BY LOWER(TRIM(email)));

DELETE FROM customers 
WHERE customer_id NOT IN (SELECT MIN(customer_id) FROM customers GROUP BY LOWER(TRIM(email)));

UPDATE customers SET email = LOWER(TRIM(email));
CREATE UNIQUE INDEX IF NOT EXISTS idx_customers_email ON customers(email);
COMMIT;


-- 2. Reconcile stuck paid orders from PENDING to PROCESSING
BEGIN TRANSACTION;
UPDATE orders 
SET status = 'PROCESSING'
WHERE status = 'PENDING' 
  AND order_id IN (SELECT order_id FROM payments WHERE payment_status = 'PAID');
COMMIT;


-- 3A. Daily failed-payment report
SELECT 
    DATE(payment_date) AS txn_date, 
    payment_method, 
    COUNT(*) AS total_attempts, 
    SUM(payment_status = 'FAILED') AS failed_count,
    ROUND(SUM(amount), 2) AS lost_revenue
FROM payments
GROUP BY DATE(payment_date), payment_method
HAVING failed_count > 0;

-- 3B. Low-stock alert report
SELECT product_id, sku, product_name, stock_quantity, reorder_level
FROM products
WHERE stock_quantity <= reorder_level;


-- 4. Speed up order search query using index
EXPLAIN QUERY PLAN
SELECT * FROM orders WHERE customer_id = 12 ORDER BY order_date DESC;

CREATE INDEX IF NOT EXISTS idx_orders_customer_date ON orders(customer_id, order_date DESC);

EXPLAIN QUERY PLAN
SELECT * FROM orders WHERE customer_id = 12 ORDER BY order_date DESC;


-- 5. Clean up orphan records
BEGIN TRANSACTION;
INSERT OR IGNORE INTO customers (customer_id, first_name, last_name, email)
VALUES (9999, 'System', 'Archive', 'archive@system.local');

UPDATE orders SET customer_id = 9999 WHERE customer_id NOT IN (SELECT customer_id FROM customers);
DELETE FROM order_items WHERE order_id NOT IN (SELECT order_id FROM orders);
DELETE FROM order_items WHERE product_id NOT IN (SELECT product_id FROM products);
DELETE FROM payments WHERE order_id NOT IN (SELECT order_id FROM orders);
COMMIT;


-- 6. Reconcile order total discrepancies with item sums
BEGIN TRANSACTION;
UPDATE orders
SET total_amount = (
    SELECT ROUND(SUM(subtotal), 2) 
    FROM order_items 
    WHERE order_items.order_id = orders.order_id
)
WHERE order_id IN (
    SELECT o.order_id 
    FROM orders o 
    JOIN order_items oi ON o.order_id = oi.order_id 
    GROUP BY o.order_id 
    HAVING ABS(o.total_amount - SUM(oi.subtotal)) > 0.01
);
COMMIT;


-- 7. Oversold inventory FIFO queue
SELECT 
    o.order_id, 
    o.customer_id, 
    o.order_date, 
    p.sku, 
    oi.quantity,
    SUM(oi.quantity) OVER (PARTITION BY oi.product_id ORDER BY o.order_date) AS running_demand
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
WHERE o.status IN ('PENDING', 'PROCESSING') AND p.stock_quantity = 0
ORDER BY p.sku, o.order_date;


-- 8. Refund duplicate payment charges
BEGIN TRANSACTION;
UPDATE payments
SET payment_status = 'REFUNDED'
WHERE payment_id IN (
    SELECT payment_id 
    FROM (
        SELECT payment_id, ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY payment_date) AS seq
        FROM payments 
        WHERE payment_status = 'PAID'
    ) 
    WHERE seq > 1
);
COMMIT;


-- 9. Cancel stale unpaid pending orders older than 48 hours
BEGIN TRANSACTION;
UPDATE orders
SET status = 'CANCELLED'
WHERE status = 'PENDING'
  AND order_date < '2026-04-14'
  AND order_id NOT IN (SELECT order_id FROM payments WHERE payment_status = 'PAID');
COMMIT;


-- 10. Customer Lifetime Value (CLV) tiers
CREATE VIEW IF NOT EXISTS vw_customer_tiers AS
SELECT 
    c.customer_id, 
    c.first_name, 
    c.email,
    COUNT(o.order_id) AS total_orders,
    COALESCE(SUM(o.total_amount), 0) AS total_spent,
    CASE 
        WHEN SUM(o.total_amount) >= 1000 THEN 'PLATINUM'
        WHEN SUM(o.total_amount) >= 500  THEN 'GOLD'
        WHEN SUM(o.total_amount) >= 200  THEN 'SILVER'
        ELSE 'BRONZE'
    END AS tier
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id AND o.status != 'CANCELLED'
GROUP BY c.customer_id, c.first_name, c.email;
