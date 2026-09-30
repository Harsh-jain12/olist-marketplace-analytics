# Project Plan

Living document. Records what exists, what was audited out, and what remains.

---

## Target narrative

| Chapter | Question |
|---|---|
| 1 · Marketplace overview | What is Olist, at what scale, growing how? |
| 2 · Marketplace supply | How concentrated is the seller base, and where does it sit? |
| 3 · Customer lifecycle | How many customers return, measured properly? |
| 4 · Fulfilment economics | What does distance cost in time and freight? |
| 5 · Customer experience | How does delivery performance relate to review outcomes? |
| 6 · Statistical validation | Do the headline associations survive formal testing? |
| 7 · Predictive analytics | Can at-risk orders be identified early enough to act? |
| 8 · Recommendations | What should the marketplace, product and ops teams do? |

Target: **8–12 figures in the main report.** Everything else moves to an appendix or is cut.

---

## Audit of existing analyses

Grades: **A** keep · **B** keep but improve · **C** supporting only · **D** remove.

| Analysis | Grade | Reason | Upgrade required |
|---|---|---|---|
| Delivery lateness → review score | **A** | Largest, cleanest association in the dataset. Currently descriptive; earlier χ² was run at item grain | Order grain; Kruskal–Wallis + Dunn; logistic regression with controls; OR, CI, effect size; reverse-causality caveat |
| First-order review → repeat purchase (null) | **A** | Precise null that contradicts the project's own hypothesis. The strongest interview asset | Re-run at order grain against 90-day censored target; report CI to show precision |
| `customer_id` identifier trap | **A** | Genuine integrity catch (0.00% vs 3.10%) | None; documented in methodology |
| Repeat rate | **B** | Right-censored; "3.10% retention" not defensible | 30/60/90/180-day windows; cohort curves; time-to-second-order |
| Distance → delivery / freight / review | **B** | Item grain. Headline overclaims: review falls only 0.25 pts while freight rises 170% | Order grain; Spearman ρ; partial correlation controlling delivery time. Reframe as a **cost** finding |
| Seller Pareto | **B** | Correct and striking (top 20% → 83%) but a single curve | Add Gini, HHI, top 1/5/10/20% table with CIs |
| Freight-to-value ratio | **B** | Real finding (75% vs 7%). Earlier wording said "structurally unprofitable" — unsupported, no cost data | Rename to shipping cost burden; report `SUM(freight)/SUM(price)` alongside mean-of-ratios |
| São Paulo supply/demand gap | **B** | Asserted from a bar chart. PR is proportionally more skewed than SP; RJ has the largest deficit | Regress delivery time and freight on state-level supply–demand gap |
| Payments / installments | **C** | AOV R\$121 → R\$419 is real but non-monotonic; 11 installments has 23 orders | Spearman ρ with controls; move to appendix |
| Monthly growth, Black Friday | **C** | Correct, well-executed, but scene-setting | None |
| Order status funnel | **C** | Better as a one-line exclusion statement | Fold into methodology |
| Cohort triangle | **C** | Near-empty once plotted | Superseded by windowed repeat curves |
| Day-of-week / hour-of-day | **D** | No decision follows from it | Cut from main report |
| Catalogue profiling (photos, description length) | **D** | Weak, correlational, no attached decision | Cut |

---

## Roadmap

### Phase 1 — Base layer ✅ written, pending validation
`v_fact_orders` at order grain with censoring-aware repeat flags.
**Gate:** validation queries V1–V6 must pass before any downstream work.

### Phase 2 — Flagship statistical analysis
Lateness → poor review, done properly.
Order grain → descriptives → Kruskal–Wallis → Dunn (Holm) → logistic regression with
controls (distance, freight, order value, category, state, month) → OR + 95% CI →
statistical vs practical significance → limitations.

### Phase 3 — Censoring-corrected lifecycle
30/60/90/180-day repeat rates on comparable-exposure cohorts; time-to-second-order;
re-run first-order-experience model against the 90-day target.

### Phase 4 — Marketplace structure
Seller concentration with Gini/HHI. Quantify supply concentration → distance →
fulfilment friction as a regression, not an assertion.

### Phase 5 — Predictive model
Late-delivery prediction. **Leakage is the main risk:** `approved_ts`, `carrier_ts` and
anything derived from actual delivery are post-hoc and must be excluded. Seller
historical performance must be computed on a rolling basis with no future data. Evaluate
with PR-AUC (the positive class is rare) and tie the operating threshold to an
intervention decision, not to maximum AUC.

### Phase 6 — Report and curation
Reduce to 8–12 figures. Write the narrative. Appendix for demoted analyses.

---

## Explicitly out of scope

**A/B testing.** The dataset contains no randomised treatment. Presenting a fabricated
experiment would be dishonest and is trivially caught. Experimentation will be
demonstrated on a dataset that supports it.

**Time-series forecasting.** ~20 months of usable history with a single observation of
each seasonal event. Seasonal decomposition cannot be validated, and the 2018 plateau
makes the forecast uninformative. Being able to explain *why not* is itself a stronger
signal than a forecast that cannot be defended.

**Profit analysis.** No cost of goods, seller margin or take rate in the data.

---

## Open decisions

- Whether review-text NLP earns its place. ~41K Portuguese comments exist. Only worth
  doing as **aspect extraction** (logistics vs product complaints) and
  **sentiment–score disagreement** — polarity sentiment alone would largely re-derive the
  star rating and invites the question "what did it add?"
- Whether repeat-purchase prediction is added as a second model, or effort concentrates
  on one strong model.
