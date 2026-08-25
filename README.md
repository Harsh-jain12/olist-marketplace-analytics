# Olist Marketplace Analytics

A **Product & Marketplace Analytics case study** using the Olist Brazilian E-Commerce dataset (~99K orders, ~96K customers, ~3K sellers; Sep 2016–Oct 2018).

Built with **BigQuery SQL → Python → statistical inference → predictive modelling**, the project investigates why so few customers place a second order and separates the marketplace's **fulfilment problem from its retention problem**.

## The central finding

The original hypothesis was:

**Poor fulfilment → poor customer experience → lower repeat purchase.**

The data supports only half of that chain.

**Fulfilment:** Orders delivered late are significantly more likely to receive poor reviews, and the relationship remains after controlling for distance, order value, category and geography.

**Retention:** First-order review score is **not a significant predictor of repeat purchase** (OR ≈ 1.00, p = 0.79), with a tight confidence interval around the null.

**Implication:** Olist appears to have **two distinct problems**:

1. A **fulfilment/CX problem** that manifests in late delivery and dissatisfaction.
2. A **retention problem** that cannot be explained by first-order satisfaction alone.

This changes the product recommendation: **improving delivery should be pursued as a customer-experience and operational initiative, but not assumed to solve retention.** Retention requires a separate investigation into customer, marketplace and product drivers.

## Marketplace findings

* **Seller concentration:** 59.7% of sellers are located in São Paulo, versus 42.0% of customers, indicating a substantial geographic concentration mismatch.
* **Fulfilment:** Greater seller-customer distance is associated with higher freight costs and longer delivery times.
* **Seller economics:** The top 20% of sellers account for ~83% of item value, indicating strong marketplace concentration.
* **Repeat behaviour:** The raw 3.12% ever-repeat figure is retained as a descriptive benchmark; retention estimates use censoring-aware repeat-purchase windows.

## Analytical approach

The project follows:

**Business question → data validation → correct analytical grain → descriptive analysis → statistical inference → predictive modelling → business decision**

Order-level inference is performed on a one-row-per-order analytical layer; customer, seller and item-level analyses use the corresponding grain.


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
