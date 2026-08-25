/* ============================================================================
   OLIST E-COMMERCE — PHASE 1 SQL  (BigQuery Standard SQL)
   Chapters covered: 0 (cleaning) · 1 (business overview) · 2 (temporal) · 4 (retention core)
   ----------------------------------------------------------------------------
   CONVENTIONS
   - Replace `olist` everywhere with your own `project.dataset` (e.g. `myproj.olist`).
   - Base tables assumed: olist.orders, olist.customers  (Phase-1 uploads only).
   - Timestamps in the raw CSV are strings like '2017-10-02 10:56:33'.
     SAFE_CAST(x AS TIMESTAMP) works whether the column loaded as STRING or TIMESTAMP.
   - Every SELECT below is meant to be run one at a time and its output exported
     to CSV for the Colab charting step.
   ============================================================================ */


/* ############################################################################
   CHAPTER 0 — DATA CLEANING (reusable VIEWs)
   Purpose: clean once, query everywhere. These three views are the foundation
   every later query builds on. The single most important thing they do is
   attach customer_unique_id so we never fall into the "customer_id = 1 order"
   trap that makes every customer look one-and-done.
   ############################################################################ */

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


/* ---- 0.4  Data-quality audit (run once, put the numbers in your report) ----
   Purpose: show you interrogated the data before trusting it. Quantifies null
   timestamps, unmatched customers, and status mix. */
SELECT
  COUNT(*)                                              AS total_rows,
  COUNTIF(customer_unique_id IS NULL)                   AS rows_no_customer_match,
  COUNTIF(delivered_ts IS NULL)                         AS rows_no_delivery_date,
  COUNTIF(approved_ts  IS NULL)                         AS rows_no_approval_date,
  COUNTIF(order_status = 'delivered')                   AS delivered_orders,
  COUNTIF(order_status = 'delivered'
          AND delivered_ts IS NULL)                     AS delivered_but_missing_date
FROM `olist.v_orders_enriched`;



/* ############################################################################
   CHAPTER 1 — BUSINESS OVERVIEW  ("what is Olist at scale?")
   ############################################################################ */

/* ---- 1.1  Headline volumes -------------------------------------------------
   NOTE: GMV / AOV need payments or order_items (Phase 2). Here we use ORDER
   COUNTS as the volume proxy and flag GMV as pending. */
SELECT
  COUNT(DISTINCT order_id)            AS total_orders,
  COUNT(DISTINCT customer_unique_id)  AS total_customers,   -- real people
  COUNT(DISTINCT customer_id)         AS total_order_keys,  -- = orders (illustrates the trap)
  DATE(MIN(purchase_ts))              AS first_order_date,
  DATE(MAX(purchase_ts))              AS last_order_date
FROM `olist.v_orders_enriched`;


/* ---- 1.2  Order-status funnel ----------------------------------------------
   Logic: window SUM as denominator gives each status's share in one pass.
   Look for: the small but real leak to canceled / unavailable — that becomes
   its own mini-analysis later. */
SELECT
  order_status,
  COUNT(*)                                             AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)   AS pct_of_orders
FROM `olist.v_orders_enriched`
GROUP BY order_status
ORDER BY orders DESC;


/* ---- 1.3  Monthly order growth (headline trajectory) -----------------------
   Look for: fast ramp through 2017, plateau into 2018. Decompose growth into
   "more customers" vs "same customers ordering more" (the latter is tiny here). */
SELECT
  DATE_TRUNC(DATE(purchase_ts), MONTH)      AS order_month,
  COUNT(*)                                  AS orders,
  COUNT(DISTINCT customer_unique_id)        AS active_customers,
  ROUND(COUNT(*) / COUNT(DISTINCT customer_unique_id), 3) AS orders_per_active_customer
FROM `olist.v_orders_enriched`
GROUP BY order_month
ORDER BY order_month;



/* ############################################################################
   CHAPTER 2 — TEMPORAL PATTERNS  ("when does Brazil shop?")
   ############################################################################ */

/* ---- 2.1  Clean monthly series (trimmed) -----------------------------------
   The data has a sparse tail (few orders Sep–Oct 2018) and a sparse head
   (a handful in 2016). Trimming to 2017-01 … 2018-08 avoids a misleading
   time-series cliff. Adjust the bounds after you see 1.3's output. */
SELECT
  DATE_TRUNC(DATE(purchase_ts), MONTH) AS order_month,
  COUNT(*)                             AS orders
FROM `olist.v_orders_enriched`
WHERE DATE(purchase_ts) BETWEEN '2017-01-01' AND '2018-08-31'
GROUP BY order_month
ORDER BY order_month;


/* ---- 2.2  TOP 15 ORDER DAYS — let the spikes reveal themselves --------------
   This is the honest way to find events: don't assume Black Friday, surface it.
   Expect the Black Friday window (late Nov 2017) to dominate. */
SELECT
  DATE(purchase_ts)                          AS order_date,
  FORMAT_DATE('%A', DATE(purchase_ts))       AS weekday,
  COUNT(*)                                   AS orders
FROM `olist.v_orders_enriched`
GROUP BY order_date, weekday
ORDER BY orders DESC
LIMIT 15;


/* ---- 2.3  Festival-window probe --------------------------------------------
   Daily series labelled with Brazilian retail windows. We CLAIM a festival
   effect only where the labelled window actually stands above its neighbours.
   Note the market-specific dates: Mother's Day (2nd Sun May) and
   Dia dos Namorados = June 12 (Brazil's Valentine's, NOT Feb 14). */
WITH daily AS (
  SELECT DATE(purchase_ts) AS order_date, COUNT(*) AS orders
  FROM `olist.v_orders_enriched`
  GROUP BY order_date
)
SELECT
  order_date,
  FORMAT_DATE('%A', order_date) AS weekday,
  orders,
  CASE
    WHEN order_date BETWEEN '2017-11-20' AND '2017-11-30' THEN 'Black Friday 2017'
    WHEN order_date BETWEEN '2017-05-08' AND '2017-05-14' THEN "Mother's Day 2017"
    WHEN order_date BETWEEN '2018-05-07' AND '2018-05-13' THEN "Mother's Day 2018"
    WHEN order_date BETWEEN '2017-06-05' AND '2017-06-12' THEN 'Dia dos Namorados 2017'
    WHEN order_date BETWEEN '2018-06-05' AND '2018-06-12' THEN 'Dia dos Namorados 2018'
    WHEN order_date BETWEEN '2017-12-15' AND '2017-12-24' THEN 'Christmas ramp 2017'
    WHEN order_date BETWEEN '2017-12-25' AND '2018-01-05' THEN 'Post-Christmas trough'
    WHEN order_date BETWEEN '2018-02-10' AND '2018-02-14' THEN 'Carnival 2018'
    ELSE NULL
  END AS festival_window
FROM daily
ORDER BY order_date;


/* ---- 2.4  Festival month vs. baseline (quantify the lift) -------------------
   For each labelled month, compare its order count to the 3-month trailing
   average as a rough baseline, so "spike" is a number, not a vibe. */
WITH monthly AS (
  SELECT DATE_TRUNC(DATE(purchase_ts), MONTH) AS m, COUNT(*) AS orders
  FROM `olist.v_orders_enriched`
  WHERE DATE(purchase_ts) BETWEEN '2017-01-01' AND '2018-08-31'
  GROUP BY m
)
SELECT
  m AS order_month,
  orders,
  ROUND(AVG(orders) OVER (ORDER BY m ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0) AS trailing_3m_avg,
  ROUND(100.0 * (orders - AVG(orders) OVER (ORDER BY m ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING))
        / NULLIF(AVG(orders) OVER (ORDER BY m ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING), 0), 1) AS pct_vs_baseline
FROM monthly
ORDER BY m;


/* ---- 2.5  Day-of-week pattern ---------------------------------------------- */
SELECT
  EXTRACT(DAYOFWEEK FROM purchase_ts)         AS dow_num,   -- 1 = Sunday
  FORMAT_DATE('%A', DATE(purchase_ts))        AS weekday,
  COUNT(*)                                    AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `olist.v_orders_enriched`
GROUP BY dow_num, weekday
ORDER BY dow_num;


/* ---- 2.6  Hour-of-day pattern ---------------------------------------------- */
SELECT
  EXTRACT(HOUR FROM purchase_ts) AS hour_of_day,
  COUNT(*)                       AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM `olist.v_orders_enriched`
GROUP BY hour_of_day
ORDER BY hour_of_day;


/* ---- 2.7  Day×Hour heatmap feed (for the Colab heatmap chart) -------------- */
SELECT
  EXTRACT(DAYOFWEEK FROM purchase_ts)  AS dow_num,
  FORMAT_DATE('%A', DATE(purchase_ts)) AS weekday,
  EXTRACT(HOUR FROM purchase_ts)       AS hour_of_day,
  COUNT(*)                             AS orders
FROM `olist.v_orders_enriched`
GROUP BY dow_num, weekday, hour_of_day
ORDER BY dow_num, hour_of_day;



/* ############################################################################
   CHAPTER 4 — RETENTION CORE  ("the 3% problem, quantified")
   ############################################################################ */

/* ---- 4.1  The identifier trap, made explicit -------------------------------
   Shows customer_id yields ~0% repeat (order-scoped) while customer_unique_id
   yields the true ~3%. Great slide: proves you found the trap. */
WITH by_order_key AS (
  SELECT customer_id AS k, COUNT(*) AS c
  FROM `olist.v_orders_enriched` GROUP BY customer_id
),
by_person_key AS (
  SELECT customer_unique_id AS k, COUNT(*) AS c
  FROM `olist.v_orders_enriched` GROUP BY customer_unique_id
)
SELECT 'customer_id (order-scoped)' AS identifier,
       COUNT(*) AS entities, COUNTIF(c > 1) AS with_multiple_orders,
       ROUND(100.0 * COUNTIF(c > 1) / COUNT(*), 2) AS repeat_pct
FROM by_order_key
UNION ALL
SELECT 'customer_unique_id (person)',
       COUNT(*), COUNTIF(c > 1),
       ROUND(100.0 * COUNTIF(c > 1) / COUNT(*), 2)
FROM by_person_key;


/* ---- 4.2  Repeat rate (the headline) --------------------------------------- */
WITH opp AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS order_count
  FROM `olist.v_orders_enriched`
  GROUP BY customer_unique_id
)
SELECT
  COUNT(*)                                              AS total_customers,
  COUNTIF(order_count = 1)                              AS one_time_buyers,
  COUNTIF(order_count > 1)                              AS repeat_buyers,
  ROUND(100.0 * COUNTIF(order_count > 1) / COUNT(*), 2) AS repeat_rate_pct
FROM opp;


/* ---- 4.3  Orders-per-person distribution (the fat "1" bar) ------------------ */
WITH opp AS (
  SELECT customer_unique_id, COUNT(DISTINCT order_id) AS order_count
  FROM `olist.v_orders_enriched`
  GROUP BY customer_unique_id
)
SELECT
  order_count,
  COUNT(*)                                             AS num_customers,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 3)   AS pct
FROM opp
GROUP BY order_count
ORDER BY order_count;


/* ---- 4.4  Cohort retention triangle ----------------------------------------
   cohort_month = month of first purchase; month_offset = months since.
   Export this long-format and pivot in Colab into the triangle + retention %.
   Expect near-total drop-off after offset 0 — that IS the story, not a bug. */
WITH first_purchase AS (
  SELECT customer_unique_id,
         DATE_TRUNC(DATE(MIN(purchase_ts)), MONTH) AS cohort_month
  FROM `olist.v_orders_enriched`
  GROUP BY customer_unique_id
),
activity AS (
  SELECT
    e.customer_unique_id,
    fp.cohort_month,
    DATE_DIFF(DATE_TRUNC(DATE(e.purchase_ts), MONTH), fp.cohort_month, MONTH) AS month_offset
  FROM `olist.v_orders_enriched` e
  JOIN first_purchase fp USING (customer_unique_id)
)
SELECT
  cohort_month,
  month_offset,
  COUNT(DISTINCT customer_unique_id) AS active_customers
FROM activity
GROUP BY cohort_month, month_offset
ORDER BY cohort_month, month_offset;


/* ---- 4.5  Time to second purchase (for the 3% who return) ------------------
   Reframes "low retention" as possibly "low FREQUENCY / considered purchase":
   if the median gap is months, Olist may be a considered-buy marketplace, not
   a broken habit business. */
WITH ranked AS (
  SELECT customer_unique_id, purchase_ts,
         ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS seq
  FROM `olist.v_orders_enriched`
),
first_two AS (
  SELECT
    customer_unique_id,
    MAX(IF(seq = 1, purchase_ts, NULL)) AS first_ts,
    MAX(IF(seq = 2, purchase_ts, NULL)) AS second_ts
  FROM ranked
  WHERE seq <= 2
  GROUP BY customer_unique_id
)
SELECT
  COUNT(*)                                                                    AS repeat_customers,
  ROUND(AVG(DATE_DIFF(DATE(second_ts), DATE(first_ts), DAY)), 1)              AS avg_days_to_2nd,
  APPROX_QUANTILES(DATE_DIFF(DATE(second_ts), DATE(first_ts), DAY), 100)[OFFSET(50)] AS median_days_to_2nd,
  MIN(DATE_DIFF(DATE(second_ts), DATE(first_ts), DAY))                        AS min_days,
  MAX(DATE_DIFF(DATE(second_ts), DATE(first_ts), DAY))                        AS max_days
FROM first_two
WHERE second_ts IS NOT NULL;


/* ---- 4.6  Time-to-second, bucketed (for the histogram chart) --------------- */
WITH ranked AS (
  SELECT customer_unique_id, purchase_ts,
         ROW_NUMBER() OVER (PARTITION BY customer_unique_id ORDER BY purchase_ts) AS seq
  FROM `olist.v_orders_enriched`
),
gaps AS (
  SELECT
    customer_unique_id,
    DATE_DIFF(DATE(MAX(IF(seq = 2, purchase_ts, NULL))),
              DATE(MAX(IF(seq = 1, purchase_ts, NULL))), DAY) AS days_gap
  FROM ranked
  WHERE seq <= 2
  GROUP BY customer_unique_id
)
SELECT
  CASE
    WHEN days_gap <= 7   THEN '0-7 days'
    WHEN days_gap <= 30  THEN '8-30 days'
    WHEN days_gap <= 90  THEN '31-90 days'
    WHEN days_gap <= 180 THEN '91-180 days'
    ELSE '180+ days'
  END AS gap_bucket,
  COUNT(*) AS customers
FROM gaps
WHERE days_gap IS NOT NULL
GROUP BY gap_bucket
ORDER BY MIN(days_gap);


/* ---- 4.7  Recency segmentation (the R in RFM; F≈1, M waits for Phase 2) ----
   Days since last purchase per person, bucketed. With near-zero repeat, this
   is mostly a "how long ago was their one order" map. */
WITH last_order AS (
  SELECT customer_unique_id, MAX(DATE(purchase_ts)) AS last_dt
  FROM `olist.v_orders_enriched`
  GROUP BY customer_unique_id
),
anchor AS ( SELECT MAX(DATE(purchase_ts)) AS ref_dt FROM `olist.v_orders_enriched` )
SELECT
  CASE
    WHEN DATE_DIFF(a.ref_dt, l.last_dt, DAY) <= 90  THEN '0-90 days'
    WHEN DATE_DIFF(a.ref_dt, l.last_dt, DAY) <= 180 THEN '91-180 days'
    WHEN DATE_DIFF(a.ref_dt, l.last_dt, DAY) <= 365 THEN '181-365 days'
    ELSE '365+ days'
  END AS recency_bucket,
  COUNT(*) AS customers
FROM last_order l CROSS JOIN anchor a
GROUP BY recency_bucket
ORDER BY MIN(DATE_DIFF(a.ref_dt, l.last_dt, DAY));

/* ============================================================================
   END PHASE 1.  Next uploads (Phase 2): order_items, products, payments,
   product_category_name_translation  →  unlocks GMV/AOV, category retention,
   and the Monetary axis of RFM.
   ============================================================================ */
