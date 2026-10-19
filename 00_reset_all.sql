-- =====================================================================
-- 00_reset_all.sql
-- Horizon Retail Bank | 32113 Advanced Database | Assignment 2
-- Team integration: start the PostgreSQL prototype again from scratch.
--
-- Drops ONLY the five Horizon schemas and everything in them:
--   staging, dw          (Maedeh: source copies and integrated warehouse)
--   graph                (Samnang: graph layer and Report 2 views)
--   governance, secure   (Shubham: data fabric and masked views)
-- Every object in these schemas is rebuilt from the CSV files by
-- run_all.ps1, so nothing is lost that cannot be recreated.
-- Other lab work in the lab database (e.g. earlier workshop schemas)
-- is not touched. Shubham's three roles are kept (they are cluster-wide
-- and his setup script reuses them).
-- =====================================================================

DROP SCHEMA IF EXISTS secure     CASCADE;
DROP SCHEMA IF EXISTS governance CASCADE;
DROP SCHEMA IF EXISTS graph      CASCADE;
DROP SCHEMA IF EXISTS dw         CASCADE;
DROP SCHEMA IF EXISTS staging    CASCADE;
