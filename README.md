# Olist Marketplace Analytics

A product-analytics case study on the **Olist Brazilian E-Commerce** dataset
(~100K orders, 96K customers, 3K sellers, Sep 2016 – Oct 2018), built end to end in
**BigQuery SQL → Python → statistical inference → predictive modelling**.

The project is structured as a business investigation, not a tour of techniques:
one question, decomposed, ending in a decision.

---

## The question

> **Olist has a 3% repeat-purchase rate. Why — and is it fixable?**

## What the analysis found

**1. Delivery lateness is strongly associated with dissatisfaction.**
Orders delivered past their promised date are rated 1–2 star far more often than
on-time orders. The association is large, highly significant, and survives controls
for distance, order value, category and geography.

**2. But dissatisfaction does not explain the retention gap.**
Logistic regression on each customer's *first* order found **no significant effect of
first-order review score on repeat purchase** (OR ≈ 1.00, p = 0.79). The confidence
interval is tight, so this is a precise null, not an underpowered one.

**3. So Olist has two separate problems, not one causal chain.**
A *fulfilment* problem that damages satisfaction and support costs, and a *retention*
problem that appears structural — customers do not return regardless of how well their
order went. Fixing delivery will not, on this evidence, fix retention.

That distinction is the project's central result. It emerged from testing the original
hypothesis and finding it only half-supported.

**4. Supply is geographically concentrated.** 59.7% of sellers sit in São Paulo against
42.0% of customers — so 58% of demand is served from a state holding 40% of supply,
which is associated with longer distances, higher freight, and slower delivery.

**5. Revenue is concentrated in few sellers.** The top 20% of sellers account for ~83%
of item value (top 10% → 67%). Marketplace quality interventions can therefore target
a few hundred sellers rather than thousands.

---

## Repository structure

```
olist-marketplace-analytics/
├── sql/          BigQuery views and analysis queries
├── notebooks/    Validation, descriptive, statistical, predictive
├── figures/      Exported charts (descriptive / statistical / ml)
├── docs/         Methodology, data dictionary, project plan
└── data/         Not committed — see data/README.md
```

### SQL

| File | Contents |
|---|---|
| `00_schema.sql` | Table load notes, expected row counts, known source-data defects |
| `01_cleaning_views.sql` | Cleaning layer: identifier fix, timestamp parsing, dedup |
| `02_order_grain_base.sql` | **`v_fact_orders`** — the order-grain base layer + validation |
| `10_descriptive_temporal_retention.sql` | Volumes, growth, seasonality, repeat behaviour |
| `11_payments_reviews_catalogue.sql` | Payments, review distribution, catalogue |
| `12_geography_sellers_synthesis.sql` | Geography, seller concentration, synthesis |

### Notebooks

| Notebook | Purpose |
|---|---|
| `01_data_validation.ipynb` | Grain, null and censoring checks against expected counts |
| `02_descriptive_analysis.ipynb` | Figures for the descriptive chapters |
| `03_statistical_analysis.ipynb` | Hypothesis tests, regression, effect sizes |
| `04_predictive_modeling.ipynb` | Late-delivery prediction tied to an operational decision |

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
repeat rate of exactly 0.00%. All customer analysis uses `customer_unique_id`.

**Causal language is restricted.** This is observational data with no randomised
treatment. Findings are stated as *associated with* / *predicts* / *differs significantly
across*. Causal verbs are used only where design supports them — which here is nowhere.
Notably, lateness may be a *marker* of a failed fulfilment event (lost, damaged) rather
than a cause of dissatisfaction; this reverse-causality risk is stated, not hidden.

**"Late" is measured against a padded promise.** Olist's delivery estimates are heavily
buffered — ~92% of orders arrive early. So a "late" order has overrun a generous buffer
and is likely pathological, not merely slow. Reported accordingly.

**No fabricated experiment.** The dataset contains no randomised treatment, so no A/B
test is presented. Experimentation is demonstrated elsewhere rather than invented here.

---

## Data

The [Olist Brazilian E-Commerce Public Dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
is published on Kaggle under CC BY-NC-SA 4.0. Raw files are **not committed** — see
[`data/README.md`](data/README.md) for the load procedure and the source-file defects
that must be handled first.

## Reproducing

1. Load the nine CSVs to BigQuery per `data/README.md` and `sql/00_schema.sql`.
2. Run `sql/01_cleaning_views.sql`, then `sql/02_order_grain_base.sql`.
3. Run the validation queries at the foot of `02_order_grain_base.sql` — row counts must
   match the expected values before proceeding.
4. Run `notebooks/01_data_validation.ipynb`, then the analysis notebooks in order.

```bash
pip install -r requirements.txt
```

## Status

| Component | State |
|---|---|
| Data load + cleaning layer | Complete |
| Order-grain base layer | Complete, pending validation run |
| Descriptive analysis + figures | Complete; being reduced to a curated set |
| Statistical validation | First pass complete; being re-run at order grain |
| Predictive model | Not started |
| Written report | Not started |

---

*Author: Harsh Jain · [github.com/Harsh-jain12](https://github.com/Harsh-jain12)*
