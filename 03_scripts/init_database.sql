/*
Purpose:
Initialize the DataWarehouse database by recreating it if it already exists,
then create the bronze, silver, and gold schemas.

WARNING:
This script permanently drops and recreates the existing DataWarehouse database.
All data and objects in that database will be deleted, and active connections
will be terminated. Back up any required data before running this script.
*/

USE master;
GO

-- Drop and recreate the 'DataWarehouse' database
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'DataWarehouse')
BEGIN
	-- Force active connections to disconnect so the database can be dropped.
	ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
	DROP DATABASE DataWarehouse;
END;
GO

-- Create the 'DataWarehouse' database
CREATE DATABASE DataWarehouse;
GO

USE DataWarehouse;
GO

-- Create Schemas
CREATE SCHEMA bronze;
GO

CREATE SCHEMA silver;
GO

CREATE SCHEMA gold;
GO