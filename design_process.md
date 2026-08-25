# Commerce warehouse design

This Azure warehouse answers two questions:

1. Which products sell the most, by units and by revenue?
2. At what times does demand tend to be strongest?

## Submission

- [`Data Architecture.jpg`](Data%20Architecture.jpg) — platform and data flow
- [`Star Schema.png`](Star%20Schema.png) — reporting model
- [`warehouse.sql`](warehouse.sql) — representative tables, controls, load logic, and reporting views
- [`BI Mockup.svg`](BI%20Mockup.svg) — dashboard wireframe using the sample rows

The SQL is representative rather than a deployable application.

## Architecture

![Data architecture](Data%20Architecture.jpg)

SQL Server holds the sales and product systems. A self-hosted Azure Data Factory integration runtime reads both databases from the company network. ADF calls the FX API over HTTPS and loads Azure SQL Managed Instance, which runs in a private Azure subnet reached through the company VPN.

The warehouse has three schemas:

- `ingestion` stores source-shaped data, load metadata, watermarks, FX responses, and rejected rows.
- `transformation` owns cleaning, reconciliation, and load procedures.
- `reporting` contains the star schema and Tableau views.

ADF authenticates with its managed identity and reads the FX API secret from Key Vault. It can write to `ingestion` and execute approved procedures. Tableau has read-only access to `reporting`. Raw FX responses are retained so a load can be replayed and audited.

The diagram labels the same three areas Raw, Curated, and Reporting.

## Reporting model

![Star schema](Star%20Schema.png)

`FactSales` has one row per source order item. `(order_id, order_item_id)` prevents duplicate facts, while `sales_fact_id` is the warehouse key. This grain supports product units and revenue without allocating an order total across products.

`DimProduct` is Type 2. A changed name, category, or price creates a new product row, and each sale joins the version valid at its order time. `DimCustomer` is Type 1 because the required reporting does not need historical customer attributes. `DimDate` and `DimTime` support calendar and time-of-day analysis.

The sample catalogue is inserted when its setup script runs, but its orders have earlier business dates. The first known product version is therefore valid from `1900-01-01`; later versions retain their source system-time boundaries.

The fact stores the source line price and currency, the applied FX rate, and the USD unit and line amounts. Product revenue comes from the order line. The order header total stays in ingestion for reconciliation and is never repeated across facts. Only completed orders enter reporting; cancelled or deleted orders remove their facts on the next successful load.

Each dimension has a `-1` unknown row. A missing product or customer uses that key and raises a warning. Invalid currency, missing FX, non-positive quantity or price, and future orders are quarantined instead of entering reporting.

## Loads

ADF captures one UTC cutoff at the start of a run. Every retry uses that same cutoff. Each source object has its own last-successful watermark, which advances only after the complete load and reconciliation succeed.

| Source | Load | Reason |
|---|---|---|
| `orders` | Temporal delta | The source records system-time history. |
| `product_descriptions` | Temporal delta | Every version is required for Type 2 history. |
| `customers` | Full snapshot | The table is small and has no update marker. |
| `order_items` | Full bulk snapshot | The table has no update marker, so a delta would miss edits and deletes. |
| FX API | Date/currency upsert | Each required currency-to-USD rate is cached by effective date. |

Temporal extraction reads versions whose start or end boundary falls inside `[last_watermark, run_cutoff)`. The half-open boundary prevents adjacent runs from reading the same change. Orders are reduced to the latest state in `ingestion.OrderCurrent`; product versions keep their validity windows. A changed order with no current source row is a deletion.

Customer and order-item snapshots load into run-specific work tables. ADF validates keys, row counts, and types before replacing the live ingestion snapshot in one short transaction. The order-item copy is partitioned by ID ranges and loaded in parallel.

A full warehouse rebuild uses the same work-table pattern. Dimensions load first, then facts. Source counts, rejected rows, unknown-key use, and money totals must reconcile before the new reporting data is published. Watermarks are set to the rebuild cutoff.

## FX and data quality

The FX rate converts one unit of the line currency into USD on the order date. USD uses a rate of `1`. Calculations use wide decimals; stored USD amounts are rounded to four decimal places and Tableau formats them to two.

The sample contains:

- 453 orders and 363 lines covering 360 orders;
- 93 orders with no lines;
- 71 lines pointing to product IDs 101–110, outside the 1–100 catalogue;
- 79 invalid order currencies and 75 invalid line currencies;
- 114 lines whose currency differs from the order header;
- 67 amount mismatches among the 246 orders directly comparable in one currency.

The rules are fixed:

- Invalid or missing line FX quarantines the line.
- A missing product or customer uses key `-1` and logs a warning.
- An order without lines produces no fact and logs a reconciliation warning.
- Line currency is authoritative for product revenue; disagreement with the header logs a warning.
- Bad quantity, bad price, or a future order quarantines the line.
- A duplicate source line fails the run.
- Header and line totals are converted separately to USD before comparison.
- A missing daily FX response is retried, then fails the run without moving the watermark.

`ingestion.ErrorLog` records the run, source object, source key, reason, and source payload. `transformation.vw_OrderReconciliation` exposes missing lines, currency disagreement, missing rates, and USD amount differences. The run summary records source, staged, published, rejected, and unknown-key counts.

Source timestamps are treated as UTC because the supplied tables have no timezone field. The dashboard is labelled UTC.

## Business views

`reporting.vw_ProductPerformance` exposes units, order count, and USD revenue by product. `reporting.vw_DemandByTime` exposes weekday and hour with orders, units, revenue, and average order value. Tableau reads these views and never joins ingestion tables.

![BI mockup](BI%20Mockup.svg)

The raw line data contains 988 units across 360 orders. The dashboard shows the currency-valid subset: 793 units across 285 orders after excluding 75 lines with `ABC`, `QWE`, or `XYZ` currency. Three two-hour windows tie at 13 orders: Wednesday 15:00–16:59, Sunday 13:00–14:59, and Sunday 15:00–16:59.

The product bars use the same subset and rank products by units. USD revenue is blank because the supplied JSON contains rates for only two dates while orders span all of 2024. The production pipeline requests every required daily rate before publishing revenue.

## Delivery

The database is stored in a Microsoft.Build.Sql project and built into one DACPAC:

```text
warehouse/
  CommerceWarehouse.sqlproj
  ingestion/
  transformation/
  reporting/
  post-deploy/
.github/workflows/database.yml
```

Pull requests build and lint the project, generate a deployment report, and run database smoke tests. A merge to `main` publishes the DACPAC, deploys it to test, waits for production approval, and deploys the same artifact to production.

GitHub Actions authenticates to Azure through Entra OIDC. A self-hosted runner in the Azure network reaches the private SQL MI endpoint. Deployment blocks data-loss operations. Post-deploy tests check unknown members, duplicate fact grain, foreign keys, and reporting views. Failed database releases are corrected with a new DACPAC; point-in-time restore protects against data damage.

## Decisions and assumptions

- Reporting currency is USD, using the rate effective on the UTC order date.
- Revenue is completed line-item revenue before refunds, tax, and shipping because those fields are not supplied.
- Product history follows SQL Server system time. Backdated business-effective changes are outside the source contract.
- Recoverable missing dimensions use the unknown member; invalid money never enters reporting.
- `DimTime` is minute-grain, while Tableau groups it into the displayed two-hour windows.
- `FactSales` is indexed by order date and product. Production retention and performance are managed with date partitioning and clustered columnstore storage.
