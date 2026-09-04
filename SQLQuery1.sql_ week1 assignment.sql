create database Voltkart;
use Voltkart;


select COUNT(*) FROM dbo.dim_category; --26
select COUNT(*) FROM dbo.dim_customer; --2000
select COUNT(*) FROM dbo.dim_employee;--58
select COUNT(*) FROM dbo.dim_product;--400
select COUNT(*) FROM dbo.fact_order_items;--56825
select COUNT(*) FROM dbo.fact_orders;--30000
select COUNT(*) FROM dbo.stg_orders_incr;--800
select COUNT(*) FROM dbo.cdc_product_changes;--35

--Question 1
SELECT TOP 20
    o.order_id,
    o.order_date,
    c.customer_name,
    e.employee_name AS sales_rep_name,
    o.order_total
FROM dbo.fact_orders AS o
INNER JOIN dim_customer AS c
    ON c.customer_id = o.customer_id
INNER JOIN dim_employee AS e
    ON o.sales_rep_id = e.employee_id
WHERE o.order_status = 'Completed'
ORDER BY o.order_total DESC;

---question 2
SELECT
    c.customer_id,
    c.customer_name,
    c.signup_date
FROM dim_customer AS c
WHERE NOT EXISTS (
    SELECT 1
    FROM fact_orders AS o
    WHERE c.customer_id = o.customer_id
)
ORDER BY c.customer_id;



---question 3
WITH ProductRevenue AS (
    SELECT
        cat.category_name,
        p.product_name,
        SUM(i.line_amount) AS total_revenue
    FROM fact_order_items AS i
    INNER JOIN dim_product AS p
        ON p.product_id = i.product_id
    INNER JOIN dim_category AS cat
        ON cat.category_id = p.category_id
    INNER JOIN fact_orders AS o
        ON o.order_id = i.order_id
    WHERE o.order_status = 'Completed'
    GROUP BY
        cat.category_name,
        p.product_name
),
RankedProducts AS (
    SELECT
        category_name,
        product_name,
        total_revenue,
        RANK() OVER (
            PARTITION BY category_name
            ORDER BY total_revenue DESC
        ) AS revenue_rank
    FROM ProductRevenue
)
SELECT
    category_name,
    product_name,
    total_revenue,
    revenue_rank
FROM RankedProducts
WHERE revenue_rank <= 3
ORDER BY
    category_name,
    revenue_rank;


--question 4
WITH MonthlyRevenue AS (
    SELECT
        CONVERT(VARCHAR(7), order_date, 126) AS order_month,
        SUM(order_total) AS monthly_revenue
    FROM fact_orders
    WHERE order_status = 'Completed'
    GROUP BY
        CONVERT(VARCHAR(7), order_date, 126)
),
PreviousRevenue AS (
    SELECT
        order_month,
        monthly_revenue,
        LAG(monthly_revenue) OVER (
            ORDER BY order_month
        ) AS previous_month_revenue
    FROM MonthlyRevenue
)
SELECT
    order_month,
    monthly_revenue,
    previous_month_revenue,
    ROUND(
        (monthly_revenue - previous_month_revenue)
        * 100.0 / NULLIF(previous_month_revenue, 0),
        2
    ) AS mom_pct_change
FROM PreviousRevenue
ORDER BY order_month;

---question 5

WITH customerspend AS (
    SELECT
        customer_id,
        SUM(order_total) AS lifetime_spend
    FROM fact_orders
    WHERE order_status = 'Completed'
    GROUP BY customer_id
),

quartiles AS (
    SELECT
        customer_id,
        lifetime_spend,
        NTILE(4) OVER (
            ORDER BY lifetime_spend
        ) AS quartile_spend
    FROM customerspend
)

SELECT
    quartile_spend,
    COUNT(*) AS customer_count,
    AVG(lifetime_spend) AS avg_lifetime_spend
FROM quartiles
GROUP BY quartile_spend
ORDER BY quartile_spend;


--question 6

WITH CategoryTree AS
(
    
    SELECT
        category_id,
        category_name,
        parent_category_id,
        0 AS depth_level,
        CAST(category_name AS NVARCHAR(MAX)) AS category_path
    FROM dim_category
    WHERE category_name = 'Computers'

    UNION ALL

   
    SELECT
        c.category_id,
        c.category_name,
        c.parent_category_id,
        ct.depth_level + 1 AS depth_level,
        CAST(ct.category_path + ' > ' + c.category_name AS NVARCHAR(MAX)) AS category_path
    FROM dim_category c
    INNER JOIN CategoryTree ct
        ON c.parent_category_id = ct.category_id
)

SELECT
    category_id,
    category_name,
    depth_level,
    category_path
FROM CategoryTree
ORDER BY category_path
OPTION (MAXRECURSION 100);

--question 7
WITH employeetree AS
(
    
    SELECT
        employee_id AS root_emp_id,
        employee_id,
        employee_name,
        role,
        0 AS depth_level
    FROM dim_employee

    UNION ALL

    
    SELECT
        et.root_emp_id,
        e.employee_id,
        e.employee_name,
        e.role,
        et.depth_level + 1 AS depth_level
    FROM employeetree AS et
    INNER JOIN dim_employee AS e
        ON e.manager_id = et.employee_id
),

teamrevenue AS
(
    SELECT
        et.root_emp_id,
        SUM(o.order_total) AS team_total_revenue
    FROM employeetree AS et
    LEFT JOIN fact_orders AS o
        ON et.employee_id = o.sales_rep_id
        AND o.order_status = 'Completed'
    GROUP BY
        et.root_emp_id
)

SELECT
    e.employee_id,
    e.employee_name,
    e.role,
    COALESCE(tr.team_total_revenue, 0) AS team_total_revenue
FROM dim_employee AS e
LEFT JOIN teamrevenue AS tr
    ON e.employee_id = tr.root_emp_id
ORDER BY e.employee_id
OPTION (MAXRECURSION 100);


---question 8

MERGE INTO fact_orders AS tgt
USING stg_orders_incr AS src
ON tgt.order_id = src.order_id

WHEN MATCHED AND
(
    ISNULL(tgt.customer_id, '') <> ISNULL(src.customer_id, '')
    OR ISNULL(tgt.order_date, '') <> ISNULL(src.order_date, '')
    OR ISNULL(tgt.sales_rep_id, '') <> ISNULL(src.sales_rep_id, '')
    OR ISNULL(tgt.order_status, '') <> ISNULL(src.order_status, '')
    OR ISNULL(tgt.order_total, 0) <> ISNULL(src.order_total, 0)
)
THEN
    UPDATE SET
        tgt.customer_id = src.customer_id,
        tgt.order_date = src.order_date,
        tgt.sales_rep_id = src.sales_rep_id,
        tgt.order_status = src.order_status,
        tgt.order_total = src.order_total

WHEN NOT MATCHED BY TARGET
THEN
    INSERT
    (
        order_id,
        customer_id,
        order_date,
        sales_rep_id,
        order_status,
        order_total
    )
    VALUES
    (
        src.order_id,
        src.customer_id,
        src.order_date,
        src.sales_rep_id,
        src.order_status,
        src.order_total
    );




    select * from fact_orders order by order_id;

---question 9
MERGE INTO dim_product AS tgt
USING cdc_product_changes AS src
ON tgt.product_id = src.product_id

WHEN MATCHED AND src.operation = 'U'
THEN
    UPDATE SET
        tgt.product_name = src.product_name,
        tgt.category_id = src.category_id,
        tgt.unit_price = src.unit_price,
        tgt.unit_cost = src.unit_cost,
        tgt.launch_date = src.launch_date

WHEN MATCHED AND src.operation = 'D'
THEN
    DELETE

WHEN NOT MATCHED BY TARGET
     AND src.operation = 'I'
THEN
    INSERT
    (
        product_id,
        product_name,
        category_id,
        unit_price,
        unit_cost,
        launch_date
    )
    VALUES
    (
        src.product_id,
        src.product_name,
        src.category_id,
        src.unit_price,
        src.unit_cost,
        src.launch_date
    );


---question 10

SELECT
    name,
    type_desc
FROM sys.indexes
WHERE object_id = OBJECT_ID('fact_order_items');

SELECT
    name,
    type_desc
FROM sys.indexes
WHERE object_id = OBJECT_ID('fact_orders');

DROP INDEX IX_fact_order_items_order_id
ON fact_order_items;

CREATE INDEX IX_fact_order_items_order_id
ON fact_order_items (order_id)
INCLUDE (line_amount);

DROP INDEX IX_fact_orders_order_date_customer
ON fact_orders;

CREATE INDEX IX_fact_orders_order_date_customer
ON fact_orders (order_date, customer_id)
INCLUDE (order_id);

WITH Orders2024 AS
(
    SELECT
        customer_id,
        COUNT(*) AS orders_2024
    FROM fact_orders
    WHERE order_date >= '20240101'
      AND order_date < '20250101'
    GROUP BY customer_id
),
LifetimeValue AS
(
    SELECT
        o.customer_id,
        SUM(oi.line_amount) AS lifetime_value
    FROM fact_orders AS o
    INNER JOIN fact_order_items AS oi
        ON o.order_id = oi.order_id
    GROUP BY o.customer_id
)
SELECT
    o.customer_id,
    o.orders_2024,
    l.lifetime_value
FROM Orders2024 AS o
INNER JOIN LifetimeValue AS l
    ON l.customer_id = o.customer_id;


---question 11
WITH activemonths AS
(
    SELECT DISTINCT
        customer_id,
        DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS active_month
    FROM fact_orders
    WHERE order_status = 'Completed'
),

numberedmonths AS
(
    SELECT
        customer_id,
        active_month,
        DATEDIFF(MONTH, '2000-01-01', active_month)
        -
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY active_month
        ) AS streak_group
    FROM activemonths
),

streaks AS
(
    SELECT
        customer_id,
        streak_group,
        COUNT(*) AS streak_months
    FROM numberedmonths
    GROUP BY
        customer_id,
        streak_group
),

longeststreak AS
(
    SELECT
        customer_id,
        MAX(streak_months) AS longest_streak_months
    FROM streaks
    GROUP BY customer_id
)

SELECT
    c.customer_id,
    c.customer_name,
    ls.longest_streak_months
FROM dim_customer AS c
INNER JOIN longeststreak AS ls
    ON c.customer_id = ls.customer_id
ORDER BY c.customer_id;
















