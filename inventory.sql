-- Create and use database
CREATE DATABASE inventory;
USE inventory;

-- Create Stores Table with composite store_region_id as primary key
CREATE TABLE stores (
    store_region_id VARCHAR(110) PRIMARY KEY,  -- composite key store_id + region
    store_id VARCHAR(10),
    region VARCHAR(100)
);

-- Create Products Table
CREATE TABLE products (
    product_id VARCHAR(10) PRIMARY KEY,
    category VARCHAR(100)
);

-- Create Inventory Table with store_region_id instead of store_id
CREATE TABLE inventory (
    record_date DATE,
    store_region_id VARCHAR(110),
    product_id VARCHAR(10),
    inventory_level INT,
    units_sold INT,
    units_ordered INT,
    demand_forecast DECIMAL(10,2),
    PRIMARY KEY (record_date, store_region_id, product_id),
    FOREIGN KEY (store_region_id) REFERENCES stores(store_region_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);

-- Create Pricing Table with store_region_id
CREATE TABLE pricing (
    store_region_id VARCHAR(110),
    product_id VARCHAR(10),
    record_date DATE,
    price DECIMAL(10,2),
    discount DECIMAL(5,2),
    competitor_pricing DECIMAL(10,2),
    PRIMARY KEY (store_region_id, product_id, record_date),
    FOREIGN KEY (store_region_id) REFERENCES stores(store_region_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);

-- Create Events Table with store_region_id
CREATE TABLE events (
    store_region_id VARCHAR(110),
    record_date DATE,
    weather_condition VARCHAR(50),
    holiday_promotion BOOLEAN,
    PRIMARY KEY (store_region_id, record_date),
    FOREIGN KEY (store_region_id) REFERENCES stores(store_region_id)
);

-- Create Seasonality Table
CREATE TABLE seasonality (
    product_id VARCHAR(10) PRIMARY KEY,
    seasonality VARCHAR(50),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
);

-- Create Staging Table for raw data import with store_region_id column
CREATE TABLE staging_data (
    record_date DATE,
    store_id VARCHAR(10),
    product_id VARCHAR(10),
    category VARCHAR(100),
    region VARCHAR(100),
    store_region_id VARCHAR(110),
    inventory_level INT,
    units_sold INT,
    units_ordered INT,
    demand_forecast DECIMAL(10,2),
    price DECIMAL(10,2),
    discount DECIMAL(5,2),
    weather_condition VARCHAR(50),
    holiday_promotion BOOLEAN,
    competitor_pricing DECIMAL(10,2),
    seasonality VARCHAR(50)
);

-- Load data into staging_data (adjust file path as needed)
LOAD DATA INFILE '\\ProgramData\\MySQL\\MySQL Server 8.0\\Uploads\\inventory_forecasting.csv'
INTO TABLE staging_data
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(@record_date, store_id, product_id, category, region, inventory_level, 
 units_sold, units_ordered, demand_forecast, price, discount,
 weather_condition, holiday_promotion, competitor_pricing, seasonality)
SET 
    record_date = STR_TO_DATE(@record_date, '%Y-%m-%d'),
    store_region_id = CONCAT(store_id, '_', region);

-- Populate dimension tables with distinct values including store_region_id
INSERT IGNORE INTO stores (store_region_id, store_id, region)
SELECT DISTINCT store_region_id, store_id, region FROM staging_data;

INSERT IGNORE INTO products (product_id, category)
SELECT DISTINCT product_id, category FROM staging_data;

INSERT IGNORE INTO seasonality (product_id, seasonality)
SELECT DISTINCT product_id, seasonality FROM staging_data;

-- Populate fact tables using store_region_id
INSERT INTO inventory (record_date, store_region_id, product_id, inventory_level, units_sold, units_ordered, demand_forecast)
SELECT record_date, store_region_id, product_id, inventory_level, units_sold, units_ordered, demand_forecast
FROM staging_data;

INSERT IGNORE INTO pricing (store_region_id, product_id, record_date, price, discount, competitor_pricing)
SELECT DISTINCT store_region_id, product_id, record_date, price, discount, competitor_pricing
FROM staging_data;

INSERT IGNORE INTO events (store_region_id, record_date, weather_condition, holiday_promotion)
SELECT DISTINCT store_region_id, record_date, weather_condition, holiday_promotion
FROM staging_data;

-- Indexes for performance
CREATE INDEX idx_inventory_store_product_date ON inventory(store_region_id, product_id, record_date);
CREATE INDEX idx_pricing_store_product_date ON pricing(store_region_id, product_id, record_date);
CREATE INDEX idx_events_store_date ON events(store_region_id, record_date);

-- store, product analysis
WITH ranked_sales AS (
    SELECT
        store_region_id,
        product_id,
        units_sold,
        ROW_NUMBER() OVER (PARTITION BY store_region_id, product_id ORDER BY units_sold) AS row_num,
        COUNT(*) OVER (PARTITION BY store_region_id, product_id) AS total_count
    FROM inventory
),
median_sales AS (
    SELECT
        store_region_id,
        product_id,
        AVG(units_sold) AS median_sales
    FROM ranked_sales
    WHERE row_num IN (FLOOR((total_count + 1) / 2), CEIL((total_count + 1) / 2))
    GROUP BY store_region_id, product_id
)
SELECT
    i.store_region_id,
    i.product_id,
    AVG(i.units_sold) AS avg_sales,
    m.median_sales,
    STDDEV(i.units_sold) AS stddev_sales
FROM inventory i
JOIN median_sales m ON i.store_region_id = m.store_region_id AND i.product_id = m.product_id
GROUP BY i.store_region_id, i.product_id, m.median_sales
ORDER BY i.store_region_id, i.product_id;

-- Stock Level Calculations across stores and warehouse
WITH stats AS (
    SELECT 
        store_region_id,
        product_id,
        AVG(inventory_level - units_sold) AS avg_inv_minus_sales,
        STDDEV(inventory_level - units_sold) AS stddev_inv_minus_sales,
        (AVG(inventory_level - units_sold) - STDDEV(inventory_level - units_sold)) AS threshold
    FROM inventory
    GROUP BY store_region_id, product_id
)
SELECT 
    i.record_date,
    i.store_region_id,
    i.product_id,
    p.category,
    (i.inventory_level - i.units_sold) AS stock_level,
    s.threshold,
    CASE 
        WHEN (i.inventory_level - i.units_sold) < s.threshold THEN 'Understock'
        ELSE 'Normal'
    END AS stock_status
FROM inventory i
JOIN stats s ON i.store_region_id = s.store_region_id AND i.product_id = s.product_id
JOIN products p ON i.product_id = p.product_id
ORDER BY i.store_region_id, i.product_id, i.record_date;

-- fast selling vs slow moving
WITH stats AS (
    SELECT 
        store_region_id,
        product_id,
        (AVG(inventory_level - units_sold) - 1.3 * STDDEV(inventory_level - units_sold)) AS threshold
    FROM inventory
    GROUP BY store_region_id, product_id
),
daily_understock AS (
    SELECT 
        i.record_date,
        i.store_region_id,
        i.product_id,
        (i.inventory_level - i.units_sold) AS inv_minus_sales,
        s.threshold,
        CASE 
            WHEN (i.inventory_level - i.units_sold) < s.threshold THEN 1 
            ELSE 0 
        END AS is_understock
    FROM inventory i
    JOIN stats s ON i.store_region_id = s.store_region_id AND i.product_id = s.product_id
),
understock_counts AS (
    SELECT 
        store_region_id,
        product_id,
        COUNT(*) AS total_days,
        SUM(is_understock) AS understock_days,
        (SUM(is_understock) * 100.0 / COUNT(*)) AS understock_percentage
    FROM daily_understock
    GROUP BY store_region_id, product_id
)
SELECT 
    store_region_id,
    product_id,
    understock_days,
    total_days,
    ROUND(understock_percentage, 2) AS understock_percentage,
    CASE 
        WHEN understock_percentage > 10 THEN 'Fast-selling'
        ELSE 'Slow-moving'
    END AS movement_type
FROM understock_counts
ORDER BY understock_percentage DESC;


-- Overstock Detection (inventory_level > 1.5 * demand_forecast)
SELECT 
    i.store_region_id,
    i.product_id,
    i.inventory_level,
    i.demand_forecast,
    (i.inventory_level - i.demand_forecast) AS overstock_amount
FROM inventory i
WHERE i.inventory_level > 2 * i.demand_forecast
ORDER BY overstock_amount DESC;


-- Average Inventory and Sales by Category
SELECT 
    p.category,
    ROUND(AVG(i.inventory_level), 2) AS avg_inventory,
    SUM(i.units_sold) AS total_units_sold,
    SUM(i.demand_forecast) AS total_forecast
FROM inventory i
JOIN products p ON i.product_id = p.product_id
GROUP BY p.category;


-- Demand Forecast Accuracy (absolute error between forecast and actual sales)
SELECT 
    i.store_region_id,
    i.product_id,
    p.category,
    ROUND(AVG(i.demand_forecast), 2) AS avg_forecast,
    ROUND(AVG(i.units_sold), 2) AS avg_actual_sales,
    ROUND(ABS(AVG(i.units_sold) - AVG(i.demand_forecast)), 2) AS avg_forecast_error,
    CASE 
        WHEN ABS(AVG(i.units_sold) - AVG(i.demand_forecast)) < 10 THEN 'Good Forecast'
        ELSE 'Poor Forecast'
    END AS forecast_quality
FROM inventory i
JOIN products p ON i.product_id = p.product_id
GROUP BY i.store_region_id, i.product_id, p.category
ORDER BY avg_forecast_error DESC;


-- Competitor Pricing Impact on Demand
SELECT 
    i.product_id,
    p.category,
    AVG(pr.competitor_pricing) AS avg_competitor_price,
	(AVG(price) - avg(pr.competitor_pricing) ) AS Difference,
    AVG(i.units_sold) AS avg_units_sold
FROM inventory i
JOIN pricing pr ON i.store_region_id = pr.store_region_id AND i.product_id = pr.product_id AND i.record_date = pr.record_date
JOIN products p ON i.product_id = p.product_id
GROUP BY i.product_id, p.category
ORDER BY avg_competitor_price DESC;

-- Stockout Rate by Store 
WITH stats AS (
    SELECT 
        store_region_id,
        product_id,
        (AVG(inventory_level - units_sold) - STDDEV(inventory_level - units_sold)) AS threshold
    FROM inventory
    GROUP BY store_region_id, product_id
),
daily_stockout AS (
    SELECT 
        i.record_date,
        i.store_region_id,
        i.product_id,
        (i.inventory_level - i.units_sold) AS inv_minus_sales,
        s.threshold,
        CASE 
            WHEN (i.inventory_level - i.units_sold) < s.threshold THEN 1
            ELSE 0
        END AS is_stockout
    FROM inventory i
    JOIN stats s 
        ON i.store_region_id = s.store_region_id
       AND i.product_id = s.product_id
),
stockout_summary_by_store AS (
    SELECT 
        store_region_id,
        COUNT(*) AS total_days,
        SUM(is_stockout) AS stockout_days,
        (SUM(is_stockout) * 100.0 / COUNT(*)) AS stockout_rate_percentage
    FROM daily_stockout
    GROUP BY store_region_id
),
performance_benchmark AS (
    SELECT 
        store_region_id,
        stockout_days,
        total_days,
        stockout_rate_percentage,
        AVG(stockout_rate_percentage) OVER() AS overall_avg_stockout_rate
    FROM stockout_summary_by_store
)
SELECT 
    store_region_id,
    stockout_days,
    total_days,
    ROUND(stockout_rate_percentage, 2) AS stockout_rate_percentage,
    CASE 
        WHEN stockout_rate_percentage < overall_avg_stockout_rate THEN 'Good Performance'
        ELSE 'Poor Performance - High Stockouts'
    END AS region_performance
FROM performance_benchmark
ORDER BY stockout_rate_percentage DESC;


-- Average Discount Impact on Sales
SELECT 
    i.product_id,
    p.category,
    AVG(pr.discount) AS avg_discount,
    AVG(i.units_sold) AS avg_units_sold
FROM inventory i
JOIN pricing pr ON i.store_region_id = pr.store_region_id AND i.product_id = pr.product_id AND i.record_date = pr.record_date
JOIN products p ON i.product_id = p.product_id
GROUP BY i.product_id, p.category
ORDER BY avg_discount DESC;


-- Reorder Point Estimation using historical trend 
WITH stats AS (
    SELECT
        store_region_id,
        product_id,
        AVG(inventory_level - units_sold) AS avg_inv_minus_sales,
        STDDEV(inventory_level - units_sold) AS stddev_inv_minus_sales,
        AVG(inventory_level) AS avg_inventory,
        AVG(units_sold) AS avg_sales,
        (AVG(inventory_level - units_sold) - 1.3*STDDEV(inventory_level - units_sold)) AS threshold
    FROM inventory
    GROUP BY store_region_id, product_id
),
-- Step 2: Calculate inv - sales per day, and flag as understock or not
daily_understock AS (
    SELECT 
        i.record_date,
        i.store_region_id,
        i.product_id,
        (i.inventory_level - i.units_sold) AS inv_minus_sales,
        s.threshold,
        CASE 
            WHEN (i.inventory_level - i.units_sold) < s.threshold THEN 1 
            ELSE 0 
        END AS is_understock
    FROM inventory i
    JOIN stats s 
        ON i.store_region_id = s.store_region_id 
       AND i.product_id = s.product_id
),
-- Step 3: Summarize understock frequency for classification
understock_summary AS (
    SELECT 
        store_region_id,
        product_id,
        COUNT(*) AS total_days,
        SUM(is_understock) AS understock_days,
        (SUM(is_understock) * 100.0 / COUNT(*)) AS understock_percentage
    FROM daily_understock
    GROUP BY store_region_id, product_id
),
-- Step 4: Combine stats and understock summary to calculate reorder point
final_calc AS (
    SELECT 
        s.store_region_id,
        s.product_id,
        s.avg_inventory,
        s.avg_sales,
        s.stddev_inv_minus_sales,
        us.understock_days,
        us.total_days,
        ROUND(us.understock_percentage, 2) AS understock_percentage,
        CASE 
            WHEN (us.understock_percentage > 10) THEN 'Fast-moving'
            ELSE 'Slow-moving'
        END AS movement_type,
        CASE 
            WHEN (us.understock_percentage > 5) THEN (s.avg_inventory - s.avg_sales)
            ELSE (s.avg_inventory - s.avg_sales - 0.5 * s.stddev_inv_minus_sales)
        END AS reorder_point
    FROM stats s
    JOIN understock_summary us 
        ON s.store_region_id = us.store_region_id AND s.product_id = us.product_id
)
-- Step 5: Final result with product category
SELECT 
    f.store_region_id,
    f.product_id,
    p.category,
    f.movement_type,
    ROUND(f.reorder_point, 2) AS reorder_point,
    ROUND(f.avg_inventory, 2) AS avg_inventory,
    ROUND(f.avg_sales, 2) AS avg_sales,
    ROUND(f.stddev_inv_minus_sales, 2) AS stddev_inv_minus_sales,
    f.understock_days,
    f.total_days,
    f.understock_percentage
FROM final_calc f
JOIN products p ON f.product_id = p.product_id
ORDER BY f.store_region_id, f.product_id;


-- Low Inventory Detection based on reorder point
WITH stats AS (
    -- Step 1: Precompute aggregates for each store_region_id + product_id
    SELECT
        store_region_id,
        product_id,
        AVG(inventory_level - units_sold) AS avg_inv_minus_sales,
        STDDEV(inventory_level - units_sold) AS stddev_inv_minus_sales,
        AVG(inventory_level) AS avg_inventory,
        AVG(units_sold) AS avg_sales
    FROM inventory
    GROUP BY store_region_id, product_id
),
understock_days_calc AS (
    -- Step 2: Calculate understock days for classification
    SELECT
        i.store_region_id,
        i.product_id,
        COUNT(*) AS total_days,
        SUM(CASE WHEN (i.inventory_level - i.units_sold) < (s.avg_inv_minus_sales - s.stddev_inv_minus_sales) THEN 1 ELSE 0 END) AS understock_days
    FROM inventory i
    JOIN stats s ON i.store_region_id = s.store_region_id AND i.product_id = s.product_id
    GROUP BY i.store_region_id, i.product_id
),
classification AS (
    -- Step 3: Classify as Fast or Slow-moving
    SELECT
        s.store_region_id,
        s.product_id,
        s.avg_inventory,
        s.avg_sales,
        s.stddev_inv_minus_sales,
        udc.total_days,
        udc.understock_days,
        (udc.understock_days * 100.0 / udc.total_days) AS understock_percentage,
        CASE
            WHEN (udc.understock_days * 100.0 / udc.total_days) > 5 THEN 'Fast-selling'
            ELSE 'Slow-moving'
        END AS movement_type
    FROM stats s
    JOIN understock_days_calc udc ON s.store_region_id = udc.store_region_id AND s.product_id = udc.product_id
),
reorder_point_calc AS (
    -- Step 4: Calculate reorder point based on movement type
    SELECT
        c.store_region_id,
        c.product_id,
        c.avg_inventory,
        c.avg_sales,
        c.stddev_inv_minus_sales,
        c.movement_type,
        CASE
            WHEN c.movement_type = 'Fast-selling' THEN (c.avg_inventory - c.avg_sales)
            ELSE (c.avg_inventory - c.avg_sales - 0.5 * c.stddev_inv_minus_sales)
        END AS reorder_point
    FROM classification c
),
low_inventory_detection AS (
    -- Step 5: Compare current inventory with reorder point
    SELECT
        i.record_date,
        i.store_region_id,
        i.product_id,
        p.category,
        i.inventory_level,
        r.reorder_point,
        CASE
            WHEN i.inventory_level <= r.reorder_point THEN 'Low Inventory'
            ELSE 'Sufficient'
        END AS inventory_status
    FROM inventory i
    JOIN reorder_point_calc r ON i.store_region_id = r.store_region_id AND i.product_id = r.product_id
    JOIN products p ON i.product_id = p.product_id
)
SELECT
    record_date,
    store_region_id,
    product_id,
    category,
    inventory_level,
    ROUND(reorder_point, 2) AS reorder_point,
    inventory_status
FROM low_inventory_detection
ORDER BY record_date, store_region_id, product_id;


-- Inventory Turnover Analysis
WITH avg_price AS (
    SELECT product_id, AVG(price) AS avg_price
    FROM pricing
    GROUP BY product_id
)
SELECT 
    i.product_id,
    p.category,
    ROUND(SUM(i.units_sold * ap.avg_price), 2) AS approx_cogs,
    ROUND(AVG(i.inventory_level), 2) AS avg_inventory,
    ROUND(SUM(i.units_sold * ap.avg_price) / NULLIF(AVG(i.inventory_level), 0), 2) AS inventory_turnover_ratio
FROM inventory i
JOIN avg_price ap ON i.product_id = ap.product_id
JOIN products p ON i.product_id = p.product_id
GROUP BY i.product_id, p.category
ORDER BY inventory_turnover_ratio DESC;




-- Regional Inventory Summary
WITH region_aggregates AS (
    SELECT
        s.region,
        COUNT(DISTINCT i.product_id) AS distinct_products,
        SUM(i.inventory_level) AS total_inventory,
        SUM(i.units_sold) AS total_units_sold,
        AVG(i.inventory_level) AS avg_inventory_per_product,
        AVG(i.units_sold) AS avg_sales_per_product
    FROM inventory i
    JOIN stores s ON i.store_region_id = s.store_region_id
    GROUP BY s.region
),
stockout_data AS (
    WITH threshold_calc AS (
        SELECT
            s.region,
            i.product_id,
            AVG(i.inventory_level - i.units_sold) AS avg_inv_minus_sales,
            STDDEV(i.inventory_level - i.units_sold) AS stddev_inv_minus_sales,
            (AVG(i.inventory_level - i.units_sold) - STDDEV(i.inventory_level - i.units_sold)) AS stockout_threshold
        FROM inventory i
        JOIN stores s ON i.store_region_id = s.store_region_id
        GROUP BY s.region, i.product_id
    ),
    daily_stockout AS (
        SELECT
            s.region,
            i.record_date,
            i.product_id,
            (i.inventory_level - i.units_sold) AS inv_minus_sales,
            t.stockout_threshold,
            CASE 
                WHEN (i.inventory_level - i.units_sold) < t.stockout_threshold THEN 1 
                ELSE 0 
            END AS is_stockout
        FROM inventory i
        JOIN stores s ON i.store_region_id = s.store_region_id
        JOIN threshold_calc t ON s.region = t.region AND i.product_id = t.product_id
    )
    SELECT
        region,
        COUNT(*) AS total_records,
        SUM(is_stockout) AS total_stockout_days,
        ROUND(SUM(is_stockout) * 100.0 / COUNT(*), 2) AS stockout_rate_percentage
    FROM daily_stockout
    GROUP BY region
)
SELECT
    r.region,
    r.distinct_products,
    r.total_inventory,
    r.total_units_sold,
    ROUND(r.avg_inventory_per_product, 2) AS avg_inventory_per_product,
    ROUND(r.avg_sales_per_product, 2) AS avg_sales_per_product,
    s.total_stockout_days,
    s.total_records,
    s.stockout_rate_percentage
FROM region_aggregates r
JOIN stockout_data s ON r.region = s.region
ORDER BY r.region;



-- summary
WITH threshold_calc AS (
    SELECT
        store_region_id,
        product_id,
        AVG(inventory_level - units_sold) AS avg_inv_minus_sales,
        STDDEV(inventory_level - units_sold) AS stddev_inv_minus_sales,
        AVG(inventory_level) AS avg_inventory_level,
        AVG(units_sold) AS avg_daily_sales,
        (AVG(inventory_level - units_sold) - STDDEV(inventory_level - units_sold)) AS stockout_threshold
    FROM inventory
    GROUP BY store_region_id, product_id
),
daily_stockout AS (
    SELECT
        i.record_date,
        i.store_region_id,
        i.product_id,
        (i.inventory_level - i.units_sold) AS inv_minus_sales,
        t.stockout_threshold,
        CASE 
            WHEN (i.inventory_level - i.units_sold) < t.stockout_threshold THEN 1 
            ELSE 0 
        END AS is_stockout
    FROM inventory i
    JOIN threshold_calc t ON i.store_region_id = t.store_region_id AND i.product_id = t.product_id
),
stockout_summary AS (
    SELECT
        ds.store_region_id,
        ds.product_id,
        p.category,
        COUNT(*) AS total_days,
        SUM(ds.is_stockout) AS stockout_days,
        ROUND(SUM(ds.is_stockout) * 100.0 / COUNT(*), 2) AS stockout_rate_percentage,
        t.avg_inventory_level,
        t.avg_daily_sales,
        CASE 
            WHEN t.avg_daily_sales > 0 THEN ROUND((t.avg_inventory_level / t.avg_daily_sales), 2)
            ELSE NULL
        END AS estimated_inventory_age_days
    FROM daily_stockout ds
    JOIN threshold_calc t ON ds.store_region_id = t.store_region_id AND ds.product_id = t.product_id
    JOIN products p ON ds.product_id = p.product_id
    GROUP BY ds.store_region_id, ds.product_id, p.category, t.avg_inventory_level, t.avg_daily_sales
)
-- Final KPI Report
SELECT *
FROM stockout_summary
ORDER BY store_region_id, product_id;


-- =====================================================
-- SEASONAL DEMAND FORECASTING ANALYSIS
-- =====================================================

WITH seasonal_performance AS (
    SELECT 
        i.store_region_id,
        s.seasonality,
        p.category,
        MONTH(i.record_date) AS month_num,
        MONTHNAME(i.record_date) AS month_name,
        SUM(i.units_sold) AS total_sales,
        SUM(i.demand_forecast) AS total_forecast,
        COUNT(*) AS data_points
    FROM inventory i
    JOIN products p ON i.product_id = p.product_id
    JOIN seasonality s ON i.product_id = s.product_id
    GROUP BY i.store_region_id, s.seasonality, p.category, MONTH(i.record_date), MONTHNAME(i.record_date)
),
seasonal_stats AS (
    SELECT 
        store_region_id,
        seasonality,
        category,
        AVG(total_sales) AS avg_monthly_sales,
        MAX(total_sales) AS peak_sales,
        MIN(total_sales) AS trough_sales,
        STDDEV(total_sales) AS sales_volatility,
        -- Forecast statistics
        AVG(total_forecast) AS avg_monthly_forecast,
        MAX(total_forecast) AS peak_forecast,
        MIN(total_forecast) AS trough_forecast,
        STDDEV(total_forecast) AS forecast_volatility
    FROM seasonal_performance
    GROUP BY store_region_id, seasonality, category
)
SELECT 
    sp.store_region_id,
    sp.category,
    sp.seasonality,
    sp.month_name,
    sp.total_sales,
    sp.total_forecast,
    ROUND(ss.avg_monthly_sales, 2) AS avg_monthly_sales,
    ROUND(ss.avg_monthly_forecast, 2) AS avg_monthly_forecast,
    ss.peak_sales,
    ss.peak_forecast,
    ss.trough_sales,
    ss.trough_forecast,
    ROUND(ss.sales_volatility, 2) AS sales_volatility,
    ROUND(ss.forecast_volatility, 2) AS forecast_volatility,
    
    -- Forecast Accuracy Metrics
    ROUND(ABS(sp.total_sales - sp.total_forecast), 2) AS absolute_forecast_error,
    ROUND(ABS(sp.total_sales - sp.total_forecast) / NULLIF(sp.total_sales, 0) * 100, 2) AS absolute_percentage_error,
    
    -- Performance Categories
    CASE 
        WHEN sp.total_sales = ss.peak_sales THEN 'PEAK MONTH'
        WHEN sp.total_sales = ss.trough_sales THEN 'TROUGH MONTH'
        WHEN sp.total_sales > ss.avg_monthly_sales THEN 'Above Average'
        ELSE 'Below Average'
    END AS sales_performance_category,
    
    CASE 
        WHEN sp.total_forecast = ss.peak_forecast THEN 'PEAK FORECAST'
        WHEN sp.total_forecast = ss.trough_forecast THEN 'TROUGH FORECAST'
        WHEN sp.total_forecast > ss.avg_monthly_forecast THEN 'Above Avg Forecast'
        ELSE 'Below Avg Forecast'
    END AS forecast_performance_category,
    
    -- Variance Analysis
    ROUND(((sp.total_sales - ss.avg_monthly_sales) / NULLIF(ss.avg_monthly_sales, 0)) * 100, 2) AS sales_variance_from_average,
    ROUND(((sp.total_forecast - ss.avg_monthly_forecast) / NULLIF(ss.avg_monthly_forecast, 0)) * 100, 2) AS forecast_variance_from_average,
    
    -- Forecast Quality Assessment
    CASE 
        WHEN ABS((sp.total_sales - sp.total_forecast) / NULLIF(sp.total_sales, 0)) * 100 < 5 THEN 'Excellent Forecast'
        WHEN ABS((sp.total_sales - sp.total_forecast) / NULLIF(sp.total_sales, 0)) * 100 < 10 THEN 'Good Forecast'
        WHEN ABS((sp.total_sales - sp.total_forecast) / NULLIF(sp.total_sales, 0)) * 100 < 20 THEN 'Fair Forecast'
        WHEN ABS((sp.total_sales - sp.total_forecast) / NULLIF(sp.total_sales, 0)) * 100 < 30 THEN 'Poor Forecast'
        ELSE 'Very Poor Forecast'
    END AS forecast_accuracy_rating,
    
    -- Bias Detection
    CASE 
        WHEN sp.total_forecast > sp.total_sales * 1.1 THEN 'Over-Forecasted'
        WHEN sp.total_forecast < sp.total_sales * 0.9 THEN 'Under-Forecasted'
        ELSE 'Well-Calibrated'
    END AS forecast_bias,
    
    -- Store Region Performance Rating
    CASE 
        WHEN sp.total_sales > ss.avg_monthly_sales * 1.2 THEN 'High Performing Region'
        WHEN sp.total_sales > ss.avg_monthly_sales THEN 'Good Performing Region'
        WHEN sp.total_sales > ss.avg_monthly_sales * 0.8 THEN 'Average Performing Region'
        ELSE 'Low Performing Region'
    END AS region_performance_rating,
    
    -- Next Month Prediction (Simple trend-based)
    ROUND(sp.total_sales + ((sp.total_sales - LAG(sp.total_sales) OVER (
        PARTITION BY sp.store_region_id, sp.seasonality, sp.category 
        ORDER BY sp.month_num
    )) * 0.5), 2) AS trend_based_next_month_prediction
    
FROM seasonal_performance sp
JOIN seasonal_stats ss ON sp.store_region_id = ss.store_region_id 
                      AND sp.seasonality = ss.seasonality 
                      AND sp.category = ss.category
ORDER BY sp.store_region_id, sp.seasonality, sp.category, sp.month_num;


-- Stock Adjustment Recommendations for Inventory Optimization
WITH stats AS (
    SELECT 
        store_region_id,
        product_id,
        (AVG(inventory_level - units_sold) - 1.3 * STDDEV(inventory_level - units_sold)) AS threshold,
        AVG(inventory_level) AS avg_inventory,
        AVG(units_sold) AS avg_daily_sales,
        STDDEV(units_sold) AS stddev_sales
    FROM inventory
    GROUP BY store_region_id, product_id
),

-- Calculate understock frequency for classification
daily_understock AS (
    SELECT 
        i.record_date,
        i.store_region_id,
        i.product_id,
        (i.inventory_level - i.units_sold) AS inv_minus_sales,
        s.threshold,
        CASE 
            WHEN (i.inventory_level - i.units_sold) < s.threshold THEN 1 
            ELSE 0 
        END AS is_understock
    FROM inventory i
    JOIN stats s ON i.store_region_id = s.store_region_id AND i.product_id = s.product_id
),

understock_counts AS (
    SELECT 
        store_region_id,
        product_id,
        COUNT(*) AS total_days,
        SUM(is_understock) AS understock_days,
        (SUM(is_understock) * 100.0 / COUNT(*)) AS understock_percentage
    FROM daily_understock
    GROUP BY store_region_id, product_id
),

-- Product classification with movement type
fast_slow_classification AS (
    SELECT 
        uc.store_region_id,
        uc.product_id,
        uc.understock_percentage,
        s.avg_inventory,
        s.avg_daily_sales,
        s.stddev_sales,
        CASE 
            WHEN uc.understock_percentage > 10 THEN 'Fast-selling'
            ELSE 'Slow-moving'
        END AS product_movement
    FROM understock_counts uc
    JOIN stats s ON uc.store_region_id = s.store_region_id AND uc.product_id = s.product_id
),

-- Calculate holding costs
product_holding_cost AS (
    SELECT
        i.product_id,
        i.store_region_id,
        s.seasonality,
        AVG(i.inventory_level) AS avg_inventory,
        AVG(pr.price) AS avg_price,
        (AVG(i.inventory_level) * AVG(pr.price)) AS holding_cost
    FROM inventory i
    JOIN products p ON i.product_id = p.product_id
    JOIN seasonality s ON i.product_id = s.product_id
    JOIN pricing pr ON i.store_region_id = pr.store_region_id 
                   AND i.product_id = pr.product_id 
                   AND i.record_date = pr.record_date
    GROUP BY i.product_id, i.store_region_id, s.seasonality
),

-- Calculate safety stock based on sales variability
safety_stock_calc AS (
    SELECT 
        fsc.store_region_id,
        fsc.product_id,
        fsc.product_movement,
        fsc.avg_inventory,
        fsc.avg_daily_sales,
        fsc.stddev_sales,
        -- Safety stock = 1.65 * stddev * sqrt(lead_time) assuming 7-day lead time
        GREATEST(1.65 * fsc.stddev_sales * SQRT(7), fsc.avg_daily_sales * 3) AS safety_stock,
        -- Optimal stock level based on movement type
        CASE 
            WHEN fsc.product_movement = 'Fast-selling' THEN 
               fsc.avg_daily_sales  + 1.5*fsc.stddev_sales
            ELSE 
                fsc.avg_daily_sales  + 0.5*fsc.stddev_sales
        END AS optimal_stock_level
    FROM fast_slow_classification fsc
),

-- Final recommendations
stock_recommendations AS (
    SELECT
        fsc.store_region_id,
        fsc.product_id,
        p.category,
        phc.seasonality,
        fsc.product_movement,
        ROUND(fsc.avg_inventory, 2) AS current_avg_inventory,
        ROUND(fsc.avg_daily_sales, 2) AS avg_daily_sales,
        ROUND(phc.holding_cost, 2) AS holding_cost,
        ROUND(ssc.optimal_stock_level, 2) AS recommended_stock_level,
        ROUND(ssc.optimal_stock_level - fsc.avg_inventory, 2) AS stock_adjustment,
        ROUND(fsc.understock_percentage, 2) AS understock_percentage,
        
        -- Recommendation logic
        CASE 
            WHEN fsc.product_movement = 'Slow-moving' AND phc.holding_cost > 1000 THEN
                CONCAT('REDUCE: High holding cost slow-mover. Reduce by ', 
                       ROUND(GREATEST(fsc.avg_inventory * 0.3, fsc.avg_inventory - ssc.optimal_stock_level), 0), 
                       ' units to optimize costs')
            
            WHEN fsc.product_movement = 'Slow-moving' AND phc.holding_cost <= 1000 THEN
                CONCAT('MAINTAIN: Low-cost slow-mover. Current level acceptable, monitor sales trends')
            
            WHEN fsc.product_movement = 'Fast-selling' AND fsc.avg_inventory < ssc.optimal_stock_level THEN
                CONCAT('INCREASE: Fast-seller understocked. Increase by ', 
                       ROUND(ssc.optimal_stock_level - fsc.avg_inventory, 0), 
                       ' units to prevent stockouts')
            
            WHEN fsc.product_movement = 'Fast-selling' AND fsc.avg_inventory >= ssc.optimal_stock_level THEN
                CONCAT('OPTIMIZE: Fast-seller well-stocked. Fine-tune to ', 
                       ROUND(ssc.optimal_stock_level, 0), 
                       ' units for efficiency')
            
            ELSE 'REVIEW: Analyze sales pattern and adjust accordingly'
        END AS recommendation,
        
        -- Priority scoring (higher = more urgent)
        CASE 
            WHEN fsc.product_movement = 'Slow-moving' AND phc.holding_cost > 1000 THEN 5
            WHEN fsc.product_movement = 'Fast-selling' AND fsc.understock_percentage > 15 THEN 4
            WHEN fsc.product_movement = 'Fast-selling' AND fsc.avg_inventory < ssc.optimal_stock_level THEN 3
            WHEN fsc.product_movement = 'Slow-moving' AND phc.holding_cost > 500 THEN 2
            ELSE 1
        END AS priority_score,
        
        -- Estimated cost impact
        CASE 
            WHEN fsc.product_movement = 'Slow-moving' AND phc.holding_cost > 1000 THEN
                ROUND(GREATEST(fsc.avg_inventory * 0.3, fsc.avg_inventory - ssc.optimal_stock_level) * phc.avg_price * 0.25, 2)
            WHEN fsc.product_movement = 'Fast-selling' AND fsc.avg_inventory < ssc.optimal_stock_level THEN
                ROUND((ssc.optimal_stock_level - fsc.avg_inventory) * phc.avg_price * 0.1, 2)
            ELSE 0
        END AS estimated_cost_impact
        
    FROM fast_slow_classification fsc
    JOIN product_holding_cost phc ON fsc.product_id = phc.product_id 
                                 AND fsc.store_region_id = phc.store_region_id
    JOIN safety_stock_calc ssc ON fsc.store_region_id = ssc.store_region_id 
                              AND fsc.product_id = ssc.product_id
    JOIN products p ON fsc.product_id = p.product_id
)

-- Final output with actionable recommendations
SELECT 
    store_region_id,
    product_id,
    category,
    product_movement,
    current_avg_inventory,
    recommended_stock_level,
    stock_adjustment,
    holding_cost,
    understock_percentage,
    recommendation,
    priority_score,
    estimated_cost_impact
    
    
FROM stock_recommendations
ORDER BY priority_score DESC, holding_cost DESC, store_region_id, product_id;

