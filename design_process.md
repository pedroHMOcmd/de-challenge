# Commerce warehouse design

This is a small Azure warehouse for two questions:

1. Which products sell the most, by units and by revenue?
2. At what times does demand tend to be strongest?

The second answer needs a little care. The source data can show when people buy; it cannot prove when a promotion causes the most extra sales because there is no campaign or control-group data. The first dashboard therefore recommends historically strong windows and makes that limitation clear.

## What is in this submission

- [`Data Architecture.jpg`](Data%20Architecture.jpg) — platform and data flow
- [`Star Schema.png`](Star%20Schema.png) — reporting model
- [`warehouse.sql`](warehouse.sql) — representative tables, controls, transformation logic, and reporting views
- [`BI Mockup.svg`](BI%20Mockup.svg) — a simple dashboard wireframe
- [`cheat_sheet.md`](cheat_sheet.md) — plain-English definitions for the main data and Azure terms

The SQL is intentionally representative rather than a deployable application. It is enough to make the important choices concrete without turning a design exercise into a fake production build.

## Architecture

![Data architecture](Data%20Architecture.jpg)

SQL Server holds the sales and product systems. Azure Data Factory (ADF) reads those databases through a self-hosted integration runtime or managed virtual network, calls the FX API, and lands data in Azure SQL Managed Instance. The warehouse is split into three schemas:

- `ingestion` keeps source-shaped data, load metadata, watermarks, and rejected rows.
- `transformation` contains the rules that make the source records consistent.
- `reporting` holds the star schema and the views Tableau uses.

Tableau only receives read access to `reporting`. ADF can write to `ingestion` and run approved load procedures, but it does not own the database. Secrets sit in Key Vault; managed identities are used where the service supports them. SQL MI and ADF use private network paths. The public FX call leaves through controlled outbound networking and its raw response is retained for replay and audit.

The diagram calls the schemas Raw, Curated, and Reporting. These map directly to `ingestion`, `transformation`, and `reporting` in the database project.

## Reporting model

![Star schema](Star%20Schema.png)

`FactSales` has one row per source order item. This is the lowest useful sales grain and supports both units and revenue without allocating order totals across products. `(order_id, order_item_id)` is unique; `sales_fact_id` is a warehouse-generated key.

`DimProduct` is Type 2 because the source product table is temporal. A sale joins the product version that was valid at the order time, so later renames or category changes do not rewrite history. `DimCustomer` is Type 1: neither business question needs historical customer attributes, and the source does not track them. Date and time are separate small dimensions. Time is minute-grain so a dashboard can switch between hour and smaller slots without rebuilding the fact.

One source wrinkle matters here: the sample catalogue is inserted when its setup script runs, while its orders carry older business dates. For the first product snapshot, the warehouse treats the earliest known version as valid from `1900-01-01`; later versions keep their real system-time boundaries. Otherwise every sample sale would incorrectly precede its product.

The fact keeps the source unit price and currency, the applied FX rate, and the calculated USD amounts. The order item price is used for product revenue; the order header total is retained in ingestion and used as a reconciliation check, not repeated on every line. Only completed orders appear in sales reporting. Cancelled or deleted orders remove their facts on the next successful load.

Every dimension has a `-1` member. A missing product or customer does not make a fact disappear: it uses the unknown member and raises a measurable warning. Invalid currency, missing FX, non-positive quantity or price, and future-dated orders are different: their facts are held back until the data is fixed.

## Loads

ADF captures one UTC upper bound at the start of a run and reuses it on retry. Each source object has its own last-successful watermark. The upper bound becomes the next watermark only after staging, checks, dimensions, facts, and reconciliation all succeed.

The supplied sources need two load styles:

| Source | Load style | Reason |
|---|---|---|
| `orders` | Temporal delta | It has `valid_from` and `valid_to` system-time columns. |
| `product_descriptions` | Temporal delta | Every version is needed to maintain product history. |
| `customers` | Full snapshot | It is small and has no reliable update column. |
| `order_items` | Full snapshot | It has no update column; a delta would silently miss edits and deletes. |
| FX API | Date/currency upsert | Rates are requested for transaction dates and cached. |

For temporal sources, the extraction finds versions whose start or end boundary falls inside the half-open interval `[last_watermark, run_upper_bound)`. Half-open bounds avoid reading the same boundary twice. Orders are collapsed to their latest state in `ingestion.OrderCurrent`; product versions retain their original validity window. A missing current row for a changed order is a deletion.

The relevant SQL is in `warehouse.sql`. It avoids using `FOR SYSTEM_TIME BETWEEN` as a change feed: that form returns rows that were merely active during the interval, not just rows that changed.

### Full refreshes

The customer and order-item snapshots are loaded to run-specific work tables first. ADF checks row counts, duplicate keys, and basic types, then swaps them into the live ingestion tables inside a short transaction. Readers never see a half-loaded snapshot.

The same shadow-table approach is used for a deliberate warehouse rebuild, such as the first load, recovery from watermark loss, a source correction outside temporal retention, or a transformation rule that changes historical results. Gold is rebuilt in dependency order—dimensions, then facts—validated against source counts and amounts, and published only when checks pass. Watermarks are reset to the captured rebuild boundary, not to the wall-clock time after the rebuild.

At larger volumes I would ask the source owners to make `order_items` temporal or add reliable change tracking. Recopying the full table is honest and safe for the supplied shape, but it is not the long-term answer for a very large order system.

## FX and data quality

The API says a rate converts one unit of `currency_from` into `currency_to`. The warehouse stores only the direction it uses: source currency to USD, by effective date. USD gets a rate of `1`. Amounts are calculated with wide decimals and rounded to two decimals only for the stored USD money values.

The supplied rows make the quality problem quite concrete. There are 453 orders but only 363 line items covering 360 of them, so orders 361–453 have no lines. Seventy-one lines point to product IDs 101–110 even though the catalogue ends at 100. The order and line tables also contain 79 and 75 invalid currency codes respectively. Header and line currency disagree on 114 lines. These are expected test cases, not edge cases to hide:

- invalid or missing FX: quarantine the line and do not publish it;
- unknown product/customer: publish under key `-1` and log a warning;
- order with no lines: publish no fact and log a warning for reconciliation;
- header/line currency disagreement: use line currency for product revenue and warn on the order;
- bad quantity/price or future order: quarantine;
- duplicate order item: fail the run because the fact grain is no longer trustworthy;
- order total versus line total mismatch: compare both sides in USD and record a warning with both amounts;
- missing FX API date: retry, then fail the run without moving the watermark.

Each error records the run, source object, source key, reason, and a small JSON payload. The run summary tracks source rows, staged rows, published rows, rejects, unknown-key use, and source-to-warehouse totals. Alerting fires on a failed run or on an agreed warning threshold.

`transformation.vw_OrderReconciliation` shows missing lines, currency disagreement, missing rates, and header-versus-line USD differences without mixing raw amounts from different currencies. The sample has 67 mismatches even among the 246 orders whose lines all use the header currency, which is another reason not to use the header total as product revenue.

Source timestamps are treated as UTC because the supplied tables have no timezone field. That is an explicit assumption to confirm before production. If the business wants local shopping behavior, a store/customer timezone must be added; country is not a safe timezone lookup.

## Business views

`reporting.vw_ProductPerformance` exposes units, order count, and USD revenue by product. Tableau can rank by either revenue or volume without touching staging tables.

`reporting.vw_DemandByTime` exposes day of week and hour with orders, units, revenue, and average order value. The dashboard uses a heatmap rather than declaring a single universal “best hour.” Filters for date, category, and weekday make the recommendation useful. A later version could join campaign exposure and margin data to estimate actual promotion lift and profit.

![BI mockup](BI%20Mockup.svg)

The mockup uses the supplied rows rather than invented totals. The raw line-item data contains 988 units across 360 orders. The displayed currency-valid subset contains 793 units across 285 orders after excluding 75 lines with `ABC`, `QWE`, or `XYZ` currency. The heatmap uses clear two-hour windows. Three cells tie at 13 orders: Wednesday 15:00–16:59, Sunday 13:00–14:59, and Sunday 15:00–16:59. The top-product bars use the same subset and are ranked by units. Normalized revenue is deliberately left blank because the JSON contains example rates for only two dates, while the orders span all of 2024. A real run would call the API for every required date before publishing revenue.

## Delivery

The database lives in a Microsoft.Build.Sql project and is built once into a DACPAC:

```text
warehouse/
  CommerceWarehouse.sqlproj
  ingestion/       tables and load-control objects
  transformation/  views and load procedures
  reporting/       dimensions, fact, and Tableau views
  post-deploy/      unknown members and date/time seeds
.github/workflows/
  database.yml
```

On a pull request, GitHub Actions restores the SQL project, builds the DACPAC, runs SQL linting, creates a deployment report against a disposable database, and runs a few grain/constraint tests. On merge, the same artifact is promoted to test and then production with environment approval. GitHub uses Entra OIDC, so there is no long-lived Azure password. A self-hosted runner inside the Azure network is needed to reach private SQL MI.

The workflow is deliberately plain:

```yaml
pull_request: build → lint → deployment report → smoke test
main:         build once → publish DACPAC → deploy test → approve → deploy production

permissions:
  id-token: write
  contents: read
runner: self-hosted Azure runner with private SQL MI access
```

The deployment step produces a script and blocks unexpected data-loss operations. Post-deploy smoke tests check the unknown members, duplicate fact grain, orphaned foreign keys, and reporting views. Database changes are normally rolled forward with a corrected DACPAC; backups and point-in-time restore cover the rare case where a data change must be reversed.

## Main assumptions and tradeoffs

- Reporting currency is USD and rates are effective by UTC order date.
- Revenue means completed line-item revenue before refunds, tax, and shipping; those fields are not supplied.
- Product history follows source system time. Backdated business-effective changes would need a separate effective-date field.
- Unknown dimension members keep recoverable sales visible. Invalid money does not enter reporting.
- Minute-level time is slightly more detail than the first dashboard needs, but costs only 1,440 rows.
- SQL MI is adequate for the stated design. If fact volume becomes very large, partitioning, columnstore, aggregate tables, and workload measurements would be considered from actual query patterns rather than added on day one.
