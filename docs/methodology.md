# Methodology

Standards every analysis in this project must meet. The purpose is that any claim in the
report can be defended under questioning.

---

## 1. The analysis template

Every major analysis is documented against this structure. If a section cannot be filled,
the analysis is not ready.

| Field | Requirement |
|---|---|
| **Business question** | What decision does this support? |
| **Unit of analysis** | What does one row represent? |
| **Metric** | Exact definition, including inclusions/exclusions |
| **Hypothesis** | H₀ and H₁, stated before looking at results |
| **Descriptive result** | What the raw data show |
| **Statistical inference** | Test used, and *why that test* |
| **Effect size** | Magnitude, not just significance |
| **Confidence interval** | Uncertainty on the estimate |
| **Controls** | Confounders considered and how handled |
| **Causal interpretation** | What can and cannot be claimed |
| **Limitations** | Stated explicitly, not buried |
| **Product implication** | The recommended action |

---

## 2. Unit of analysis

The single most common error available in this dataset.

`olist_order_items` is **item grain** — 112,650 rows across 98,666 orders. 9.9% of orders
contain more than one item. Joining item rows to order-level outcomes (review score,
delivery days, repeat purchase) causes a six-item order to contribute its single review
score six times.

Consequences: inflated *n*, understated standard errors, p-values that are too small, and
silent over-weighting of large baskets.

### Rule

| Outcome | View | Grain |
|---|---|---|
| Review score, delivery time, lateness, repeat purchase | `v_fact_orders` | one row = one order |
| Item price, freight per item, product attributes | `v_fact_order_items` | one row = one order item |
| Seller revenue, seller concentration | aggregate from item grain, report at seller grain | one row = one seller |

Where an order spans multiple sellers or categories (1,278 orders span sellers), the
**dominant** seller/category by item value is used — deterministic and reproducible.
`ANY_VALUE()` is avoided because it is non-deterministic and would make regression
coefficients change between runs.

---

## 3. Censoring and observation windows

The dataset ends **2018-10-17**. A customer acquired the week before had almost no
opportunity to return; one acquired in January 2017 had ~21 months.

Reporting "3.10% of customers ever repeated" as *retention* compares incomparable
exposure and understates the true rate.

### Treatment

Repeat indicators are three-state:

```
repeat_within_Nd = TRUE   -> second order observed within N days
                 = FALSE  -> N days elapsed with no second order
                 = NULL   -> insufficient exposure (censored)
```

NULL rows drop out of the denominator rather than counting as non-repeaters.

Usable share of first orders by window:

| Window | Usable |
|---|---|
| 30 days | 100.0% |
| 60 days | 98.5% |
| **90 days** | **90.5%** ← headline window |
| 180 days | 71.7% |

90 days is reported as the headline: long enough to be meaningful, retains 90% of the
cohort. The uncensored "ever repeated" figure is kept only for comparison with earlier
versions of this analysis and is never labelled retention.

---

## 4. Choice of statistical test

Tests are chosen for the data, not for variety.

**Review score is ordinal (1–5), heavily left-skewed, and bimodal.** ANOVA assumes
interval-scaled, approximately normal, homoscedastic data. None of those hold.

| Question | Test | Why |
|---|---|---|
| Does review score differ across lateness bands? | **Kruskal–Wallis** | Non-parametric, appropriate for ordinal outcome across >2 groups |
| Which specific bands differ? | **Dunn's post-hoc**, Holm-adjusted | Controls family-wise error across pairwise comparisons |
| Is lateness associated with a *poor* review? | **Logistic regression** on `poor_review` | Binary outcome, admits controls |
| Is the association monotonic in continuous lateness? | **Spearman ρ** | Rank-based, no linearity assumption |
| Independence of two categorical variables | **χ²** with Cramér's V | V reports effect size, not just significance |

Effect size is always reported alongside p. At n ≈ 96,000, trivial differences reach
significance; **statistical significance and practical significance are interpreted
separately in every section**.

---

## 5. Causal language policy

This is observational data. There is no randomised treatment, no instrument, and no
natural experiment.

**Permitted:** associated with · correlated with · linked to · predicts · differs
significantly across · consistent with

**Not permitted without design support:** causes · drives · forces · leads to · unlocks ·
results in · impact (as a verb)

### Specific caveats carried in the report

**Reverse causality on lateness → reviews.** An order that goes wrong — lost, damaged,
wrong item — is *both* late and badly reviewed. Lateness may be a **marker of a failed
fulfilment event** rather than a cause of dissatisfaction. Controls cannot resolve this;
only an experiment could. Stated explicitly wherever the finding appears.

**Lateness is measured against a padded promise.** Roughly 92% of orders arrive before
the estimated date, with a median several days early. "Late" therefore means an order
overran an already-generous buffer, not that it was merely slow.

**No profit claims.** The dataset contains item price and freight charged. It does not
contain cost of goods, seller margin, or Olist's take rate. Therefore:

| Say | Do not say |
|---|---|
| GMV, item value, order value | revenue (ambiguous), profit |
| Freight-to-value ratio, shipping cost burden | unprofitable, loss-making |

---

## 6. Data-quality decisions

| Issue | Decision |
|---|---|
| `customer_id` unique per order | All customer analysis keyed on `customer_unique_id` (96,096 people vs 99,441 order keys) |
| 775 orders with no items | Excluded via INNER JOIN in `v_fact_orders`; predominantly cancelled/unavailable |
| 547 orders with >1 review | Deduplicated to the most recent review |
| 2,961 orders paid across multiple methods | Rolled up to order total; dominant method = largest single line |
| 1,000,163 geolocation rows / 19,015 zips | Deduplicated to one centroid per zip prefix before any join (raw join fans out ~50×) |
| 3,852 reviews with embedded newlines | Line breaks collapsed to spaces at load |
| 610 products with null category | Coded `uncategorised` rather than dropped |
| Sparse periods at both ends of the series | Time-series analysis trimmed; trimming stated where applied |

---

## 7. Reporting standards

- Sample size shown on every figure where groups differ materially in size.
- Confidence intervals shown wherever a rate is compared across groups.
- Null results reported with the same prominence as positive ones.
- Every figure states its unit of analysis if not obvious.
- Numbers superseded by a methodological correction are updated everywhere, not
  selectively.
