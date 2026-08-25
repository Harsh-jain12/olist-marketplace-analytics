/* ============================================================================
   OLIST - CLEANING VIEW LAYER  (BigQuery Standard SQL)

   Run once, after loading the nine raw tables. Order matters:
     v_orders_clean, v_customers_clean  ->  v_orders_enriched
     v_geo_dedup, v_products_clean, v_order_items_clean -> v_fact_order_items

   Replace `olist` with your project.dataset.
   ============================================================================ */

/* ---- 0.1  Clean orders: parse timestamps, keep status ---------------------
   Logic: SAFE_CAST all five timestamps to TIMESTAMP. Drop rows with no
   purchase timestamp (unusable). We do NOT trim the date range here — that's a
   toggle applied only in the temporal chapter, so other analyses keep all rows. */
CREATE OR REPLACE VIEW `olist.v_orders_clean` AS
SELECT
  order_id,
  customer_id,
  order_status,
  SAFE_CAST(order_purchase_timestamp      AS TIMESTAMP) AS purchase_ts,
  SAFE_CAST(order_approved_at             AS TIMESTAMP) AS approved_ts,
  SAFE_CAST(order_delivered_carrier_date  AS TIMESTAMP) AS carrier_ts,
  SAFE_CAST(order_delivered_customer_date AS TIMESTAMP) AS delivered_ts,
  SAFE_CAST(order_estimated_delivery_date AS TIMESTAMP) AS estimated_ts
FROM `olist.orders`
WHERE order_purchase_timestamp IS NOT NULL;


/* ---- 0.2  Clean customers: normalise text, expose both identifiers -------- */
CREATE OR REPLACE VIEW `olist.v_customers_clean` AS
SELECT
  customer_id,                                   -- order-scoped key (unique per row)
  customer_unique_id,                            -- the actual PERSON (stable across orders)
  customer_zip_code_prefix,
  LOWER(TRIM(customer_city))  AS customer_city,
  UPPER(TRIM(customer_state)) AS customer_state
FROM `olist.customers`;


/* ---- 0.3  Enriched orders: the workhorse view -----------------------------
   Every downstream query uses THIS, so customer_unique_id + geography are
   always available. This is the fix for the identifier trap. */
CREATE OR REPLACE VIEW `olist.v_orders_enriched` AS
SELECT
  o.order_id,
  o.customer_id,
  c.customer_unique_id,
  o.order_status,
  o.purchase_ts,
  o.approved_ts,
  o.carrier_ts,
  o.delivered_ts,
  o.estimated_ts,
  c.customer_state,
  c.customer_city,
  c.customer_zip_code_prefix
FROM `olist.v_orders_clean` o
LEFT JOIN `olist.v_customers_clean` c USING (customer_id);


/* ---- P2.1  Payments rolled up to ONE row per order ------------------------
   order_payments has >1 row per order (split methods). We sum to an order
   total, count the lines, take max installments, and label the DOMINANT
   method (largest single line). */
CREATE OR REPLACE VIEW `olist.v_payments_order` AS
SELECT
  order_id,
  ROUND(SUM(payment_value), 2)                                          AS order_payment_total,
  COUNT(*)                                                              AS payment_lines,
  MAX(payment_installments)                                            AS max_installments,
  ARRAY_AGG(payment_type ORDER BY payment_value DESC LIMIT 1)[OFFSET(0)] AS primary_payment_type
FROM `olist.order_payments`
GROUP BY order_id;


/* ---- P2.2  Reviews deduped to ONE (latest) review per order ---------------
   Some orders carry >1 review; keep the most recent. has_text flags the ~41%
   with a free-text message (the NLP corpus). */
CREATE OR REPLACE VIEW `olist.v_reviews_clean` AS
WITH dedup AS (
  SELECT
    order_id, review_id, review_score, review_comment_message,
    SAFE_CAST(review_creation_date  AS TIMESTAMP) AS review_created_ts,
    SAFE_CAST(review_answer_timestamp AS TIMESTAMP) AS review_answered_ts,
    ROW_NUMBER() OVER (PARTITION BY order_id
                       ORDER BY SAFE_CAST(review_creation_date AS TIMESTAMP) DESC) AS rn
  FROM `olist.order_reviews`
)
SELECT
  order_id, review_id, review_score, review_comment_message,
  (review_comment_message IS NOT NULL) AS has_text,
  review_created_ts, review_answered_ts
FROM dedup
WHERE rn = 1;


/* ---- P2.3  Products cleaned + category translated -------------------------
   COALESCE handles the 610 null-category rows -> 'uncategorised'. Keeps the
   content-quality fields (photos, description length) and derives volume. */
CREATE OR REPLACE VIEW `olist.v_products_clean` AS
SELECT
  p.product_id,
  COALESCE(t.product_category_name_english, p.product_category_name, 'uncategorised') AS category,
  p.product_category_name                                     AS category_pt,
  p.product_name_lenght                                      AS name_length,
  p.product_description_lenght                               AS description_length,
  p.product_photos_qty                                       AS photos_qty,
  p.product_weight_g                                         AS weight_g,
  p.product_length_cm * p.product_height_cm * p.product_width_cm AS volume_cm3
FROM `olist.products` p
LEFT JOIN `olist.product_category_translation` t
  ON p.product_category_name = t.product_category_name;


/* ---- P3.1  Geolocation deduped to ONE point per zip prefix -----------------
   Median-style centroid via AVG. Guards against the ~50x fan-out. */
CREATE OR REPLACE VIEW `olist.v_geo_dedup` AS
SELECT
  geolocation_zip_code_prefix              AS zip_prefix,
  AVG(geolocation_lat)                     AS lat,
  AVG(geolocation_lng)                     AS lng,
  ANY_VALUE(UPPER(TRIM(geolocation_state))) AS state
FROM `olist.geolocation`
GROUP BY geolocation_zip_code_prefix;


/* ---- P3.2  Order items cleaned --------------------------------------------- */
CREATE OR REPLACE VIEW `olist.v_order_items_clean` AS
SELECT
  order_id,
  order_item_id,
  product_id,
  seller_id,
  SAFE_CAST(shipping_limit_date AS TIMESTAMP) AS shipping_limit_ts,
  price,
  freight_value
FROM `olist.order_items`;


/* ---- P3.3  Order-level item rollup ----------------------------------------- */
CREATE OR REPLACE VIEW `olist.v_order_value` AS
SELECT
  order_id,
  COUNT(*)                           AS n_items,
  COUNT(DISTINCT seller_id)          AS n_sellers,
  COUNT(DISTINCT product_id)         AS n_products,
  ROUND(SUM(price), 2)               AS item_revenue,
  ROUND(SUM(freight_value), 2)       AS freight_total,
  ROUND(SUM(price + freight_value),2) AS order_total
FROM `olist.v_order_items_clean`
GROUP BY order_id;


/* ---- P3.4  THE MASTER FACT VIEW — one row per order item, fully enriched ---
   This is the backbone for Power BI. Joins orders + customers + items +
   products + sellers + geo (both ends) + reviews + payments. */
CREATE OR REPLACE VIEW `olist.v_fact_order_items` AS
SELECT
  o.order_id, o.customer_unique_id, o.order_status,
  o.purchase_ts, o.delivered_ts, o.estimated_ts,
  DATE_DIFF(DATE(o.delivered_ts), DATE(o.purchase_ts),  DAY) AS delivery_days,
  DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) AS lateness_days,
  i.order_item_id, i.product_id, i.seller_id, i.price, i.freight_value,
  p.category, p.photos_qty, p.description_length, p.weight_g, p.volume_cm3,
  o.customer_state, s.seller_state,
  (o.customer_state != s.seller_state)                       AS is_interstate,
  cg.lat AS cust_lat, cg.lng AS cust_lng,
  sg.lat AS sell_lat, sg.lng AS sell_lng,
  ST_DISTANCE(ST_GEOGPOINT(sg.lng, sg.lat),
              ST_GEOGPOINT(cg.lng, cg.lat)) / 1000          AS distance_km,
  r.review_score
FROM `olist.v_orders_enriched`     o
JOIN `olist.v_order_items_clean`   i  USING (order_id)
LEFT JOIN `olist.v_products_clean` p  USING (product_id)
LEFT JOIN `olist.sellers`          s  USING (seller_id)
LEFT JOIN `olist.v_geo_dedup`      cg ON o.customer_zip_code_prefix = cg.zip_prefix
LEFT JOIN `olist.v_geo_dedup`      sg ON s.seller_zip_code_prefix   = sg.zip_prefix
LEFT JOIN `olist.v_reviews_clean`  r  USING (order_id);
