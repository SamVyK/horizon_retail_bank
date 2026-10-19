-- 00_reset_lab.sql  (OPTIONAL - only to start again from scratch)
-- Deletes the Horizon schemas and everything in them from the lab database:
-- graph (Samnang), dw and staging (Maedeh). Other lab work is not touched.
-- After running this, start again from 01_create_schemas_lab.sql.
DROP SCHEMA IF EXISTS graph   CASCADE;
DROP SCHEMA IF EXISTS dw      CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;
