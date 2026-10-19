-- Replica identity (required for DELETE capture)
ALTER TABLE staging.card_transactions REPLICA IDENTITY FULL;
ALTER TABLE staging.digital_events    REPLICA IDENTITY FULL;
ALTER TABLE staging.core_transactions REPLICA IDENTITY FULL;