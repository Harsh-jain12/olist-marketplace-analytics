/* ============================================================================
   OLIST E-COMMERCE — PHASE 2a SQL  (BigQuery Standard SQL)
   Chapters: 6 (payments) · 9-partial (reviews + DELIVERY→REVIEW centerpiece)
             · 5-partial (product catalogue profiling only)
   ----------------------------------------------------------------------------
   DEPENDS ON: the Phase-1 views (v_orders_enriched etc.) already created.
   TABLE NAMES assumed: order_payments, order_reviews, products,
                        product_category_translation.  Rename to match yours.

   *** DEPENDENCY NOTE ***
   order_items is the BRIDGE from orders <-> products/sellers/categories.
   Until it is loaded, we CANNOT do category-sales, seller performance, or
   item-level price/freight. Those are Phase 2b. Everything below needs only
   the tables already uploaded.

   *** GMV CAVEAT ***
   GMV here = SUM(payment_value), which INCLUDES freight (it's total paid).
   Item-level product-only revenue arrives with order_items (Phase 2b).
   ============================================================================ */


/* ############################################################################
   CHAPTER 0 (Phase 2) — additional cleaning VIEWs
   ############################################################################ */

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



/* ############################################################################
   CHAPTER 6 — PAYMENTS  (Brazil-specific + finally GMV/AOV)
   ############################################################################ */

/* ---- 6.1  GMV & AOV (backfills Chapter 1's pending metric) ----------------- */
SELECT
  COUNT(*)                                              AS orders_with_payment,
  ROUND(SUM(order_payment_total), 2)                   AS total_gmv,        -- incl. freight
  ROUND(AVG(order_payment_total), 2)                   AS aov,
  APPROX_QUANTILES(order_payment_total, 100)[OFFSET(50)] AS median_order_value
FROM `olist.v_payments_order`;


/* ---- 6.2  Payment-type mix (credit vs boleto vs voucher/debit) ------------- */
SELECT
  primary_payment_type,
  COUNT(*)                                             AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)   AS pct_orders,
  ROUND(SUM(order_payment_total), 2)                   AS gmv,
  ROUND(AVG(order_payment_total), 2)                   AS aov
FROM `olist.v_payments_order`
GROUP BY primary_payment_type
ORDER BY orders DESC;


/* ---- 6.3  Installments (parcelamento) distribution + AOV lift --------------
   Look for: AOV climbing with installment count -> Brazilians finance bigger
   baskets. The market-specific flourish generic notebooks skip. */
SELECT
  max_installments                                     AS installments,
  COUNT(*)                                             AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)   AS pct_orders,
  ROUND(AVG(order_payment_total), 2)                   AS aov
FROM `olist.v_payments_order`
GROUP BY installments
ORDER BY installments;


/* ---- 6.4  Split-payment orders --------------------------------------------- */
SELECT
  CASE WHEN payment_lines = 1 THEN 'single method' ELSE 'split across methods' END AS split_flag,
  COUNT(*)                           AS orders,
  ROUND(AVG(order_payment_total), 2) AS aov
FROM `olist.v_payments_order`
GROUP BY split_flag;



/* ############################################################################
   CHAPTER 9 (partial) — REVIEWS & SATISFACTION
   ############################################################################ */

/* ---- 9.1  Review-score distribution ---------------------------------------- */
SELECT
  review_score,
  COUNT(*)                                           AS reviews,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `olist.v_reviews_clean`
GROUP BY review_score
ORDER BY review_score;


/* ---- 9.2  *** THE CENTERPIECE ***  Delivery lateness  ->  review score -----
   Gap = actual delivery vs the PROMISED (estimated) date. Negative = early.
   Look for: avg score cliff-diving as lateness grows, and % 1-2 star exploding
   in the 8+ days late bucket. This is the causal spine of the whole project. */
WITH base AS (
  SELECT
    DATE_DIFF(DATE(o.delivered_ts), DATE(o.estimated_ts), DAY) AS gap_days,
    r.review_score
  FROM `olist.v_orders_enriched` o
  JOIN `olist.v_reviews_clean`   r USING (order_id)
  WHERE o.order_status = 'delivered'
    AND o.delivered_ts IS NOT NULL
    AND o.estimated_ts IS NOT NULL
)
SELECT
  CASE
    WHEN gap_days <= -1            THEN 'Early'
    WHEN gap_days = 0              THEN 'On estimated day'
    WHEN gap_days BETWEEN 1 AND 3  THEN '1-3 days late'
    WHEN gap_days BETWEEN 4 AND 7  THEN '4-7 days late'
    ELSE '8+ days late'
  END AS delivery_bucket,
  COUNT(*)                                              AS orders,
  ROUND(AVG(review_score), 3)                           AS avg_review_score,
  ROUND(100.0 * COUNTIF(review_score <= 2) / COUNT(*), 1) AS pct_1_2_star
FROM base
GROUP BY delivery_bucket
ORDER BY MIN(gap_days);


/* ---- 9.3  Absolute delivery speed (purchase -> delivered) -> score --------- */
WITH base AS (
  SELECT
    DATE_DIFF(DATE(o.delivered_ts), DATE(o.purchase_ts), DAY) AS delivery_days,
    r.review_score
  FROM `olist.v_orders_enriched` o
  JOIN `olist.v_reviews_clean`   r USING (order_id)
  WHERE o.order_status = 'delivered' AND o.delivered_ts IS NOT NULL
)
SELECT
  CASE
    WHEN delivery_days <= 3  THEN '0-3 days'
    WHEN delivery_days <= 7  THEN '4-7 days'
    WHEN delivery_days <= 14 THEN '8-14 days'
    WHEN delivery_days <= 21 THEN '15-21 days'
    ELSE '22+ days'
  END AS speed_bucket,
  COUNT(*)                    AS orders,
  ROUND(AVG(review_score), 3) AS avg_score
FROM base
GROUP BY speed_bucket
ORDER BY MIN(delivery_days);


/* ---- 9.4  Estimate padding: how early does Olist beat its own promise? -----
   Look for: large positive avg_days_early + high % on-or-before -> Olist
   sandbags delivery estimates. The product question: tighten them (risk more
   "late" flags) or keep padding (customers wait longer than needed)? */
SELECT
  ROUND(AVG(DATE_DIFF(DATE(estimated_ts), DATE(delivered_ts), DAY)), 1)        AS avg_days_early,
  APPROX_QUANTILES(DATE_DIFF(DATE(estimated_ts), DATE(delivered_ts), DAY),100)[OFFSET(50)] AS median_days_early,
  ROUND(100.0 * COUNTIF(delivered_ts <= estimated_ts) / COUNT(*), 1)          AS pct_on_or_before_estimate
FROM `olist.v_orders_enriched`
WHERE order_status = 'delivered' AND delivered_ts IS NOT NULL AND estimated_ts IS NOT NULL;


/* ---- 9.5  Review coverage: how many reviews carry text (the NLP corpus) ---- */
SELECT
  COUNT(*)                                            AS total_reviews,
  COUNTIF(has_text)                                   AS reviews_with_text,
  ROUND(100.0 * COUNTIF(has_text) / COUNT(*), 1)      AS pct_with_text
FROM `olist.v_reviews_clean`;



/* ############################################################################
   CHAPTER 5 (partial) — PRODUCT CATALOGUE PROFILING
   NOTE: sales-linked category analysis needs order_items (Phase 2b). These
   queries profile the CATALOGUE only (what exists), not what SELLS.
   ############################################################################ */

/* ---- 5.1  Catalogue breadth + content quality by category ------------------ */
SELECT
  category,
  COUNT(*)                          AS products,
  ROUND(AVG(photos_qty), 2)         AS avg_photos,
  ROUND(AVG(description_length), 0) AS avg_desc_len,
  ROUND(AVG(weight_g), 0)           AS avg_weight_g
FROM `olist.v_products_clean`
GROUP BY category
ORDER BY products DESC
LIMIT 25;


/* ---- 5.2  Photo-count distribution (listing quality signal) ---------------- */
SELECT
  photos_qty,
  COUNT(*)                                           AS products,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `olist.v_products_clean`
GROUP BY photos_qty
ORDER BY photos_qty;

/* ============================================================================
   END PHASE 2a.
   Phase 2b (needs order_items): category sales & retention, seller performance,
   item-level price vs freight, content-quality -> sales/review payoff.
   Parallel track (Colab/Python): aspect-based sentiment + score-disagreement
   on the ~41K text reviews -> scored table -> join back here in SQL.
   ============================================================================ */
