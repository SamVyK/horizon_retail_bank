CREATE TRIGGER digital_users_tcn_trigger
AFTER INSERT OR UPDATE OR DELETE ON staging.digital_users
FOR EACH ROW EXECUTE FUNCTION triggered_change_notification();
