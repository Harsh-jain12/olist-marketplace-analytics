# Data Dictionary

## Layers

```
raw tables  ->  cleaning views  ->  v_fact_order_items (item grain)
                                ->  v_fact_orders      (order grain)  <- use for inference
```

---

## Cleaning views

| View | Grain | Purpose |
|---|---|---|
| `v_orders_clean` | order | Timestamps cast; rows without a purchase timestamp dropped |
| `v_customers_clean` | order-key | Exposes both `customer_id` and `customer_unique_id`; city/state normalised |
| `v_orders_enriched` | order | Workhorse: orders + `customer_unique_id` + geography |
| `v_payments_order` | order | Payment lines summed to an order total; dominant method = largest line |
| `v_reviews_clean` | order | Deduplicated to the most recent review per order; `has_text` flag |
| `v_products_clean` | product | Category translated to English; nulls coded `uncategorised` |
| `v_geo_dedup` | zip prefix | One centroid per zip prefix — **always join through this** |
| `v_order_items_agg` | order | Item rows rolled up to order totals and dominant attributes |
| `v_customer_order_seq` | order | Order sequence, exposure days, censoring-aware repeat flags |

---

## `v_fact_orders` — the base layer

One row per order (98,666). Use for all order-level outcomes.

### Keys
| Column | Notes |
|---|---|
| `order_id` | Primary key |
| `customer_unique_id` | The **person**. Never use `customer_id` for customer analysis |
| `dominant_seller_id` | Seller carrying the most item value in the order |

### Timing
| Column | Definition |
|---|---|
| `purchase_ts`, `purchase_date`, `purchase_month` | Order placement |
| `approved_ts`, `carrier_ts`, `delivered_ts` | Pipeline milestones |
| `estimated_ts` | Promised delivery date shown to the customer |
| `delivery_days` | purchase → delivered |
| `promised_days` | purchase → estimated |
| `days_to_approve`, `days_seller_to_carrier`, `days_carrier_to_customer` | Pipeline legs |

### Lateness
| Column | Definition |
|---|---|
| `lateness_days` | delivered − estimated. Negative = early |
| `late_flag` | 1 if `lateness_days > 0` |
| `days_late_pos` | `lateness_days` floored at 0 |
| `days_early_pos` | Days ahead of promise, floored at 0 |
| `lateness_band` | Early / On time / 1-3d / 4-7d / 8d+ late |

> **Caveat.** Lateness is relative to Olist's own estimate, which is heavily padded —
> ~92% of orders arrive early. A "late" order overran a generous buffer and is likely a
> pathological fulfilment event rather than merely a slow one.

### Basket
| Column | Definition |
|---|---|
| `item_value` | Σ item price — **GMV excluding freight** |
| `freight_value` | Σ freight charged |
| `order_value` | item_value + freight_value |
| `n_items`, `n_products`, `n_sellers`, `is_multi_seller` | Composition |
| `category` | Dominant category by item value |
| `freight_to_value_ratio` | freight ÷ item value. **Shipping cost burden, not margin** |

### Geography
| Column | Definition |
|---|---|
| `customer_state`, `customer_city` | Delivery destination |
| `dominant_seller_state` | State of the dominant seller |
| `is_interstate` | Customer and seller states differ |
| `max_distance_km` | Furthest seller→customer distance in the order — binding constraint on delivery |
| `avg_distance_km` | Mean across items; sensitivity checks only |

### Experience
| Column | Definition |
|---|---|
| `review_score` | 1–5. **Ordinal** — parametric tests are inappropriate |
| `poor_review` | 1 if score ≤ 2 |
| `good_review` | 1 if score ≥ 4 |
| `review_has_text` | ~41% of reviews carry a free-text comment |

### Lifecycle and censoring
| Column | Definition |
|---|---|
| `order_seq` | Order number for this customer |
| `is_first_order` | `order_seq = 1` |
| `lifetime_orders` | Total observed orders for this customer |
| `days_to_next_order` | Gap to the next order; NULL if none observed |
| `exposure_days` | Days between this order and the dataset end (2018-10-17) |
| `repeat_within_30d/60d/90d/180d` | **Three-state.** TRUE / FALSE / NULL where exposure is insufficient |
| `ever_repeated` | Uncensored. Retained for comparison only — **do not report as retention** |

---

## Reference values

| Quantity | Value |
|---|---|
| Orders | 99,441 raw · 98,666 with items |
| Delivered orders | 96,478 |
| Unique customers (`customer_unique_id`) | 96,096 |
| Order keys (`customer_id`) | 99,441 |
| Sellers | 3,095 |
| Order items | 112,650 |
| Multi-item orders | 9,803 (9.9%) |
| Multi-seller orders | 1,278 |
| Date range | 2016-09-04 → 2018-10-17 |
| Sellers in São Paulo | 59.7% |
| Customers in São Paulo | 42.0% |
