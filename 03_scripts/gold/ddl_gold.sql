/*
===============================================================================
Title:          Gold Layer Views Initialization
===============================================================================

Purpose:
    Create the Gold Layer views in the DataWarehouse database to provide
    business-ready dimensions and fact data for reporting and analytics.

Note:
    - Existing views are dropped before recreation.
    - The Gold Layer follows a Star Schema structure, consisting of
      dimension views and a fact view.
    - Dimension views combine and enrich data from the Silver Layer tables.
    - The customer_key and product_key columns generate surrogate keys
      using ROW_NUMBER().
    - The product dimension includes only currently active products.
    - The fact view connects sales transactions to customer and product
      dimensions using their business keys.

Target:
    DataWarehouse -> Gold Schema

Views Created:
    - gold.dim_customers
    - gold.dim_products
    - gold.fact_sales

===============================================================================
*/

USE DataWarehouse;
GO

IF OBJECT_ID ('gold.dim_customer', 'U') IS NOT NULL
	DROP VIEW gold.dim_customers;
GO

CREATE VIEW gold.dim_customers AS (
	SELECT
		ROW_NUMBER() OVER (ORDER BY ci.cst_id ASC) AS customer_key,
		ci.cst_id AS customer_id,
		ci.cst_key AS customer_number,
		ci.cst_firstname AS first_name,
		ci.cst_lastname AS last_name,
		la.cntry AS country,
		ci.cst_marital_status AS marital_status,
		CASE
			WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr
			ELSE COALESCE(ca.gen, 'n/a')
		END AS gender,
		ca.bdate AS birth_date,
		ci.cst_create_date AS create_date
	FROM silver.crm_cust_info ci
	LEFT JOIN silver.erp_cust_az12 ca
	ON		  ci.cst_key = ca.cid
	LEFT JOIN silver.erp_loc_a101 la
	ON		  ci.cst_key = la.cid
);
GO

IF OBJECT_ID ('gold.dim_products', 'U') IS NOT NULL
	DROP VIEW gold.dim_products;
GO

CREATE VIEW gold.dim_products AS (
	SELECT
		ROW_NUMBER() OVER (ORDER BY pi.prd_start_dt, pi.prd_key) AS product_key,
		pi.prd_id AS product_id,
		pi.prd_key AS product_number,
		pi.prd_nm AS product_name,
		pi.cat_id AS category_id,
		pc.cat AS category,
		pc.subcat AS subcategory,
		pc.maintenance,
		pi.prd_cost AS cost,
		pi.prd_line AS product_line,
		pi.prd_start_dt AS start_date
	FROM silver.crm_prd_info pi
	LEFT JOIN silver.erp_px_cat_g1v2 pc
	ON		  pi.cat_id = pc.id
	WHERE pi.prd_end_dt IS NULL
);
GO

IF OBJECT_ID ('gold.fact_sales', 'U') IS NOT NULL
	DROP VIEW gold.fact_sales;
GO

CREATE VIEW gold.fact_sales AS (
	SELECT
		sd.sls_ord_num AS order_number,
		dp.product_key,
		dc.customer_key,
		sd.sls_order_dt AS order_date,
		sd.sls_ship_dt AS ship_date,
		sd.sls_due_dt AS due_date,
		sd.sls_sales AS sales_amount,
		sd.sls_quantity AS quantity,
		sd.sls_price AS price
	FROM silver.crm_sales_details sd
	LEFT JOIN gold.dim_customers dc
	ON		  sd.sls_cust_id = dc.customer_id
	LEFT JOIN gold.dim_products dp
	ON        sd.sls_prd_key = dp.product_number
);
GO