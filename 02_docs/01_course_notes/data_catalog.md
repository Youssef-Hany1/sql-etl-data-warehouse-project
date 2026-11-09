# Gold Layer Data Catalog

## Overview

The Gold layer is the business-ready presentation layer of the `DataWarehouse` database. It is modeled as a **star schema** and exposed entirely through views in the `gold` schema. The views read from the cleaned Silver tables, so no data is physically stored in Gold.

| Object | Type | Role | Grain (one row per...) |
|---|---|---|---|
| `gold.dim_customers` | View | Dimension | Customer |
| `gold.dim_products` | View | Dimension | Currently active product |
| `gold.fact_sales` | View | Fact | Sales order line |

### Star schema relationships

```
gold.dim_customers (customer_key) 1 ──── * gold.fact_sales * ──── 1 (product_key) gold.dim_products
```

| Fact column | Dimension column | Cardinality |
|---|---|---|
| `fact_sales.customer_key` | `dim_customers.customer_key` | Many-to-one |
| `fact_sales.product_key` | `dim_products.product_key` | Many-to-one |

---

## 1. `gold.dim_customers`

**Purpose:** Customer dimension combining CRM customer master data with ERP demographic and location data. One row per customer.

**Grain:** One row per unique `cst_id` (CRM duplicates are already removed in Silver, keeping the latest record).

**Sources:**

| Silver table | Alias | Join | Contributes |
|---|---|---|---|
| `silver.crm_cust_info` | `ci` | Driving table | Customer identity, name, marital status, gender, create date |
| `silver.erp_cust_az12` | `ca` | `LEFT JOIN ci.cst_key = ca.cid` | Birth date, fallback gender |
| `silver.erp_loc_a101` | `la` | `LEFT JOIN ci.cst_key = la.cid` | Country |

### Columns

| Column | Data type | Description | Source / logic |
|---|---|---|---|
| `customer_key` | BIGINT | Surrogate key. Primary key of the dimension and the key used by the fact table. | `ROW_NUMBER() OVER (ORDER BY cst_id)` |
| `customer_id` | INT | Business customer ID from the CRM system. | `crm_cust_info.cst_id` |
| `customer_number` | NVARCHAR(50) | Alphanumeric customer code used to link CRM and ERP records. | `crm_cust_info.cst_key` |
| `first_name` | NVARCHAR(50) | Customer first name, trimmed. | `crm_cust_info.cst_firstname` |
| `last_name` | NVARCHAR(50) | Customer last name, trimmed. | `crm_cust_info.cst_lastname` |
| `country` | NVARCHAR(50) | Country of residence, standardized (e.g., `US`/`USA` become `United States`, `DE` becomes `Germany`). `n/a` if missing; NULL if there is no ERP location match. | `erp_loc_a101.cntry` |
| `marital_status` | NVARCHAR(50) | `Single`, `Married`, or `n/a` when unknown. | `crm_cust_info.cst_marital_status` (`S`/`M` decoded in Silver) |
| `gender` | NVARCHAR(50) | `Female`, `Male`, or `n/a`. CRM is the primary source; when CRM is `n/a`, the ERP value is used as a fallback. | `CASE WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr ELSE COALESCE(ca.gen, 'n/a') END` |
| `birth_date` | DATE | Date of birth. NULL if missing, if the future-dated source value was invalidated, or if there is no ERP match. | `erp_cust_az12.bdate` |
| `create_date` | DATE | Date the customer record was created in the CRM. | `crm_cust_info.cst_create_date` |

### Notes
- ERP customer IDs have the `NAS` prefix removed (Silver) and ERP location IDs have hyphens removed (Silver) so they match `cst_key`.
- Because the ERP tables are joined with `LEFT JOIN`, customers without ERP records are kept, with NULL `country` / `birth_date`.
- `customer_key` is regenerated each time the view is queried and can change if customers are added or removed. Do not persist it outside the warehouse as a stable identifier; use `customer_id` or `customer_number` for that.

---

## 2. `gold.dim_products`

**Purpose:** Product dimension combining CRM product master data with ERP category hierarchy. Contains **current products only**.

**Grain:** One row per active product (a product whose Silver `prd_end_dt` is NULL). Historical product versions are excluded.

**Sources:**

| Silver table | Alias | Join | Contributes |
|---|---|---|---|
| `silver.crm_prd_info` | `pi` | Driving table (filtered `prd_end_dt IS NULL`) | Product identity, cost, line, start date |
| `silver.erp_px_cat_g1v2` | `pc` | `LEFT JOIN pi.cat_id = pc.id` | Category, subcategory, maintenance flag |

### Columns

| Column | Data type | Description | Source / logic |
|---|---|---|---|
| `product_key` | BIGINT | Surrogate key. Primary key of the dimension and the key used by the fact table. | `ROW_NUMBER() OVER (ORDER BY prd_start_dt, prd_key)` |
| `product_id` | INT | Business product ID from the CRM system. | `crm_prd_info.prd_id` |
| `product_number` | NVARCHAR(50) | Product code, derived from the CRM product key with the 5-character category prefix removed. Used to match sales lines. | `crm_prd_info.prd_key` (substring from position 7 in Silver) |
| `product_name` | NVARCHAR(50) | Product name. | `crm_prd_info.prd_nm` |
| `category_id` | NVARCHAR(50) | Category code in ERP format (hyphen replaced by underscore). | `crm_prd_info.cat_id` |
| `category` | NVARCHAR(50) | Product category. NULL if there is no ERP category match. | `erp_px_cat_g1v2.cat` |
| `subcategory` | NVARCHAR(50) | Product subcategory. NULL if there is no ERP category match. | `erp_px_cat_g1v2.subcat` |
| `maintenance` | NVARCHAR(50) | Flag from the ERP indicating whether the product requires maintenance. | `erp_px_cat_g1v2.maintenance` |
| `cost` | INT | Product cost. Missing source values are defaulted to `0`. | `crm_prd_info.prd_cost` |
| `product_line` | NVARCHAR(50) | `Mountain`, `Road`, `Other Sales`, `Touring`, or `n/a`. | `crm_prd_info.prd_line` (`M`/`R`/`S`/`T` decoded in Silver) |
| `start_date` | DATE | Date the current product version became effective. | `crm_prd_info.prd_start_dt` |

### Notes
- The end date of each product version is calculated in Silver with `LEAD()` over `prd_start_dt` (next start date minus one day). The latest version has no end date, so it is the only one that passes the Gold filter.
- Sales rows for products that are no longer active will have a NULL `product_key` in `gold.fact_sales`.

---

## 3. `gold.fact_sales`

**Purpose:** Transactional fact view of sales, linking each order line to the customer and product dimensions through surrogate keys.

**Grain:** One row per sales order line from the CRM (`silver.crm_sales_details`).

**Sources:**

| Object | Alias | Join | Contributes |
|---|---|---|---|
| `silver.crm_sales_details` | `sd` | Driving table | Order, dates, and measures |
| `gold.dim_customers` | `dc` | `LEFT JOIN sd.sls_cust_id = dc.customer_id` | `customer_key` |
| `gold.dim_products` | `dp` | `LEFT JOIN sd.sls_prd_key = dp.product_number` | `product_key` |

### Columns

| Column | Data type | Role | Description | Source |
|---|---|---|---|---|
| `order_number` | NVARCHAR(50) | Degenerate dimension | Sales order identifier. | `sls_ord_num` |
| `product_key` | BIGINT | Foreign key | Surrogate key to `dim_products`. NULL if no active product matches. | `dim_products.product_key` |
| `customer_key` | BIGINT | Foreign key | Surrogate key to `dim_customers`. NULL if no customer matches. | `dim_customers.customer_key` |
| `order_date` | DATE | Date | Date the order was placed. NULL if the source date was invalid. | `sls_order_dt` |
| `ship_date` | DATE | Date | Date the order was shipped. NULL if the source date was invalid. | `sls_ship_dt` |
| `due_date` | DATE | Date | Date the payment/order was due. NULL if the source date was invalid. | `sls_due_dt` |
| `sales_amount` | INT | Measure | Total sales value of the line, equal to `quantity * price`. Recalculated in Silver when the source value was missing, non-positive, or inconsistent. | `sls_sales` |
| `quantity` | INT | Measure | Number of units sold. | `sls_quantity` |
| `price` | INT | Measure | Unit price. Derived in Silver from `sales / quantity` when the source value was missing or non-positive. | `sls_price` |

### Notes
- Source dates are stored as `YYYYMMDD` integers in Bronze. Values that are zero, negative, or not 8 digits long become NULL in Silver.
- `sales_amount`, `price`, and `quantity` can be NULL when they could not be validated or recalculated.
- All joins are `LEFT JOIN`, so no sales rows are dropped when a dimension match is missing. Check for NULL keys when validating data quality.

---

## Data Lineage

| Gold object | Silver tables | Bronze tables | Source system |
|---|---|---|---|
| `dim_customers` | `crm_cust_info`, `erp_cust_az12`, `erp_loc_a101` | `crm_cust_info`, `erp_cust_az12`, `erp_loc_a101` | CRM, ERP |
| `dim_products` | `crm_prd_info`, `erp_px_cat_g1v2` | `crm_prd_info`, `erp_px_cat_g1v2` | CRM, ERP |
| `fact_sales` | `crm_sales_details` (+ the two dimensions above) | `crm_sales_details` | CRM |

## Conventions

| Convention | Rule |
|---|---|
| Naming | `snake_case`, business-friendly names; dimensions prefixed `dim_`, facts prefixed `fact_` |
| Surrogate keys | Suffix `_key`, generated with `ROW_NUMBER()` |
| Unknown values | Text attributes use `n/a`; unmatched joins and invalid numbers/dates are NULL |
| Refresh | Views are always current with Silver; refresh the data by running `bronze.load_bronze` and then `silver.load_silver` |
