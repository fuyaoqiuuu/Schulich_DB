-- TWO ASSUMPTIONS/VALIDATION ABOUT THE DATASETS BEFORE THE OFFICIAL QUERY

-- EVERY ORDER ONLY HAS 1 PRODUCT
SELECT
    order_number,
    COUNT(DISTINCT fk_product) AS unique_products_count
FROM
    fact_tables.orders
GROUP BY
    order_number
HAVING
    COUNT(DISTINCT fk_product) > 0;

-- EVERY ORDER_ID ONLY HAS 1 order_number
SELECT
    order_id,
    COUNT(DISTINCT order_number) AS unique_order_number_count
FROM
    fact_tables.orders
GROUP BY
    order_id,order_number
HAVING
    COUNT(DISTINCT order_number) > 1;


----------------------------------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS customer360;

-- 1. Create the structured table under your schema
CREATE TABLE IF NOT EXISTS customer360.output_table (
    customer_id INT,
    first_name VARCHAR(255),
    last_name VARCHAR(255),
    conversion_id INT,
    conversion_number INT,
    conversion_type VARCHAR(255),
    conversion_date DATE,
    conversion_week VARCHAR(255),
    next_conversion_week VARCHAR(255),
    conversion_channel VARCHAR(255),
    first_order_week VARCHAR(255),
    first_order_total_paid DECIMAL(18,2),
    week_counter INT,
    order_week VARCHAR(255),
    orders_placed INT,
    total_before_discounts DECIMAL(18,2),
    total_discounts DECIMAL(18,2),
    total_paid_in_week DECIMAL(18,2),
    conversion_cumulative_revenue DECIMAL(18,2),
    lifetime_cumulative_revenue DECIMAL(18,2)
);



-- 2. Completely wipe all existing data out of the original table
TRUNCATE TABLE customer360.output_table;

-- 3. Insert query results into it
--CTE 1: Static Customer/Conversion Data as bass
WITH conversion_base AS (
    select cd.customer_id,
           cd.first_name,
           cd.last_name,
           cs.conversion_id,
           -- window functions to sequence the orders of each conversion
           row_number() over (partition by cd.customer_id order by cs.conversion_date ASC) as conversion_numer,
           cs.conversion_type,
           cs.conversion_date,
           dd.year_week as conversion_week,
           -- Use window functions to find the next conversion week
           lead(dd.year_week,1,null) over (partition by cd.customer_id order by cs.conversion_date) as next_conversion_week,
           cs.conversion_channel,
           cs.order_number
    from fact_tables.conversions as cs
    RIGHT JOIN dimensions.customer_dimension as cd
        ON cs.fk_customer = cd.sk_customer
    LEFT JOIN dimensions.date_dimension AS dd
        ON cs.fk_conversion_date = dd.sk_date
    ),

-- CTE 2: first ever order placed *per conversion*
first_orders AS (
    SELECT cb.conversion_id,
           cb.order_number,
-- no need to aggregate by conversion_id? i.e. 1 conversion to 1 order to 1 product?
            dd.year_week AS first_order_week,
            o.price_paid AS first_order_total_paid
    FROM conversion_base AS cb
          INNER JOIN fact_tables.orders AS o
                     ON cb.order_number = o.order_number
          INNER JOIN dimensions.date_dimension AS dd
                     ON o.fk_order_date = dd.sk_date
    ),

-- CTE 3:Pre-aggregate weekly order history to avoid fan-out when joining
aggregated_weekly_order AS (
    SELECT o.fk_customer,
           cd.customer_id,
           dd.year_week          AS order_week,
           COUNT(o.order_number) AS orders_count,
           SUM(o.unit_price)     AS total_before_discounts,
           SUM(o.discount_value) AS total_discounts,
           SUM(o.price_paid)     AS total_paid_in_week
    FROM fact_tables.orders AS o
             LEFT JOIN dimensions.date_dimension AS dd
                       ON o.fk_order_date = dd.sk_date
             LEFT JOIN dimensions.customer_dimension AS cd
                       ON O.fk_customer = cd.sk_customer
    GROUP BY o.fk_customer, cd.customer_id, DD.year_week
    ),

-- CTE 4: Spine generation (create a row for each week between conversion and next_conversion)
weekly_spine AS (
    SELECT cb.*,
            dd.year_week                                                         AS order_week,
            -- Generate a sequence counter starting from 1 for each conversion period
            ROW_NUMBER() OVER (PARTITION BY conversion_id ORDER BY dd.year_week) AS week_counter,
            ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY dd.year_week)   AS lifetime_week_counter
     FROM conversion_base AS cb
              LEFT JOIN (SELECT DISTINCT year_week FROM dimensions.date_dimension) AS dd
                        ON dd.year_week >= cb.conversion_week
     WHERE (dd.year_week < cb.next_conversion_week OR cb.next_conversion_week IS NULL)
     ),

-- Final CTE 5: Combine everything and compute running totals
final_table AS (
    SELECT
        ws.customer_id,
        ws.first_name,
        ws.last_name,
        ws.conversion_id,
        ws.conversion_numer,
        ws.conversion_type,
        ws.conversion_date,
        ws.conversion_week,
        next_conversion_week,
        ws.conversion_channel,
        fo.first_order_week,
        fo.first_order_total_paid,
        ws.week_counter,
        ws.order_week,
        CASE WHEN  awo.orders_count > 0 THEN 1 ELSE 0 END AS orders_placed,
        COALESCE(awo.total_before_discounts, 0) AS total_before_discounts,
        COALESCE(awo.total_discounts, 0) AS total_discounts,
        COALESCE(awo.total_paid_in_week, 0) AS total_paid_in_week,

    -- Cumulative fields calculated using window functions over the generated spine
        SUM(COALESCE(awo.total_paid_in_week,0)) OVER(
            PARTITION BY ws.conversion_id
            ORDER BY ws.order_week
            ) AS conversion_cumulative_revenue,

        SUM(COALESCE(awo.total_paid_in_week,0)) OVER (
            PARTITION BY ws.customer_id
            ORDER BY WS.order_week
            ) AS lifetime_cumulative_revenue

    FROM weekly_spine AS ws
    LEFT JOIN first_orders AS fo
        ON ws.conversion_id = fo.conversion_id
    LEFT JOIN aggregated_weekly_order AS awo
        ON ws.customer_id = awo.customer_id AND ws.order_week = awo.order_week
        -- WHERE ws.customer_id = 333
    ORDER BY ws.customer_id, ws.conversion_id, ws.week_counter
    )
INSERT INTO customer360.output_table
SELECT * FROM final_table;







