/* ============================================================================
   OLIST E-COMMERCE — PHASE 2b SQL  (BigQuery Standard SQL)
   Chapters: 3 (geography) · 5 (categories) · 7 (delivery/freight) · 8 (sellers)
             · 10 (the causal-chain synthesis)
   ----------------------------------------------------------------------------
   DEPENDS ON: Phase-1 and Phase-2a views.
   NEW TABLES: order_items, geolocation.

   *** THE #1 TRAP IN THIS PHASE ***
   geolocation has 1,000,163 rows but only 19,015 unique zip prefixes
   (~52.6 rows each). Joining it RAW will fan out your order table ~50x.
   ALWAYS join via v_geo_dedup below.

   *** GMV DEFINITIONS — keep these straight ***
   - item price GMV   = SUM(price)                    <- product revenue only
   - freight          = SUM(freight_value)            <- shipping charged
   - payment GMV      = SUM(payment_value)            <- total paid (incl freight)
   775 orders exist with NO items (canceled/unavailable), so item-GMV and
   payment-GMV will not reconcile exactly. Say so in the report.
   ============================================================================ */


/* ############################################################################
   CHAPTER 0 (Phase 2b) — cleaning VIEWs
   ############################################################################ */

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



/* ############################################################################
   CHAPTER 3 — GEOGRAPHY: the supply/demand imbalance
   ############################################################################ */

/* ---- 3.1  Supply vs demand by state (the premise, quantified) --------------
   VERIFIED: sellers 59.7% SP vs customers 42.0% SP.
   Frame it precisely: 58% of DEMAND is outside SP, but only 40% of SUPPLY is. */
WITH cust AS (
  SELECT customer_state AS state, COUNT(DISTINCT customer_unique_id) AS customers
  FROM `olist.v_orders_enriched` GROUP BY state
),
sell AS (
  SELECT UPPER(TRIM(seller_state)) AS state, COUNT(*) AS sellers
  FROM `olist.sellers` GROUP BY state
)
SELECT
  COALESCE(c.state, s.state) AS state,
  IFNULL(c.customers, 0)     AS customers,
  IFNULL(s.sellers, 0)       AS sellers,
  ROUND(100.0 * IFNULL(c.customers,0) / SUM(IFNULL(c.customers,0)) OVER (), 2) AS pct_demand,
  ROUND(100.0 * IFNULL(s.sellers,0)   / SUM(IFNULL(s.sellers,0))   OVER (), 2) AS pct_supply
FROM cust c FULL OUTER JOIN sell s ON c.state = s.state
ORDER BY customers DESC;


/* ---- 3.2  Interstate shipping share ---------------------------------------- */
SELECT
  is_interstate,
  COUNT(*)                          AS items,
  ROUND(AVG(distance_km), 1)        AS avg_distance_km,
  ROUND(AVG(freight_value), 2)      AS avg_freight,
  ROUND(AVG(delivery_days), 1)      AS avg_delivery_days,
  ROUND(AVG(review_score), 3)       AS avg_review_score
FROM `olist.v_fact_order_items`
WHERE order_status = 'delivered'
GROUP BY is_interstate;


/* ---- 3.3  State-level delivery & satisfaction ------------------------------ */
SELECT
  customer_state,
  COUNT(*)                                                AS items,
  ROUND(AVG(distance_km), 0)                              AS avg_distance_km,
  ROUND(AVG(delivery_days), 1)                            AS avg_delivery_days,
  ROUND(AVG(freight_value), 2)                            AS avg_freight,
  ROUND(100.0 * AVG(freight_value / NULLIF(price,0)), 1)  AS freight_pct_of_price,
  ROUND(AVG(review_score), 3)                             AS avg_review_score,
  ROUND(100.0 * COUNTIF(lateness_days > 0) / COUNT(*), 1) AS pct_late
FROM `olist.v_fact_order_items`
WHERE order_status = 'delivered'
GROUP BY customer_state
ORDER BY items DESC;



/* ############################################################################
   CHAPTER 5 — CATEGORIES (now sales-linked)
   ############################################################################ */

/* ---- 5.3  Category performance: the Pareto -------------------------------- */
SELECT
  category,
  COUNT(DISTINCT order_id)                    AS orders,
  COUNT(*)                                    AS items,
  ROUND(SUM(price), 2)                        AS revenue,
  ROUND(AVG(price), 2)                        AS avg_item_price,
  ROUND(AVG(freight_value), 2)                AS avg_freight,
  ROUND(AVG(review_score), 3)                 AS avg_review_score,
  ROUND(AVG(delivery_days), 1)                AS avg_delivery_days,
  ROUND(100.0 * SUM(SUM(price)) OVER (ORDER BY SUM(price) DESC)
        / SUM(SUM(price)) OVER (), 1)         AS cumulative_revenue_pct
FROM `olist.v_fact_order_items`
GROUP BY category
ORDER BY revenue DESC;


/* ---- 5.4  Does listing quality pay off? (photos -> price / review) ---------
   The payoff query Phase 2a couldn't run. Look for: more photos -> higher
   review score / price. Correlation, NOT causation — say so. */
SELECT
  photos_qty,
  COUNT(*)                    AS items,
  ROUND(AVG(price), 2)        AS avg_price,
  ROUND(AVG(review_score), 3) AS avg_review_score
FROM `olist.v_fact_order_items`
WHERE photos_qty IS NOT NULL
GROUP BY photos_qty
ORDER BY photos_qty;


/* ---- 5.5  STRUCTURAL vs FAILED retention (the smart-analyst split) ---------
   Do one-and-done categories (furniture, mattresses) explain low repeat, or
   is it satisfaction? Compares each category's repeat rate to its review score.
   Low repeat + HIGH score = structural. Low repeat + LOW score = failure. */
WITH cust_cat AS (
  SELECT DISTINCT customer_unique_id, category
  FROM `olist.v_fact_order_items`
  WHERE category IS NOT NULL
),
cust_orders AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS n_orders
  FROM `olist.v_orders_enriched` GROUP BY customer_unique_id
)
SELECT
  cc.category,
  COUNT(*)                                              AS customers,
  ROUND(100.0 * COUNTIF(co.n_orders > 1) / COUNT(*), 2) AS repeat_rate_pct,
  ROUND((SELECT AVG(review_score) FROM `olist.v_fact_order_items` f
         WHERE f.category = cc.category), 3)            AS avg_review_score
FROM cust_cat cc
JOIN cust_orders co USING (customer_unique_id)
GROUP BY cc.category
HAVING customers >= 200
ORDER BY repeat_rate_pct DESC;



/* ############################################################################
   CHAPTER 7 — DELIVERY, FREIGHT & UNIT ECONOMICS
   ############################################################################ */

/* ---- 7.1  Delay decomposition: WHERE does the time go? ---------------------
   Splits purchase->delivered into three legs. Tells you if the fix is a
   SELLER problem (slow to hand over) or a CARRIER problem. */
SELECT
  ROUND(AVG(DATE_DIFF(DATE(approved_ts),  DATE(purchase_ts),  DAY)), 2) AS avg_days_to_approve,
  ROUND(AVG(DATE_DIFF(DATE(carrier_ts),   DATE(approved_ts),  DAY)), 2) AS avg_days_seller_to_carrier,
  ROUND(AVG(DATE_DIFF(DATE(delivered_ts), DATE(carrier_ts),   DAY)), 2) AS avg_days_carrier_to_customer,
  ROUND(AVG(DATE_DIFF(DATE(delivered_ts), DATE(purchase_ts),  DAY)), 2) AS avg_total_days
FROM `olist.v_orders_enriched`
WHERE order_status = 'delivered'
  AND approved_ts IS NOT NULL AND carrier_ts IS NOT NULL AND delivered_ts IS NOT NULL;


/* ---- 7.2  Distance -> delivery time & freight ------------------------------ */
SELECT
  CASE
    WHEN distance_km <   50 THEN '0-50 km'
    WHEN distance_km <  200 THEN '50-200 km'
    WHEN distance_km <  500 THEN '200-500 km'
    WHEN distance_km < 1000 THEN '500-1000 km'
    ELSE '1000+ km'
  END AS distance_bucket,
  COUNT(*)                     AS items,
  ROUND(AVG(delivery_days), 1) AS avg_delivery_days,
  ROUND(AVG(freight_value), 2) AS avg_freight,
  ROUND(AVG(review_score), 3)  AS avg_review_score
FROM `olist.v_fact_order_items`
WHERE order_status = 'delivered' AND distance_km IS NOT NULL
GROUP BY distance_bucket
ORDER BY MIN(distance_km);


/* ---- 7.3  Freight economics: when is fulfilment uneconomic? ----------------
   Freight as a share of item price, bucketed by price band. Cheap+heavy items
   are where the marketplace bleeds. */
SELECT
  CASE
    WHEN price <  30 THEN 'R$0-30'
    WHEN price <  60 THEN 'R$30-60'
    WHEN price < 120 THEN 'R$60-120'
    WHEN price < 300 THEN 'R$120-300'
    ELSE 'R$300+'
  END AS price_band,
  COUNT(*)                                               AS items,
  ROUND(AVG(price), 2)                                   AS avg_price,
  ROUND(AVG(freight_value), 2)                           AS avg_freight,
  ROUND(100.0 * AVG(freight_value / NULLIF(price, 0)),1) AS freight_pct_of_price,
  ROUND(AVG(weight_g), 0)                                AS avg_weight_g
FROM `olist.v_fact_order_items`
GROUP BY price_band
ORDER BY MIN(price);



/* ############################################################################
   CHAPTER 8 — SELLERS: the supply side
   ############################################################################ */

/* ---- 8.1  Seller Pareto ---------------------------------------------------- */
WITH s AS (
  SELECT seller_id, SUM(price) AS revenue, COUNT(*) AS items
  FROM `olist.v_fact_order_items` GROUP BY seller_id
),
r AS (
  SELECT seller_id, revenue, items,
         ROW_NUMBER() OVER (ORDER BY revenue DESC) AS rank,
         SUM(revenue) OVER (ORDER BY revenue DESC) AS cum_revenue,
         SUM(revenue) OVER ()                      AS total_revenue,
         COUNT(*)     OVER ()                      AS total_sellers
  FROM s
)
SELECT rank, seller_id, ROUND(revenue,2) AS revenue, items,
       ROUND(100.0 * rank / total_sellers, 2)         AS pct_of_sellers,
       ROUND(100.0 * cum_revenue / total_revenue, 2)  AS cum_pct_of_revenue
FROM r
ORDER BY rank
LIMIT 100;


/* ---- 8.2  Seller quality tiers: do big sellers deliver good experiences? ---
   The marketplace-risk query. If top-GMV sellers have weak reviews, that's a
   concentration risk worth flagging to the business. */
WITH s AS (
  SELECT
    seller_id, seller_state,
    COUNT(*)                AS items,
    SUM(price)              AS revenue,
    AVG(review_score)       AS avg_score,
    AVG(delivery_days)      AS avg_delivery_days,
    AVG(IF(lateness_days > 0, 1, 0)) AS late_rate
  FROM `olist.v_fact_order_items`
  WHERE order_status = 'delivered'
  GROUP BY seller_id, seller_state
  HAVING items >= 20
)
SELECT
  NTILE(4) OVER (ORDER BY revenue DESC)   AS revenue_quartile,
  COUNT(*)                                AS sellers,
  ROUND(SUM(revenue), 2)                  AS total_revenue,
  ROUND(AVG(avg_score), 3)                AS avg_review_score,
  ROUND(AVG(avg_delivery_days), 1)        AS avg_delivery_days,
  ROUND(100.0 * AVG(late_rate), 1)        AS pct_late
FROM s
GROUP BY revenue_quartile
ORDER BY revenue_quartile;


/* ---- 8.3  Worst offenders: high-volume sellers with poor experience -------- */
SELECT
  seller_id, seller_state,
  COUNT(*)                                                AS items,
  ROUND(SUM(price), 2)                                    AS revenue,
  ROUND(AVG(review_score), 2)                             AS avg_score,
  ROUND(100.0 * COUNTIF(lateness_days > 0) / COUNT(*), 1) AS pct_late
FROM `olist.v_fact_order_items`
WHERE order_status = 'delivered'
GROUP BY seller_id, seller_state
HAVING items >= 50 AND avg_score < 3.5
ORDER BY revenue DESC
LIMIT 25;



/* ############################################################################
   CHAPTER 10 — SYNTHESIS: the causal chain, end to end
   ############################################################################ */

/* ---- 10.1  THE CHAIN IN ONE TABLE ------------------------------------------
   distance -> delivery days -> lateness -> review score -> repeat rate.
   This single query is the spine of the LaTeX report. If repeat_rate falls
   monotonically with distance, the whole argument closes. */
WITH item_level AS (
  SELECT
    customer_unique_id, order_id, distance_km, delivery_days,
    lateness_days, review_score
  FROM `olist.v_fact_order_items`
  WHERE order_status = 'delivered' AND distance_km IS NOT NULL
),
order_level AS (
  SELECT customer_unique_id, order_id,
         AVG(distance_km)   AS distance_km,
         AVG(delivery_days) AS delivery_days,
         AVG(lateness_days) AS lateness_days,
         AVG(review_score)  AS review_score
  FROM item_level GROUP BY customer_unique_id, order_id
),
cust_orders AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS n_orders
  FROM `olist.v_orders_enriched` GROUP BY customer_unique_id
)
SELECT
  CASE
    WHEN o.distance_km <  200 THEN '0-200 km'
    WHEN o.distance_km <  500 THEN '200-500 km'
    WHEN o.distance_km < 1000 THEN '500-1000 km'
    ELSE '1000+ km'
  END AS distance_bucket,
  COUNT(*)                                                 AS orders,
  ROUND(AVG(o.delivery_days), 1)                           AS avg_delivery_days,
  ROUND(100.0 * AVG(IF(o.lateness_days > 0, 1, 0)), 1)     AS pct_late,
  ROUND(AVG(o.review_score), 3)                            AS avg_review_score,
  ROUND(100.0 * COUNTIF(c.n_orders > 1) / COUNT(*), 2)     AS repeat_rate_pct
FROM order_level o
JOIN cust_orders c USING (customer_unique_id)
GROUP BY distance_bucket
ORDER BY MIN(o.distance_km);


/* ---- 10.2  First-order experience -> did they ever come back? --------------
   The money question: does a bad FIRST impression kill the relationship?
   Isolates each customer's first order, then checks if they returned. */
WITH first_order AS (
  SELECT customer_unique_id, order_id, purchase_ts,
         ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS seq
  FROM `olist.v_orders_enriched`
),
fo AS ( SELECT * FROM first_order WHERE seq = 1 ),
totals AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS n_orders
  FROM `olist.v_orders_enriched` GROUP BY customer_unique_id
),
enriched AS (
  SELECT
    fo.customer_unique_id,
    r.review_score,
    DATE_DIFF(DATE(e.delivered_ts), DATE(e.estimated_ts), DAY) AS lateness_days,
    t.n_orders
  FROM fo
  JOIN `olist.v_orders_enriched` e ON fo.order_id = e.order_id
  JOIN totals t USING (customer_unique_id)
  LEFT JOIN `olist.v_reviews_clean` r ON fo.order_id = r.order_id
  WHERE e.order_status = 'delivered' AND e.delivered_ts IS NOT NULL
)
SELECT
  review_score AS first_order_review_score,
  COUNT(*)                                              AS customers,
  ROUND(AVG(lateness_days), 1)                          AS avg_lateness_days,
  COUNTIF(n_orders > 1)                                 AS returned,
  ROUND(100.0 * COUNTIF(n_orders > 1) / COUNT(*), 2)    AS return_rate_pct
FROM enriched
WHERE review_score IS NOT NULL
GROUP BY review_score
ORDER BY review_score;


/* ---- 10.3  Ranked fix list: worst state x category cells -------------------
   The actionable output. Revenue-weighted so fixes are prioritised by
   business impact, not just by badness. */
SELECT
  customer_state,
  category,
  COUNT(*)                                                AS items,
  ROUND(SUM(price), 2)                                    AS revenue_at_risk,
  ROUND(AVG(delivery_days), 1)                            AS avg_delivery_days,
  ROUND(100.0 * COUNTIF(lateness_days > 0) / COUNT(*), 1) AS pct_late,
  ROUND(AVG(review_score), 2)                             AS avg_score
FROM `olist.v_fact_order_items`
WHERE order_status = 'delivered' AND category IS NOT NULL
GROUP BY customer_state, category
HAVING items >= 100 AND avg_score < 3.8
ORDER BY revenue_at_risk DESC
LIMIT 30;

/* ============================================================================
   END PHASE 2b — all 9 tables now in play.
   Remaining tracks: (1) Colab NLP on ~41K Portuguese review texts
                     (2) Power BI build off v_fact_order_items
                     (3) LaTeX report writing
   ============================================================================ */
