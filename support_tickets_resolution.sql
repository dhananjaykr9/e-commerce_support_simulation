-- ============================================================================
-- SUPPORT TICKETS RESOLUTION (PURE SQL)
-- ============================================================================

-- 1. Deduplicate customers: merge orders to primary account and delete duplicates
BEGIN TRANSACTION;
UPDATE orders 
SET customer_id = (
    SELECT MIN(c2.customer_id) 
    FROM customers c2 
    WHERE c2.email = (SELECT c1.email FROM customers c1 WHERE c1.customer_id = orders.customer_id)
)
WHERE customer_id NOT IN (SELECT MIN(customer_id) FROM customers GROUP BY email);

DELETE FROM customers 
WHERE customer_id NOT IN (SELECT MIN(customer_id) FROM customers GROUP BY email);

CREATE UNIQUE INDEX IF NOT EXISTS idx_customers_email ON customers(email);
COMMIT;


-- 2. Reconcile stuck orders: advance paid orders from PENDING to PROCESSING
UPDATE orders 
SET status = 'PROCESSING'
WHERE status = 'PENDING' 
  AND order_id IN (SELECT order_id FROM payments WHERE payment_status = 'PAID');


-- 3A. Daily failed-payment report
SELECT payment_date, payment_method, COUNT(*) AS failed_count, ROUND(SUM(amount), 2) AS lost_revenue
FROM payments
WHERE payment_status = 'FAILED'
GROUP BY payment_date, payment_method;

-- 3B. Low-stock alert report
SELECT product_id, sku, name, stock_quantity
FROM products
WHERE stock_quantity <= 5;


-- 4. Speed up slow order-history query with an index
EXPLAIN QUERY PLAN
SELECT * FROM orders WHERE customer_id = 10 ORDER BY order_date DESC;

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id, order_date DESC);

EXPLAIN QUERY PLAN
SELECT * FROM orders WHERE customer_id = 10 ORDER BY order_date DESC;


-- 5. Clean up orphan records with missing parent keys
DELETE FROM orders WHERE customer_id NOT IN (SELECT customer_id FROM customers);
DELETE FROM order_items WHERE order_id NOT IN (SELECT order_id FROM orders);
DELETE FROM payments WHERE order_id NOT IN (SELECT order_id FROM orders);


-- 6. Reconcile order total discrepancies with actual item sums
UPDATE orders
SET total_amount = (
    SELECT ROUND(SUM(quantity * unit_price), 2)
    FROM order_items 
    WHERE order_items.order_id = orders.order_id
)
WHERE order_id IN (
    SELECT o.order_id 
    FROM orders o 
    JOIN order_items oi ON o.order_id = oi.order_id 
    GROUP BY o.order_id 
    HAVING ABS(o.total_amount - SUM(oi.quantity * oi.unit_price)) > 0.01
);


-- 7. Identify orders affected by oversold (out-of-stock) inventory
SELECT o.order_id, o.customer_id, p.name AS product_name, oi.quantity
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
WHERE p.stock_quantity = 0;


-- 8. Refund duplicate payment charges on the same order
UPDATE payments
SET payment_status = 'REFUNDED'
WHERE payment_id NOT IN (
    SELECT MIN(payment_id) 
    FROM payments 
    WHERE payment_status = 'PAID' 
    GROUP BY order_id
)
AND payment_status = 'PAID';


-- 9. Cancel stale unpaid orders
UPDATE orders
SET status = 'CANCELLED'
WHERE status = 'PENDING'
  AND order_id NOT IN (SELECT order_id FROM payments WHERE payment_status = 'PAID');


-- 10. Customer Lifetime Value (CLV) support tiers
CREATE VIEW IF NOT EXISTS vw_customer_tiers AS
SELECT 
    c.customer_id, 
    c.name, 
    c.email,
    COUNT(o.order_id) AS total_orders,
    COALESCE(SUM(o.total_amount), 0) AS total_spent,
    CASE 
        WHEN SUM(o.total_amount) >= 500 THEN 'VIP'
        ELSE 'STANDARD'
    END AS tier
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id AND o.status != 'CANCELLED'
GROUP BY c.customer_id, c.name, c.email;
