-- LAB VERSION of Maedeh's 01_create_schemas.sql.
-- The lab already has a database called "lab", so CREATE DATABASE horizon_dw
-- is skipped and the warehouse is built inside lab.
-- Run in CloudBeaver connected to the lab database (Execute script).
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS dw;
