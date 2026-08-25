/* ============================================================================
   OLIST - SCHEMA AND LOAD REFERENCE
   Run nothing here. This file documents the expected raw layer and provides
   the checks that must pass before any view is created.
   See data/README.md for load instructions and source-file defects.
   ============================================================================ */

/* ---- Expected raw tables in dataset `olist` -------------------------------
   orders                        99,441
   customers                     99,441
   order_items                  112,650
   order_payments               103,886
   order_reviews                 99,224
   products                      32,951
   sellers                        3,095
   geolocation                1,000,163
   product_category_translation      71
   --------------------------------------------------------------------------- */

/* ---- CHECK 1  Row counts ---- */
SELECT 'orders' AS tbl, COUNT(*) AS n FROM `olist.orders` UNION ALL
SELECT 'customers',      COUNT(*) FROM `olist.customers` UNION ALL
SELECT 'order_items',    COUNT(*) FROM `olist.order_items` UNION ALL
SELECT 'order_payments', COUNT(*) FROM `olist.order_payments` UNION ALL
SELECT 'order_reviews',  COUNT(*) FROM `olist.order_reviews` UNION ALL
SELECT 'products',       COUNT(*) FROM `olist.products` UNION ALL
SELECT 'sellers',        COUNT(*) FROM `olist.sellers` UNION ALL
SELECT 'geolocation',    COUNT(*) FROM `olist.geolocation` UNION ALL
SELECT 'product_category_translation', COUNT(*) FROM `olist.product_category_translation`
ORDER BY tbl;
/* A table off by exactly +1 has its header row sitting in the data. */

/* ---- CHECK 2  Header-row failure: generic column names ---- */
SELECT table_name, column_name, ordinal_position
FROM `olist.INFORMATION_SCHEMA.COLUMNS`
WHERE column_name LIKE 'string_field_%'
   OR column_name LIKE 'int64_field_%'
   OR column_name LIKE 'float64_field_%'
ORDER BY table_name, ordinal_position;
/* Empty result = every table loaded with a proper header. */

/* ---- CHECK 3  The customer identifier trap ----
   customer_id is unique per ORDER; customer_unique_id identifies the PERSON.
   Expect 99,441 vs 96,096. Keying customer analysis on customer_id reports a
   repeat rate of exactly 0.00%. */
SELECT
  COUNT(*)                            AS rows,
  COUNT(DISTINCT customer_id)         AS order_keys,
  COUNT(DISTINCT customer_unique_id)  AS people
FROM `olist.customers`;

/* ---- CHECK 4  Geolocation fan-out risk ----
   ~52.6 rows per zip prefix. Joining raw multiplies the order table ~50x.
   Always join through v_geo_dedup. */
SELECT
  COUNT(*)                                        AS rows,
  COUNT(DISTINCT geolocation_zip_code_prefix)     AS zip_prefixes,
  ROUND(COUNT(*) / COUNT(DISTINCT geolocation_zip_code_prefix), 1) AS rows_per_zip
FROM `olist.geolocation`;

/* ---- CHECK 5  Duplicate reviews and split payments ----
   Expect 547 orders with >1 review, 2,961 with >1 payment line. Both are
   deduplicated / rolled up in the cleaning layer. */
SELECT
  (SELECT COUNT(*) FROM (SELECT order_id FROM `olist.order_reviews`
     GROUP BY order_id HAVING COUNT(*) > 1)) AS orders_multi_review,
  (SELECT COUNT(*) FROM (SELECT order_id FROM `olist.order_payments`
     GROUP BY order_id HAVING COUNT(*) > 1)) AS orders_multi_payment;

/* ---- CHECK 6  Date range ----
   Expect 2016-09-04 .. 2018-10-17. The dataset end date drives every
   censoring calculation in v_customer_order_seq. */
SELECT
  MIN(DATE(SAFE_CAST(order_purchase_timestamp AS TIMESTAMP))) AS first_order,
  MAX(DATE(SAFE_CAST(order_purchase_timestamp AS TIMESTAMP))) AS last_order
FROM `olist.orders`;
