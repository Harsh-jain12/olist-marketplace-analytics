# Notebooks

Run in order. Each assumes the BigQuery views from `sql/` already exist.

| Notebook | Status | Purpose |
|---|---|---|
| `01_data_validation.ipynb` | to be written | Grain, null and censoring checks against expected counts |
| `02_descriptive_analysis.ipynb` | drafted | Figures for the descriptive chapters. Being curated down |
| `03_statistical_analysis.ipynb` | first pass | Hypothesis tests and regression. **Being re-run at order grain** |
| `04_predictive_modeling.ipynb` | not started | Late-delivery prediction |

## Authentication

Notebooks authenticate via `google.colab.auth`. No credential file is committed or
required; nothing under `notebooks/` should ever contain a key.

```python
from google.colab import auth
auth.authenticate_user()

from google.cloud import bigquery
client = bigquery.Client(project="YOUR_PROJECT_ID")
```

## Known caveat

`03_statistical_analysis.ipynb` was first written against the item-grain view. Results in
it are superseded until re-run against `v_fact_orders`. Direction of findings is expected
to hold; exact figures will shift because multi-item orders no longer contribute their
review score more than once.
