# Data

Raw data is **not committed** to this repository.

## Source

[Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
Licence: CC BY-NC-SA 4.0. ~100K orders placed on the Olist marketplace, Sep 2016 – Oct 2018.

## Load procedure

Create a BigQuery dataset named `olist` and load the nine CSVs under these **exact**
table names — the SQL depends on them.

| CSV | BigQuery table | Expected rows |
|---|---|---|
| `olist_orders_dataset.csv` | `orders` | 99,441 |
| `olist_customers_dataset.csv` | `customers` | 99,441 |
| `olist_order_items_dataset.csv` | `order_items` | 112,650 |
| `olist_order_payments_dataset.csv` | `order_payments` | 103,886 |
| `olist_order_reviews_dataset.csv` | `order_reviews` | 99,224 |
| `olist_products_dataset.csv` | `products` | 32,951 |
| `olist_sellers_dataset.csv` | `sellers` | 3,095 |
| `olist_geolocation_dataset.csv` | `geolocation` | 1,000,163 |
| `product_category_name_translation.csv` | `product_category_translation` | 71 |

Note the last table drops `name_` from the filename.

## Source-file defects that must be handled

These are properties of the published files, not of the analysis. Each will cause a load
failure or silent corruption if ignored.

**1. `order_reviews` — embedded newlines.** 3,852 reviews contain literal line breaks
inside quoted `review_comment_message` fields. Valid RFC 4180 CSV, but BigQuery's default
loader rejects it with *"Missing close quote character"*. Either enable **Allow quoted
newlines** under Advanced options, or use `--allow_quoted_newlines` with `bq load`.

**2. `product_category_name_translation` — UTF-8 BOM.** The file begins with a byte-order
mark, which auto-detect folds into the first column name. Joins then fail with
*"Name product_category_name not found"*. Strip the BOM before loading.

**3. Auto-detect may miss the header row.** If a table loads with columns named
`string_field_0`, `string_field_1`, the header row was ingested as data. Symptom: row
count is exactly one higher than expected. Fix by unchecking Auto detect and setting
**Header rows to skip = 1** with an explicit schema.

Check all tables at once:

```sql
SELECT table_name, column_name
FROM `olist.INFORMATION_SCHEMA.COLUMNS`
WHERE column_name LIKE 'string_field_%' OR column_name LIKE 'int64_field_%';
```

An empty result means every table loaded cleanly.

**4. Do not "correct" the typo'd column names.** `products` ships with
`product_name_lenght` and `product_description_lenght` (missing the *g*). These are
original to the dataset and the SQL references them as-is.

## Verify after loading

```sql
SELECT 'orders' t, COUNT(*) n FROM `olist.orders` UNION ALL
SELECT 'customers',      COUNT(*) FROM `olist.customers` UNION ALL
SELECT 'order_items',    COUNT(*) FROM `olist.order_items` UNION ALL
SELECT 'order_payments', COUNT(*) FROM `olist.order_payments` UNION ALL
SELECT 'order_reviews',  COUNT(*) FROM `olist.order_reviews` UNION ALL
SELECT 'products',       COUNT(*) FROM `olist.products` UNION ALL
SELECT 'sellers',        COUNT(*) FROM `olist.sellers` UNION ALL
SELECT 'geolocation',    COUNT(*) FROM `olist.geolocation` UNION ALL
SELECT 'product_category_translation', COUNT(*) FROM `olist.product_category_translation`;
```

Any table off by exactly +1 has its header row sitting in the data.
