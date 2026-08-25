/* ============================================================================
   OLIST — BASE LAYER: v_fact_orders   (BigQuery Standard SQL)
   ----------------------------------------------------------------------------
   PURPOSE
   The existing v_fact_order_items is ITEM grain (112,650 rows). Using it for
   ORDER-level outcomes (review score, delivery days) makes a 6-item order
   contribute its single review score six times. That inflates n, understates
   standard errors, and silently weights multi-item orders.

   9.9% of orders are multi-item, so the distortion is material but not obvious.

   RULE FROM HERE ON
     - order-level outcomes (review, delivery, repeat) -> v_fact_orders
     - item economics (price, freight per item)        -> v_fact_order_items

   Replace `olist` with your project.dataset, e.g. `blinkit-analysis-503505.olist`.
   ============================================================================ */


/* ############################################################################
   STEP 1 — Item aggregates rolled up to ONE row per order
   ############################################################################ */

CREATE OR REPLACE VIEW `olist.v_order_items_agg` AS
SELECT
  order_id,

  /* ---- money (order totals) ---- */
  ROUND(SUM(price), 2)                    AS item_value,      -- GMV excl. freight
  ROUND(SUM(freight_value), 2)            AS freight_value,
  ROUND(SUM(price + freight_value), 2)    AS order_value,
  ROUND(AVG(price), 2)                    AS avg_item_price,

  /* ---- composition ---- */
  COUNT(*)                                AS n_items,
  COUNT(DISTINCT product_id)              AS n_products,
  COUNT(DISTINCT seller_id)               AS n_sellers,
  (COUNT(DISTINCT seller_id) > 1)         AS is_multi_seller,

  /* ---- DOMINANT category / seller = the one carrying the most value.
          Using ANY_VALUE() here would pick an arbitrary row; for a 1-item
          order the two agree, but for multi-item orders "dominant" is the
          defensible choice and is reproducible. ---- */
  ARRAY_AGG(category  IGNORE NULLS ORDER BY price DESC LIMIT 1)[SAFE_OFFSET(0)] AS category,
  ARRAY_AGG(seller_id IGNORE NULLS ORDER BY price DESC LIMIT 1)[SAFE_OFFSET(0)] AS seller_id,

  /* ---- physical ---- */
  ROUND(SUM(weight_g), 0)                 AS total_weight_g,
  ROUND(AVG(photos_qty), 2)               AS avg_photos_qty,

  /* ---- distance: MAX is the binding constraint on delivery time
          (the order is only complete when the furthest item arrives);
          MEAN kept for sensitivity checks ---- */
  ROUND(MAX(distance_km), 1)              AS max_distance_km,
  ROUND(AVG(distance_km), 1)              AS avg_distance_km

FROM `olist.v_fact_order_items`
GROUP BY order_id;


/* ############################################################################
   STEP 2 — Customer order sequence + censoring-aware repeat flags

   WHY THIS MATTERS
   A customer acquired in Oct 2018 had days to return; one acquired in
   Jan 2017 had ~21 months. Calling the raw 3.12% "retention" compares
   incomparable exposure windows.

   TREATMENT
     repeat_within_Nd = TRUE   -> next order observed within N days
                      = FALSE  -> N days of exposure elapsed, no repeat
                      = NULL   -> insufficient exposure (CENSORED, exclude)

   NULL is the important case: those rows must drop out of the denominator,
   not count as non-repeaters.

   Exposure coverage on this dataset (verified):
     30d  -> 100.0% of first orders usable
     60d  ->  98.5%
     90d  ->  90.5%
     180d ->  71.7%
   90 days is the recommended headline window: long enough to be meaningful,
   still retains 90% of the cohort.
   ############################################################################ */

CREATE OR REPLACE VIEW `olist.v_customer_order_seq` AS
WITH bounds AS (
  SELECT MAX(DATE(purchase_ts)) AS dataset_max_date
  FROM `olist.v_orders_enriched`
),
seq AS (
  SELECT
    order_id,
    customer_unique_id,
    purchase_ts,
    ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS order_seq,
    COUNT(*)    OVER (PARTITION BY customer_unique_id)                       AS lifetime_orders,
    LEAD(purchase_ts) OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS next_purchase_ts
  FROM `olist.v_orders_enriched`
)
SELECT
  s.order_id,
  s.customer_unique_id,
  s.order_seq,
  s.lifetime_orders,
  (s.order_seq = 1)                                                AS is_first_order,
  s.next_purchase_ts,
  DATE_DIFF(DATE(s.next_purchase_ts), DATE(s.purchase_ts), DAY)    AS days_to_next_order,
  DATE_DIFF(b.dataset_max_date, DATE(s.purchase_ts), DAY)          AS exposure_days,

  /* censoring-aware repeat indicators */
  CASE WHEN DATE_DIFF(DATE(s.next_purchase_ts), DATE(s.purchase_ts), DAY) <= 30 THEN TRUE
       WHEN DATE_DIFF(b.dataset_max_date, DATE(s.purchase_ts), DAY)        >= 30 THEN FALSE
       ELSE NULL END AS repeat_within_30d,

  CASE WHEN DATE_DIFF(DATE(s.next_purchase_ts), DATE(s.purchase_ts), DAY) <= 60 THEN TRUE
       WHEN DATE_DIFF(b.dataset_max_date, DATE(s.purchase_ts), DAY)        >= 60 THEN FALSE
       ELSE NULL END AS repeat_within_60d,

  CASE WHEN DATE_DIFF(DATE(s.next_purchase_ts), DATE(s.purchase_ts), DAY) <= 90 THEN TRUE
       WHEN DATE_DIFF(b.dataset_max_date, DATE(s.purchase_ts), DAY)        >= 90 THEN FALSE
       ELSE NULL END AS repeat_within_90d,

  CASE WHEN DATE_DIFF(DATE(s.next_purchase_ts), DATE(s.purchase_ts), DAY) <= 180 THEN TRUE
       WHEN DATE_DIFF(b.dataset_max_date, DATE(s.purchase_ts), DAY)        >= 180 THEN FALSE
       ELSE NULL END AS repeat_within_180d,

  /* uncensored ever-repeat, kept ONLY for backwards comparison with the
     old 3.12% figure. Do not report this as "retention". */
  (s.lifetime_orders > 1)                                          AS ever_repeated

FROM seq s
CROSS JOIN bounds b;


/* ############################################################################
   STEP 3 — THE BASE LAYER: one row per order
   ############################################################################ */

CREATE OR REPLACE VIEW `olist.v_fact_orders` AS
SELECT
  /* ---------- keys ---------- */
  o.order_id,
  o.customer_unique_id,
  i.seller_id                              AS dominant_seller_id,

  /* ---------- status & time ---------- */
  o.order_status,
  o.purchase_ts,
  DATE(o.purchase_ts)                      AS purchase_date,
  DATE_TRUNC(DATE(o.purchase_ts), MONTH)   AS purchase_month,
  o.approved_ts,
  o.carrier_ts,
  o.delivered_ts,
  o.estimated_ts,

  /* ---------- delivery outcomes (ORDER grain) ---------- */
  DATE_DIFF(DATE(o.delivered_ts), DATE(o.purchase_ts),  DAY) AS delivery_days,
  DATE_DIFF(DATE(o.estimated_ts), DATE(o.purchase_ts),  DAY) AS promised_days,
  DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) AS lateness_days,

  /* pipeline legs — locates WHERE time is spent */
  DATE_DIFF(DATE(o.approved_ts),  DATE(o.purchase_ts), DAY)  AS days_to_approve,
  DATE_DIFF(DATE(o.carrier_ts),   DATE(o.approved_ts), DAY)  AS days_seller_to_carrier,
  DATE_DIFF(DATE(o.delivered_ts), DATE(o.carrier_ts),  DAY)  AS days_carrier_to_customer,

  /* lateness derivatives.
     CAVEAT: "late" is measured against Olist's OWN promised date, which is
     heavily padded — 92% of orders arrive early, median ~12 days early.
     So late_flag = 1 means the order blew through a generous buffer, and is
     likely a pathological fulfilment event (lost/damaged/stuck), not merely
     a slow one. Say this out loud in the report. */
  IF(DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) > 0, 1, 0) AS late_flag,
  GREATEST(DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY), 0)  AS days_late_pos,
  GREATEST(DATE_DIFF(DATE(o.estimated_ts), DATE(o.delivered_ts), DAY), 0)  AS days_early_pos,

  CASE
    WHEN o.delivered_ts IS NULL THEN NULL
    WHEN DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) <= -1 THEN 'Early'
    WHEN DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) =   0 THEN 'On time'
    WHEN DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) <=  3 THEN '1-3d late'
    WHEN DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) <=  7 THEN '4-7d late'
    ELSE '8d+ late'
  END AS lateness_band,

  /* ---------- basket ---------- */
  i.item_value, i.freight_value, i.order_value, i.avg_item_price,
  i.n_items, i.n_products, i.n_sellers, i.is_multi_seller,
  i.category, i.total_weight_g, i.avg_photos_qty,
  SAFE_DIVIDE(i.freight_value, i.item_value) AS freight_to_value_ratio,

  /* ---------- geography ---------- */
  o.customer_state,
  o.customer_city,
  s.seller_state                           AS dominant_seller_state,
  (o.customer_state != s.seller_state)     AS is_interstate,
  i.max_distance_km,
  i.avg_distance_km,

  /* ---------- payment ---------- */
  p.order_payment_total,
  p.primary_payment_type,
  p.max_installments,

  /* ---------- experience (ORDER grain — one review per order) ---------- */
  r.review_score,
  IF(r.review_score <= 2, 1, 0)            AS poor_review,
  IF(r.review_score >= 4, 1, 0)            AS good_review,
  r.has_text                               AS review_has_text,

  /* ---------- lifecycle & censoring ---------- */
  q.order_seq,
  q.lifetime_orders,
  q.is_first_order,
  q.days_to_next_order,
  q.exposure_days,
  q.repeat_within_30d,
  q.repeat_within_60d,
  q.repeat_within_90d,
  q.repeat_within_180d,
  q.ever_repeated

FROM `olist.v_orders_enriched`      o
JOIN `olist.v_order_items_agg`      i USING (order_id)     -- INNER: drops the 775 order-less orders
LEFT JOIN `olist.sellers`           s ON i.seller_id = s.seller_id
LEFT JOIN `olist.v_payments_order`  p ON o.order_id  = p.order_id
LEFT JOIN `olist.v_reviews_clean`   r ON o.order_id  = r.order_id
LEFT JOIN `olist.v_customer_order_seq` q ON o.order_id = q.order_id;


/* ############################################################################
   STEP 4 — VALIDATION.  Run these before trusting anything downstream.
   Expected values are from the raw CSVs and should match within rounding.
   ############################################################################ */

/* ---- V1  Grain check: must be exactly one row per order ---- */
SELECT
  COUNT(*)                  AS rows,               -- expect 98,666
  COUNT(DISTINCT order_id)  AS distinct_orders,    -- expect 98,666  (MUST equal rows)
  COUNTIF(order_status = 'delivered') AS delivered -- expect 96,478
FROM `olist.v_fact_orders`;


/* ---- V2  No fan-out vs the item layer ---- */
SELECT
  (SELECT COUNT(*) FROM `olist.v_fact_order_items`) AS item_rows,   -- expect 112,650
  (SELECT COUNT(*) FROM `olist.v_fact_orders`)      AS order_rows,  -- expect  98,666
  (SELECT COUNTIF(n_items > 1) FROM `olist.v_fact_orders`) AS multi_item_orders; -- expect 9,803


/* ---- V3  Null audit on the modelling columns ---- */
SELECT
  COUNTIF(review_score    IS NULL) AS no_review,
  COUNTIF(delivery_days   IS NULL) AS no_delivery_date,
  COUNTIF(max_distance_km IS NULL) AS no_distance,
  COUNTIF(category        IS NULL) AS no_category,
  COUNTIF(order_payment_total IS NULL) AS no_payment
FROM `olist.v_fact_orders`
WHERE order_status = 'delivered';


/* ---- V4  Censoring: how much of each window is usable? ----
   Expected on first orders: 30d 100.0% | 60d 98.5% | 90d 90.5% | 180d 71.7% */
SELECT
  '30d'  AS window, COUNTIF(repeat_within_30d  IS NOT NULL) AS usable,
  COUNT(*) AS total_first_orders,
  ROUND(100*COUNTIF(repeat_within_30d IS NOT NULL)/COUNT(*),1) AS pct_usable
FROM `olist.v_fact_orders` WHERE is_first_order
UNION ALL SELECT '60d',  COUNTIF(repeat_within_60d  IS NOT NULL), COUNT(*),
  ROUND(100*COUNTIF(repeat_within_60d IS NOT NULL)/COUNT(*),1)
FROM `olist.v_fact_orders` WHERE is_first_order
UNION ALL SELECT '90d',  COUNTIF(repeat_within_90d  IS NOT NULL), COUNT(*),
  ROUND(100*COUNTIF(repeat_within_90d IS NOT NULL)/COUNT(*),1)
FROM `olist.v_fact_orders` WHERE is_first_order
UNION ALL SELECT '180d', COUNTIF(repeat_within_180d IS NOT NULL), COUNT(*),
  ROUND(100*COUNTIF(repeat_within_180d IS NOT NULL)/COUNT(*),1)
FROM `olist.v_fact_orders` WHERE is_first_order;


/* ---- V5  The headline correction: censored vs uncensored repeat rate ----
   The uncensored figure is the old 3.12%. The 90-day figure is the
   defensible one. Expect the 90d rate to be LOWER (shorter window) but
   computed on a comparable-exposure population. */
SELECT
  ROUND(100 * AVG(CAST(ever_repeated AS INT64)), 2)        AS pct_ever_repeated_uncensored,
  ROUND(100 * AVG(CAST(repeat_within_30d  AS INT64)), 2)   AS pct_repeat_30d,
  ROUND(100 * AVG(CAST(repeat_within_60d  AS INT64)), 2)   AS pct_repeat_60d,
  ROUND(100 * AVG(CAST(repeat_within_90d  AS INT64)), 2)   AS pct_repeat_90d,
  ROUND(100 * AVG(CAST(repeat_within_180d AS INT64)), 2)   AS pct_repeat_180d
FROM `olist.v_fact_orders`
WHERE is_first_order;
-- NOTE: AVG ignores NULLs, so each window is automatically computed only on
-- customers with sufficient exposure. That is the whole point.


/* ---- V6  Sanity: does the flagship finding survive the grain change? ----
   Compare against the item-grain version. Direction must hold; the exact
   percentages will shift because multi-item orders are no longer double-counted. */
SELECT
  lateness_band,
  COUNT(*)                                        AS orders,
  ROUND(100*COUNT(*)/SUM(COUNT(*)) OVER (), 2)    AS pct_of_orders,
  ROUND(AVG(review_score), 3)                     AS avg_review_score,
  ROUND(100 * AVG(poor_review), 1)                AS pct_poor_review
FROM `olist.v_fact_orders`
WHERE order_status = 'delivered' AND review_score IS NOT NULL
GROUP BY lateness_band
ORDER BY MIN(lateness_days);

/* ============================================================================
   NEXT: with v_fact_orders in place, re-run the flagship lateness->review
   analysis at order grain (Kruskal-Wallis + Dunn + logistic regression),
   then the censoring-corrected repeat-purchase section.
   ============================================================================ */
