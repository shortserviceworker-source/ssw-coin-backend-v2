BEGIN;

ALTER TABLE admin_users
ADD COLUMN IF NOT EXISTS two_factor_last_used_step BIGINT;

COMMIT;
