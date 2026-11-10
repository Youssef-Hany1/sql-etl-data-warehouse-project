# Medallion Architecture ETL Documentation

## 1. Overview

This project builds a SQL Server data warehouse (`DataWarehouse`) using the **Medallion architecture**. Raw CRM and ERP CSV files are loaded into a Bronze layer, cleaned and standardized in a Silver layer, and exposed as a star schema in a Gold layer for reporting and analytics.

| Layer | Schema | Object type | Purpose | Load method |
|---|---|---|---|---|
| Bronze | `bronze` | Tables | Raw copy of the source files, no transformation | `BULK INSERT` (truncate and load) |
| Silver | `silver` | Tables | Cleaned, standardized, validated data | `INSERT ... SELECT` from Bronze (truncate and load) |
| Gold | `gold` | Views | Business-ready star schema (dimensions and fact) | Views over Silver, always current |

## 2. Architecture and Data Flow

```
 SOURCES                BRONZE                    SILVER                      GOLD
 -------                ------                    ------                      ----
 CRM CSV files   -->  bronze.crm_cust_info   -->  silver.crm_cust_info   -->  gold.dim_customers
 (3 files)            bronze.crm_prd_info    -->  silver.crm_prd_info    -->  gold.dim_products
                      bronze.crm_sales_details-->  silver.crm_sales_details-> gold.fact_sales

 ERP CSV files   -->  bronze.erp_cust_az12   -->  silver.erp_cust_az12   -->  (dim_customers)
 (3 files)            bronze.erp_loc_a101    -->  silver.erp_loc_a101    -->  (dim_customers)
                      bronze.erp_px_cat_g1v2 -->  silver.erp_px_cat_g1v2 -->  (dim_products)

              bronze.load_bronze          silver.load_silver          CREATE VIEW (ddl_gold.sql)
```

## 3. Project Files

| File | Type | Purpose |
|---|---|---|
| `ddl_bronze.sql` | DDL | Creates the six Bronze tables (drops existing ones first) |
| `proc_load_bronze.sql` | Procedure | `bronze.load_bronze`: loads CSVs into Bronze |
| `ddl_sillver.sql` | DDL | Creates the six Silver tables (drops existing ones first) |
| `proc_load_silver.sql` | Procedure | `silver.load_silver`: transforms Bronze into Silver |
| `ddl_gold.sql` | DDL | Creates `dim_customers`, `dim_products`, `fact_sales` views |
| `gold_data_catalog.md` | Docs | Column-level catalog of the Gold layer |

> `ddl_sillver.sql` is spelled with a double "l" in the file name. Consider renaming it to `ddl_silver.sql`.

## 4. Source Systems

| System | Table | Source file | Content |
|---|---|---|---|
| CRM | `crm_cust_info` | `cust_info.csv` | Customer master data |
| CRM | `crm_prd_info` | `prd_info.csv` | Product master data with version history |
| CRM | `crm_sales_details` | `sales_details.csv` | Sales order lines |
| ERP | `erp_cust_az12` | `CUST_AZ12.csv` | Customer birth date and gender |
| ERP | `erp_loc_a101` | `LOC_A101.csv` | Customer country |
| ERP | `erp_px_cat_g1v2` | `PX_CAT_G1V2.csv` | Product category hierarchy |

## 5. Prerequisites

- SQL Server with a `DataWarehouse` database and the `bronze`, `silver`, and `gold` schemas created (the database/schema creation script is not part of the files documented here).
- The SQL Server service account has read permission on the CSV folders.
- The hard-coded paths in `bronze.load_bronze` point to your local dataset folders (`...\01_datasets\source_crm\` and `...\source_erp\`). Change them to match where the files are stored.

## 6. Execution Order

| Step | Script / command | Notes |
|---|---|---|
| 1 | `ddl_bronze.sql` | Drops and recreates Bronze tables (destroys data) |
| 2 | `ddl_sillver.sql` | Drops and recreates Silver tables (destroys data) |
| 3 | `proc_load_bronze.sql`, then `EXEC bronze.load_bronze;` | Creates the procedure, then loads raw data |
| 4 | `proc_load_silver.sql`, then `EXEC silver.load_silver;` | Creates the procedure, then transforms and loads |
| 5 | `ddl_gold.sql` | Creates the views (needs the Silver tables to exist) |

For regular refreshes, only run `EXEC bronze.load_bronze;` followed by `EXEC silver.load_silver;`. Gold views update automatically.

## 7. Bronze Layer

**Principle:** store source data as-is so the original structure is preserved.

`bronze.load_bronze` loads each table in the same pattern:

1. `TRUNCATE TABLE` the target table.
2. `BULK INSERT` from the CSV with `FIRSTROW = 2` (skip header), `FIELDTERMINATOR = ','`, and `TABLOCK`.
3. Print the load duration in seconds.

The procedure also prints the total batch duration and wraps everything in `TRY...CATCH`, printing the error message, number, and state on failure.

Notable Bronze typing: `crm_sales_details` date columns are `INT` (source format `YYYYMMDD`), and `crm_prd_info` dates are `DATETIME`.

## 8. Silver Layer

**Principle:** clean, standardize, and validate. Every Silver table has an extra column, `dwh_create_date` (`DATETIME2`, defaults to the load time), which records when the row was inserted.

`silver.load_silver` truncates and reloads each table. Transformations by table:

### 8.1 `silver.crm_cust_info`

| Rule | Detail |
|---|---|
| Remove NULL IDs | Rows with `cst_id IS NULL` are excluded |
| Deduplicate | `ROW_NUMBER() OVER (PARTITION BY cst_id ORDER BY cst_create_date DESC)`, keep the most recent row |
| Trim text | `cst_firstname`, `cst_lastname` |
| Decode marital status | `S` = Single, `M` = Married, otherwise `n/a` |
| Decode gender | `F` = Female, `M` = Male, otherwise `n/a` |

### 8.2 `silver.crm_prd_info`

| Rule | Detail |
|---|---|
| Derive `cat_id` | First 5 characters of `prd_key`, with `-` replaced by `_` (matches ERP category IDs) |
| Clean `prd_key` | Substring from position 7 onward (removes the category prefix) |
| Default cost | `COALESCE(prd_cost, 0)` |
| Decode product line | `M` = Mountain, `R` = Road, `S` = Other Sales, `T` = Touring, otherwise `n/a` |
| Dates | Cast to `DATE` |
| Calculate end date | `LEAD(prd_start_dt - 1)` over the product key ordered by start date, so the latest version has a NULL end date |

### 8.3 `silver.crm_sales_details`

| Rule | Detail |
|---|---|
| Dates | `YYYYMMDD` integers converted to `DATE`; values `<= 0` or not 8 digits become NULL |
| Sales amount | Recalculated as `quantity * ABS(price)` when missing, non-positive, or inconsistent with quantity and price; NULL if it cannot be recalculated |
| Unit price | Derived as `sales / quantity` when the source price is missing or non-positive |

### 8.4 `silver.erp_cust_az12`

| Rule | Detail |
|---|---|
| Align IDs | Remove the `NAS` prefix from `cid` to match CRM `cst_key` |
| Birth date | Future dates become NULL |
| Gender | `F`/`FEMALE` = Female, `M`/`MALE` = Male, otherwise `n/a` |

### 8.5 `silver.erp_loc_a101`

| Rule | Detail |
|---|---|
| Align IDs | Remove `-` from `cid` |
| Country | `US`/`USA` = United States, `DE` = Germany, blank or NULL = `n/a`, otherwise trimmed value |

### 8.6 `silver.erp_px_cat_g1v2`

No transformation: a straight copy of Bronze.

## 9. Gold Layer

The Gold layer is a star schema built from views. See `gold_data_catalog.md` for full column definitions.

| View | Type | Grain | Key points |
|---|---|---|---|
| `gold.dim_customers` | Dimension | One row per customer | Joins CRM customers with ERP birth date/gender and location; CRM gender is primary, ERP is the fallback; surrogate key `customer_key` |
| `gold.dim_products` | Dimension | One row per active product | Joins CRM products with ERP categories; only rows with `prd_end_dt IS NULL`; surrogate key `product_key` |
| `gold.fact_sales` | Fact | One row per order line | Replaces business keys with `customer_key` and `product_key` via `LEFT JOIN`; keeps order, ship, and due dates plus sales, quantity, and price |

## 10. Logging and Error Handling

| Aspect | Current behavior |
|---|---|
| Logging | `PRINT` messages: step headers, truncate/insert notices, per-table duration, total duration |
| Errors | `TRY...CATCH` prints message, number, and state |
| Timing | `DATEDIFF(second, ...)` per table and for the whole batch |

## 11. Known Issues and Suggested Improvements

| # | Issue | Suggestion |
|---|---|---|
| 1 | `ddl_gold.sql` drop checks use `OBJECT_ID('gold.dim_customer', 'U')` (wrong name for the first one and wrong type `'U'` for all three). The `DROP VIEW` never executes, so re-running the script fails. | Use `CREATE OR ALTER VIEW`, or check `OBJECT_ID('gold.dim_customers', 'V')` |
| 2 | The `CATCH` blocks only print the error, so a failed run does not return a failing status to a scheduler (e.g., SQL Agent). | Add `THROW;` at the end of the `CATCH` block |
| 3 | A `TRUNCATE` followed by a failed insert leaves the table empty. | Wrap each load in a transaction, or load into staging and swap |
| 4 | `dim_customers` and `dim_products` surrogate keys come from `ROW_NUMBER()`, so they can change between queries when the data changes. | Persist dimensions as tables with `IDENTITY` keys if stable keys are needed |
| 5 | `dim_products` keeps only active products, so sales of discontinued products get a NULL `product_key`. | Add a historical/SCD Type 2 dimension, or join on date ranges |
| 6 | Bronze file paths are hard-coded. | Parameterize the base folder |
| 7 | Logging only goes to the console. | Write run results to an ETL log table |

## 12. Data Quality Checks (suggested)

- Bronze to Silver row counts per table, accounting for removed duplicates and NULL IDs.
- No duplicate `cst_id` in `silver.crm_cust_info`.
- No unwanted spaces in trimmed text columns.
- `sls_sales = sls_quantity * sls_price` in `silver.crm_sales_details`, and `sls_order_dt <= sls_ship_dt <= sls_due_dt`.
- No NULL `customer_key` or `product_key` in `gold.fact_sales` (or review the unmatched rows).
- Unique `customer_key` and `product_key` in the dimensions.
