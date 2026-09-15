# Urban Retail Co. - Inventory Optimization & Demand Analytics

SQL-based inventory analytics for a mid-sized retail chain, with a Power BI dashboard on top. The project takes two years of daily store-product inventory records, normalizes them into a relational schema, and answers the operational questions a supply chain team actually asks: what is understocked, what is sitting too long, where are reorder points, and how much can we trust the demand forecast.

---

## Problem

Urban Retail Co. manages inventory across five stores and four regions with limited visibility into stock movement. The result is inconsistent stock levels, overstocking of slow movers, and delayed restocking of high-demand products — missed sales on one side, tied-up capital on the other.

The goal of this project is to turn raw transactional data into decision-ready metrics: stockout risk, reorder points, turnover, forecast bias, and per-SKU stock adjustment recommendations.

---

## Dataset

`inventory_forecasting.csv` — 109,500 rows, one record per store / product / day.

| | |
|---|---|
| Date range | 2022-01-01 to 2023-12-31 |
| Stores | S001–S005 |
| Regions | North, South, East, West |
| Products | 30 SKUs |
| Categories | Clothing, Electronics, Furniture, Groceries, Toys |
| Seasonality | Winter, Spring, Summer, Autumn |
| Weather | Sunny, Cloudy, Rainy, Snowy |

Columns: `Date`, `Store ID`, `Product ID`, `Category`, `Region`, `Inventory Level`, `Units Sold`, `Units Ordered`, `Demand Forecast`, `Price`, `Discount`, `Weather Condition`, `Holiday/Promotion`, `Competitor Pricing`, `Seasonality`.

---

## Data model

The flat CSV is loaded into a staging table and split into a star-style schema. Because a store operates across multiple regions in this dataset, the grain key is a composite `store_region_id` (`store_id + '_' + region`) rather than `store_id` alone.

| Table | Grain | Key columns |
|---|---|---|
| `stores` | store-region | `store_region_id` (PK), `store_id`, `region` |
| `products` | product | `product_id` (PK), `category` |
| `seasonality` | product | `product_id` (PK), `seasonality` |
| `inventory` (fact) | date × store-region × product | `inventory_level`, `units_sold`, `units_ordered`, `demand_forecast` |
| `pricing` | date × store-region × product | `price`, `discount`, `competitor_pricing` |
| `events` | date × store-region | `weather_condition`, `holiday_promotion` |
| `staging_data` | raw load | all CSV columns |

Indexes are created on `(store_region_id, product_id, record_date)` for the fact and pricing tables, and `(store_region_id, record_date)` for events.

See `ERD_.png` for the diagram.

---

## Analysis performed

All queries live in `inventory.sql`, after the schema and load section.

**Stock health**
- **Store/product sales profile** — average, median, and standard deviation of `units_sold` per store-product.
- **Stock level calculation** — daily `inventory_level − units_sold`, flagged `Understock` when it falls below `avg − 1 stddev`.
- **Fast-selling vs slow-moving** — a SKU understocked on more than 10% of days is classified fast-selling; the rest are slow-moving.
- **Overstock detection** — records where inventory exceeds twice the demand forecast.
- **Stockout rate by store** — per store-region stockout frequency, benchmarked against the chain-wide average.

**Replenishment**
- **Reorder point estimation** — movement-aware:
  - fast-moving: `avg_inventory − avg_sales`
  - slow-moving: `avg_inventory − avg_sales − 0.5 × stddev`
- **Low inventory detection** — current inventory compared against that reorder point, labelled `Low Inventory` / `Sufficient`.
- **Stock adjustment recommendations** — combines movement type, holding cost (`avg_inventory × avg_price`), and a safety-stock estimate (`1.65 × stddev × √7`, assuming a 7-day lead time) to emit a priority-scored action per SKU: `INCREASE`, `REDUCE`, `OPTIMIZE`, or `MAINTAIN`, with an estimated cost impact.

**Efficiency and demand**
- **Inventory turnover** — approximate COGS (`units_sold × avg_price`) over average inventory, by product and category.
- **Forecast accuracy** — absolute and percentage error between `demand_forecast` and `units_sold`, rated from Excellent to Very Poor, with a bias label of `Over-Forecasted` / `Under-Forecasted` / `Well-Calibrated`.
- **Seasonal demand analysis** — monthly sales and forecast by store-region, seasonality, and category, with peak/trough months, volatility, variance from average, and a simple trend-based next-month projection.
- **Pricing effects** — average discount and competitor price gap against average units sold.
- **Regional summary** — inventory, sales, and stockout rate rolled up by region.

---

## Dashboard

`Dashboard.pbix` (preview in `dashboard.pdf`) surfaces the query outputs as an interactive report, sliced by `product_id` and `store_region_id`:

- Stock adjustment recommendations with holding cost and suggested action
- Low inventory detection, by product and by store-region
- Stock level calculations across store-regions
- Reorder point vs average sales, by product and by store
- Fast-selling vs slow-moving classification
- Monthly demand trend
- Inventory turnover by category

---

## Key findings

1. Forecasted demand runs consistently above actual sales, which pushes systematic overstocking.
2. Inventory levels are misaligned with store-level demand across most product lines.
3. About 11% of products are frequently understocked, pointing to weak replenishment planning.
4. Several stores show recurring understock on the same high-demand SKUs.
5. Reorder logic that distinguishes fast from slow movers produces noticeably tighter stock targets than a single flat rule.

---

## Recommendations

- Correct the forecast's upward bias using the monthly forecast-vs-actual comparison before it propagates into ordering.
- Run store-specific replenishment policies rather than a chain-wide rule; understock patterns are local.
- Act on threshold alerts for SKUs breaching the low-inventory line on more than 10% of days.
- Apply the segmented (fast/slow) stocking rules to trim holding cost on slow movers without starving fast sellers.
- Review the top understocked SKUs per store on a regular cadence.

---

## Repository contents

| File | Description |
|---|---|
| `inventory_forecasting.csv` | Source dataset (109,500 rows) |
| `inventory.sql` | Schema, data load, and all analytical queries (MySQL 8.0) |
| `ERD_.png` | Entity relationship diagram |
| `Dashboard.pbix` | Power BI report |
| `dashboard.pdf` | Static export of the dashboard |
| `INVENTORY_OPTIMIZATION_EXECUTIVE_SUMMARY.pdf` | Executive summary |

---

## How to run

1. Install MySQL 8.0 (window functions and CTEs are required).
2. Copy `inventory_forecasting.csv` into the server's `secure_file_priv` upload directory, then update the path in the `LOAD DATA INFILE` statement in `inventory.sql`.
3. Run the script top to bottom — it creates the `inventory` database, builds the tables, loads staging, populates the dimension and fact tables, and creates the indexes.
4. Run the analytical queries individually; each block below the index section is standalone.
5. Open `Dashboard.pbix` in Power BI Desktop and repoint the data source to your MySQL instance to refresh.

**Note on `LOAD DATA INFILE`:** if the server rejects the load, confirm `secure_file_priv` and enable `local_infile` (or use `LOAD DATA LOCAL INFILE`) on both server and client.

---

## Tech stack

MySQL 8.0 (CTEs, window functions, statistical aggregates) · Power BI Desktop
