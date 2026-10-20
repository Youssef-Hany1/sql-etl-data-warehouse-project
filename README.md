# SQL Data Warehousing & ETL Pipeline

🔗 **Course Context:** This project is part of my complete SQL learning portfolio. View the full course notes and other projects here: [SQL Full Course - From Zero to Hero](https://github.com/Youssef-Hany1/SQL-Course)

## 🚀 Overview
This project simulates an enterprise-grade Data Warehousing environment. It demonstrates the design and execution of an Extract, Transform, Load (ETL) pipeline using Microsoft SQL Server to integrate two distinct source systems (CRM and ERP) via CSV files into a centralized data model. 

## 🛠️ Architecture (Medallion Approach)
- **🥉 Bronze Layer:** Raw data ingestion from CRM and ERP CSV files using `BULK INSERT` operations. No transformations are applied to maintain traceability.
- **🥈 Silver Layer:** Cleansed and standardized data. Transformations include handling nulls, removing unwanted spaces, standardizing domains (e.g., gender, marital status), and adding metadata columns (like load dates).
- **🥇 Gold Layer:** Business-ready data modeled using a **Star Schema** (Dimension and Fact tables). Data is integrated from multiple sources, surrogate keys are generated using `ROW_NUMBER()`, and exposed entirely via `VIEWS` for analytics.

## 💻 Tech Stack & Concepts
- **Database Engine:** Microsoft SQL Server
- **IDE:** SQL Server Management Studio (SSMS)
- **Concepts:** DDL/DML, Stored Procedures, Error Handling (`TRY...CATCH`), Execution Duration Logging, Star Schema Data Modeling.

## 👨‍🏫 Acknowledgments
Developed as part of the [SQL Full Course for Beginners (30 Hours)](https://www.youtube.com/watch?v=SSKVgrwhzus) by **Data with Baraa**.
