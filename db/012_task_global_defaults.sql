-- S.S.W COIN migration 012: allow global task reward/timer defaults for new task rows
-- Apply only to an existing v1.3 database after backup. Existing values are preserved as explicit overrides.
BEGIN;
ALTER TABLE tasks ALTER COLUMN timer_seconds DROP NOT NULL;
ALTER TABLE tasks ALTER COLUMN timer_seconds DROP DEFAULT;
ALTER TABLE tasks ALTER COLUMN reward_amount_usd DROP NOT NULL;
ALTER TABLE tasks ALTER COLUMN reward_amount_usd DROP DEFAULT;
UPDATE system_controls SET reward_system_enabled=FALSE, withdrawal_enabled=FALSE WHERE id=1;
UPDATE payment_method_settings SET is_enabled=FALSE;
COMMIT;
