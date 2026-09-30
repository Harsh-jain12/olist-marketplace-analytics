# Olist Marketplace Analytics

End-to-end product analytics on the **Olist Brazilian E-Commerce** dataset
(~100K orders, 96K customers, 3K sellers, Sep 2016 – Oct 2018).
**BigQuery SQL → Python → statistical inference → gradient boosting.**

The project is structured as a business investigation, not a tour of techniques:
one question, decomposed, ending in a decision.

---

## The question

> **Olist has a ~3% repeat-purchase rate. Why — and is it fixable?**

## What the analysis found

**1. Delivery lateness is strongly associated with poor reviews.**
Orders delivered past their promised date carry **7.7× the odds of a 1–2 star rating**
(95% CI [7.1, 8.4]) after controlling for distance, order value, category and
geography. Large, precise, and robust to specification.

**2. But first-order satisfaction does *not* predict repeat purchase.**
Logistic regression on each customer's *first* order finds no effect of first-order
review score on returning: **OR 0.98, 95% CI [0.945, 1.020], p = 0.79**. The interval
is tight and straddles 1.0, so this is a **precise null** — not an underpowered test.
The data rules out anything but a negligible effect.

**3. So Olist has two separate problems, not one causal chain.**
A **fulfilment** problem that damages satisfaction and drives support cost, and a
**retention** problem that appears structural — customers do not return regardless of
how well their order went. **Improving delivery will not fix retention.**

That distinction is the project's central result. It emerged from testing the original
hypothesis and finding it only half-supported.

**4. A delivery-time model beats Olist's own estimate by 68%.**
Gradient boosting on order, geography and seller-history features predicts delivery
time to **MAE 4.3 days** (bootstrap 95% CI [4.26, 4.36]) against **13.3 days** for
Olist's own production estimate on the same 25,352 held-out orders — a **67.6%**
reduction in error. Olist's estimate is biased **+12.7 days**; 93.8% of orders arrive
early, so the promise is padded rather than accurate.

Applied with a 10-day safety buffer the model is **strictly better on both axes at
once**: average promise shortens from 22.0 to 21.2 days *and* the late rate falls
**4.4% → 3.1%** (a 30% relative reduction). A more aggressive 8-day buffer buys a much
shorter promise (19.2 days, −2.8) but holds the late rate flat at ~4.5% rather than
improving it — the trade-off is real and is reported rather than smoothed over.

**5. Supply is geographically and commercially concentrated.**
**59.7% of sellers** sit in São Paulo against **42.0% of customers**, so demand is
served from a state holding a disproportionate share of supply — associated with longer
distances, higher freight and slower delivery. Revenue is concentrated too: the **top
20% of sellers account for 83% of item value** (top 10% → 67%), **Gini 0.79**.
Marketplace quality interventions can therefore target a few hundred sellers, not
thousands.

### What did *not* work, and is reported anyway

Predicting **which individual order** will be late barely beats chance
(best model PR-AUC 0.057, ROC-AUC 0.575, recall@10% 16.1%, lift 1.6×). Predicting
**how long** delivery will take works well; per-order late *classification* does not.
Both results are kept in `04_predictive_modeling.ipynb`.

---

## Repository structure

| Path | Contents |
|---|---|
| `sql/` | BigQuery cleaning views, order-grain base layer, analysis queries |
| `notebooks/` | Validation → descriptive → statistical → predictive |
| `figures/` | Exported charts (`descriptive/`, `statistical/`, `ml/`) |
| `docs/` | Methodology, data dictionary, project plan |
| `data/` | **Not committed** — load instructions in `data/README.md` |

### SQL

| File | Contents |
|---|---|
| `00_schema.sql` | Table load notes, expected row counts, known source-data defects |
| `01_cleaning_views.sql` | Cleaning layer: identifier fix, timestamp parsing, dedup |
| `02_order_grain_base.sql` | **`v_fact_orders`** — order-grain base layer + validation |
| `10_descriptive_temporal_retention.sql` | Volumes, growth, seasonality, repeat behaviour |
| `11_payments_reviews_catalogue.sql` | Payments, review distribution, catalogue |
| `12_geography_sellers_synthesis.sql` | Geography, seller concentration, synthesis |

### Notebooks

| Notebook | Purpose |
|---|---|
| `01_data_validation.ipynb` | Grain, null and censoring checks against expected counts |
| `02_descriptive_analysis.ipynb` | Figures for the descriptive chapters |
| `03_statistical_analysis.ipynb` | OLS, logistic regression, ANOVA, chi-square, effect sizes |
| `04_predictive_modeling.ipynb` | Delivery-time regression tied to an operational decision |

---

## Methodological choices worth calling out

These are the decisions that make the results defensible; each is documented in
[`docs/methodology.md`](docs/methodology.md).

**Unit of analysis is enforced.** Olist's `order_items` table is item grain. Using it
for order-level outcomes lets a six-item order contribute its single review score six
times, inflating *n* and understating standard errors. All order-level inference runs
on `v_fact_orders` (one row per order); only item economics use item grain.

**Repeat purchase is censoring-corrected.** A customer acquired in October 2018 had days
to return; one acquired in January 2017 had ~21 months. Repeat indicators are three-state
— TRUE / FALSE / NULL where exposure is insufficient — so each window is computed only on
customers who could have repeated. The raw "3.12% ever repeated" figure is retained only
for comparison and is **not** reported as retention.

**The customer identifier trap is documented.** `customer_id` is unique per *order*;
`customer_unique_id` identifies the person. Analysis keyed on the former reports a
repeat rate of exactly 0.00% — a silent, total error. All customer analysis uses
`customer_unique_id`.

**Causal language is restricted.** This is observational data with no randomised
treatment. Findings are stated as *associated with* / *predicts* / *differs significantly
across*. Notably, lateness may be a *marker* of a failed fulfilment event (lost, damaged)
rather than a cause of dissatisfaction; this reverse-causality risk is stated, not hidden.

**"Late" is measured against a padded promise.** Olist's delivery estimates are heavily
buffered — 93.8% of orders arrive early, with a +12.7 day bias. So a "late" order has
overrun a generous buffer and is likely pathological, not merely slow.

**Train/test split is temporal, not random.** The model trains on 2016-09 → 2018-04 and
tests on 2018-05 → 2018-08, so no future information leaks backwards. Seller-history
features use expanding windows bounded at the row before, for the same reason.

**No fabricated experiment.** The dataset contains no randomised treatment, so no A/B
test is presented. Experimentation is not invented to fill a gap.

---

## Reproducing

```bash
pip install -r requirements.txt
```

1. Load the nine CSVs to BigQuery per [`data/README.md`](data/README.md) and `sql/00_schema.sql`.
2. Set `PROJECT = "YOUR_PROJECT_ID"` at the top of each notebook.
3. Run `sql/01_cleaning_views.sql`, then `sql/02_order_grain_base.sql`.
4. Run the validation queries at the foot of `02_order_grain_base.sql` — row counts must
   match the expected values before proceeding.
5. Run `notebooks/01_data_validation.ipynb`, then the analysis notebooks in order.

Notebook outputs are stripped from version control, so notebooks must be run to
regenerate figures and tables.

## Data source and licence

The [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
is published on Kaggle by Olist under **CC BY-NC-SA 4.0**. Raw files are **not
committed** — see [`data/README.md`](data/README.md) for the load procedure and the
source-file defects that must be handled first. Analysis code in this repository is
released under the MIT licence; the dataset retains its original licence.

---

*Author: Harsh Jain · [github.com/Harsh-jain12](https://github.com/Harsh-jain12)*
