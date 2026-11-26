-- S.S.W COIN - Consolidated PostgreSQL starter schema
-- Consolidated schema v1.4 | PostgreSQL 14+ (includes v1.3 safeguards; reward and withdrawal systems off by default)
-- IMPORTANT:
-- 1) This is a reviewed starter design, not a deployed or production-certified database.
-- 2) Run on a NEW empty database after review by a qualified backend/database developer.
-- 3) Never store passwords, API keys, Telegram bot tokens, crypto seed phrases or private keys here.
-- 4) All money-changing operations must run in server-side DB transactions with idempotency keys.
-- 5) Apply migrations through a versioned migration tool; do not run ad-hoc snippets in production.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. USERS, PROFILES AND AUTHENTICATION
CREATE TABLE users (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(160) NOT NULL,
    username VARCHAR(50) NOT NULL UNIQUE,
    email VARCHAR(254) NOT NULL UNIQUE,
    password_hash TEXT,
    country_code CHAR(2) NOT NULL,
    mobile_optional VARCHAR(32),
    referral_code VARCHAR(32) NOT NULL UNIQUE,
    email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    account_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (account_status IN ('pending','active','suspended','banned')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_profiles (
    user_id BIGINT PRIMARY KEY REFERENCES users(id),
    profile_image_ref TEXT,
    preferred_language VARCHAR(10) NOT NULL DEFAULT 'en',
    timezone_name VARCHAR(80) NOT NULL DEFAULT 'UTC',
    profile_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE email_verification_tokens (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE password_reset_tokens (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_auth_identities (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    provider VARCHAR(30) NOT NULL,
    provider_user_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(provider, provider_user_id)
);

CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id BIGINT NOT NULL REFERENCES users(id),
    refresh_token_hash TEXT NOT NULL UNIQUE,
    device_info TEXT,
    ip_address INET,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE login_security_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT REFERENCES users(id),
    email_attempted VARCHAR(254),
    event_type VARCHAR(60) NOT NULL,
    ip_address INET,
    device_info TEXT,
    event_details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. TASKS, COUNTDOWN SESSIONS AND COMPLETIONS
CREATE TABLE tasks (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(180) NOT NULL,
    description TEXT,
    task_url TEXT NOT NULL,
    reward_amount_usd NUMERIC(18,6) CHECK (reward_amount_usd IS NULL OR reward_amount_usd >= 0),
    timer_seconds INTEGER CHECK (timer_seconds IS NULL OR timer_seconds BETWEEN 5 AND 86400),
    repeat_policy VARCHAR(20) NOT NULL DEFAULT 'once_daily'
        CHECK (repeat_policy IN ('once_daily','multiple_daily','once_ever')),
    daily_completion_cap INTEGER NOT NULL DEFAULT 1 CHECK (daily_completion_cap > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    display_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE task_daily_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    daily_task_limit INTEGER NOT NULL DEFAULT 20 CHECK (daily_task_limit > 0),
    default_timer_seconds INTEGER NOT NULL DEFAULT 60 CHECK (default_timer_seconds > 0),
    reset_timezone VARCHAR(80) NOT NULL DEFAULT 'UTC',
    reset_local_time TIME NOT NULL DEFAULT '00:00',
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    created_by BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_task_daily_settings_current
    ON task_daily_settings(is_current) WHERE is_current = TRUE;
INSERT INTO task_daily_settings(daily_task_limit, default_timer_seconds, is_current)
VALUES (20, 60, TRUE);

CREATE TABLE task_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id BIGINT NOT NULL REFERENCES users(id),
    task_id BIGINT NOT NULL REFERENCES tasks(id),
    timer_seconds_snapshot INTEGER NOT NULL CHECK (timer_seconds_snapshot > 0),
    reward_amount_snapshot NUMERIC(18,6) NOT NULL CHECK (reward_amount_snapshot >= 0),
    task_url_snapshot TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    session_status VARCHAR(20) NOT NULL DEFAULT 'running'
        CHECK (session_status IN ('running','completed','expired','cancelled'))
);

CREATE TABLE task_completions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    task_id BIGINT NOT NULL REFERENCES tasks(id),
    session_id UUID NOT NULL UNIQUE REFERENCES task_sessions(id),
    reward_amount_usd NUMERIC(18,6) NOT NULL CHECK (reward_amount_usd >= 0),
    platform_day DATE NOT NULL,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_task_completions_user_day ON task_completions(user_id, platform_day);
CREATE INDEX idx_task_sessions_user_status ON task_sessions(user_id, session_status);

-- 3. REWARDS AND EARNINGS
CREATE TABLE earnings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    source_type VARCHAR(30) NOT NULL
        CHECK (source_type IN ('task','referral','monthly_bonus','admin_adjustment')),
    source_reference_id TEXT,
    amount_usd NUMERIC(18,6) NOT NULL CHECK (amount_usd >= 0),
    reward_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (reward_status IN ('pending','approved','rejected','credited')),
    description TEXT,
    approved_by_admin_id BIGINT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX uq_earnings_source
ON earnings(user_id, source_type, source_reference_id)
WHERE source_reference_id IS NOT NULL;

CREATE TABLE reward_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    default_task_reward_usd NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK (default_task_reward_usd >= 0),
    referral_reward_usd NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK (referral_reward_usd >= 0),
    monthly_bonus_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_reward_settings_current
    ON reward_settings(is_current) WHERE is_current = TRUE;
INSERT INTO reward_settings(is_current) VALUES (TRUE);

-- 4. REFERRALS AND MONTHLY REFERRAL BONUS
CREATE TABLE referrals (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    referrer_id BIGINT NOT NULL REFERENCES users(id),
    referred_user_id BIGINT NOT NULL UNIQUE REFERENCES users(id),
    referral_code_used VARCHAR(32) NOT NULL,
    referral_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (referral_status IN ('pending','qualified','rejected','under_review')),
    risk_flag BOOLEAN NOT NULL DEFAULT FALSE,
    risk_reason TEXT,
    source_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    verified_at TIMESTAMPTZ,
    qualified_at TIMESTAMPTZ,
    rejection_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (referrer_id <> referred_user_id)
);

CREATE TABLE referral_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    withdrawal_referral_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    required_active_referrals INTEGER NOT NULL DEFAULT 15 CHECK (required_active_referrals >= 0),
    effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by_admin_id BIGINT,
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX uq_referral_settings_current
    ON referral_settings(is_current) WHERE is_current = TRUE;
INSERT INTO referral_settings(withdrawal_referral_enabled, required_active_referrals, is_current)
VALUES (TRUE, 15, TRUE);

CREATE TABLE monthly_bonus_campaigns (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_name VARCHAR(160) NOT NULL,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ NOT NULL,
    is_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    winner_count INTEGER NOT NULL DEFAULT 1 CHECK (winner_count > 0),
    tie_break_rule TEXT NOT NULL,
    eligibility_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_by_admin_id BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (ends_at > starts_at)
);

CREATE TABLE monthly_bonus_prizes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id BIGINT NOT NULL REFERENCES monthly_bonus_campaigns(id),
    rank_position INTEGER NOT NULL CHECK (rank_position > 0),
    prize_amount_usd NUMERIC(18,6) NOT NULL CHECK (prize_amount_usd >= 0),
    UNIQUE(campaign_id, rank_position)
);

CREATE TABLE monthly_bonus_awards (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id BIGINT NOT NULL REFERENCES monthly_bonus_campaigns(id),
    user_id BIGINT NOT NULL REFERENCES users(id),
    rank_position INTEGER NOT NULL CHECK (rank_position > 0),
    eligible_referral_count INTEGER NOT NULL CHECK (eligible_referral_count >= 0),
    bonus_amount_usd NUMERIC(18,6) NOT NULL CHECK (bonus_amount_usd >= 0),
    award_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (award_status IN ('pending','approved','rejected','paid')),
    payout_reference TEXT,
    approved_by_admin_id BIGINT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(campaign_id, user_id)
);

-- 5. ADMIN USERS, ROLES AND PERMISSIONS
CREATE TABLE admin_users (
    user_id BIGINT PRIMARY KEY REFERENCES users(id),
    admin_status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (admin_status IN ('active','suspended','revoked')),
    two_factor_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    two_factor_secret_encrypted BYTEA,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE admin_roles (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_name VARCHAR(40) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE admin_permissions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    permission_code VARCHAR(100) NOT NULL UNIQUE,
    description TEXT
);

CREATE TABLE admin_role_permissions (
    role_id BIGINT NOT NULL REFERENCES admin_roles(id),
    permission_id BIGINT NOT NULL REFERENCES admin_permissions(id),
    PRIMARY KEY(role_id, permission_id)
);

CREATE TABLE admin_user_roles (
    admin_user_id BIGINT NOT NULL REFERENCES admin_users(user_id),
    role_id BIGINT NOT NULL REFERENCES admin_roles(id),
    assigned_by BIGINT REFERENCES admin_users(user_id),
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY(admin_user_id, role_id)
);

-- 6. WALLET, APPEND-ONLY LEDGER AND WITHDRAWALS
CREATE TABLE wallets (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL UNIQUE REFERENCES users(id),
    currency CHAR(3) NOT NULL DEFAULT 'USD',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sign convention: positive = credit; negative = debit.
-- A withdrawal hold is a negative available-balance entry.
-- Rejection creates a positive refund entry. Mark-paid records settlement metadata,
-- not a second wallet debit, unless a separately documented accounting model is adopted.
CREATE TABLE wallet_ledger (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    wallet_id BIGINT NOT NULL REFERENCES wallets(id),
    entry_type VARCHAR(30) NOT NULL
        CHECK (entry_type IN (
            'task_reward','referral_reward','monthly_bonus',
            'withdrawal_hold','withdrawal_refund','admin_adjustment'
        )),
    amount_usd NUMERIC(18,6) NOT NULL CHECK (amount_usd <> 0),
    reference_type VARCHAR(40),
    reference_id TEXT,
    idempotency_key VARCHAR(160) NOT NULL UNIQUE,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_wallet_ledger_wallet_date ON wallet_ledger(wallet_id, created_at);

CREATE TABLE payment_method_settings (
    method_code VARCHAR(20) PRIMARY KEY
        CHECK (method_code IN ('bkash','nagad','binance')),
    is_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    minimum_withdrawal_usd NUMERIC(18,6) NOT NULL DEFAULT 0 CHECK (minimum_withdrawal_usd >= 0),
    maximum_withdrawal_usd NUMERIC(18,6) CHECK (maximum_withdrawal_usd IS NULL OR maximum_withdrawal_usd >= minimum_withdrawal_usd),
    fee_configuration JSONB NOT NULL DEFAULT '{}'::jsonb,
    public_configuration JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_by_admin_id BIGINT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- Do not put provider passwords, API secrets, private keys or bot tokens in configuration JSON.

CREATE TABLE withdrawal_schedule_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schedule_name VARCHAR(120) NOT NULL,
    timezone_name VARCHAR(80) NOT NULL DEFAULT 'UTC',
    schedule_configuration JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    updated_by_admin_id BIGINT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE withdrawals (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    wallet_id BIGINT NOT NULL REFERENCES wallets(id),
    amount_usd NUMERIC(18,6) NOT NULL CHECK (amount_usd > 0),
    payment_method VARCHAR(20) NOT NULL REFERENCES payment_method_settings(method_code),
    destination_ciphertext BYTEA NOT NULL,
    eligibility_snapshot JSONB NOT NULL,
    withdrawal_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (withdrawal_status IN ('pending','under_review','approved','rejected','paid')),
    transaction_reference TEXT,
    request_idempotency_key VARCHAR(160) UNIQUE,
    reviewed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    reviewed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    paid_at TIMESTAMPTZ
);

CREATE INDEX idx_withdrawals_status_created ON withdrawals(withdrawal_status, created_at);

CREATE TABLE withdrawal_review_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    withdrawal_id BIGINT NOT NULL REFERENCES withdrawals(id),
    admin_user_id BIGINT NOT NULL REFERENCES admin_users(user_id),
    action VARCHAR(20) NOT NULL
        CHECK (action IN ('reviewed','approved','rejected','paid')),
    remarks TEXT,
    transaction_reference TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7. NOTIFICATIONS
CREATE TABLE notifications (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    category VARCHAR(30) NOT NULL
        CHECK (category IN ('payment','withdrawal','task','referral','warning','announcement','security','monthly_bonus')),
    priority VARCHAR(20) NOT NULL DEFAULT 'normal'
        CHECK (priority IN ('low','normal','high','urgent')),
    audience_type VARCHAR(20) NOT NULL
        CHECK (audience_type IN ('single','selected','all')),
    created_by_admin_id BIGINT REFERENCES admin_users(user_id),
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_notifications (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    notification_id BIGINT NOT NULL REFERENCES notifications(id),
    user_id BIGINT NOT NULL REFERENCES users(id),
    read_at TIMESTAMPTZ,
    delivery_status VARCHAR(20) NOT NULL DEFAULT 'queued'
        CHECK (delivery_status IN ('queued','sent','delivered','failed','expired')),
    delivered_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(notification_id, user_id)
);

CREATE TABLE notification_delivery_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_notification_id BIGINT NOT NULL REFERENCES user_notifications(id),
    channel VARCHAR(20) NOT NULL CHECK (channel IN ('in_app','email','telegram')),
    delivery_status VARCHAR(20) NOT NULL,
    error_message TEXT,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 8. TELEGRAM
CREATE TABLE telegram_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_url TEXT,
    channel_id TEXT,
    bot_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    mandatory_join BOOLEAN NOT NULL DEFAULT FALSE,
    membership_verification_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    updated_by_admin_id BIGINT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE telegram_members (
    user_id BIGINT PRIMARY KEY REFERENCES users(id),
    telegram_user_id TEXT UNIQUE,
    membership_status VARCHAR(20) NOT NULL DEFAULT 'unverified'
        CHECK (membership_status IN ('unverified','member','not_member','left')),
    last_verified_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE telegram_announcements (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    message TEXT NOT NULL,
    created_by_admin_id BIGINT REFERENCES admin_users(user_id),
    telegram_message_id TEXT,
    delivery_status VARCHAR(20) NOT NULL DEFAULT 'queued',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 9. REPORTS AND FINANCIAL RECONCILIATION
CREATE TABLE report_exports (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    requested_by_admin_id BIGINT NOT NULL REFERENCES admin_users(user_id),
    report_type VARCHAR(80) NOT NULL,
    export_format VARCHAR(10) NOT NULL CHECK (export_format IN ('pdf','xlsx','csv')),
    filter_parameters JSONB NOT NULL DEFAULT '{}'::jsonb,
    export_status VARCHAR(20) NOT NULL DEFAULT 'queued'
        CHECK (export_status IN ('queued','processing','completed','failed')),
    private_storage_reference TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE financial_reconciliations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    wallet_liability_usd NUMERIC(18,6) NOT NULL DEFAULT 0,
    withdrawal_holds_usd NUMERIC(18,6) NOT NULL DEFAULT 0,
    external_payouts_usd NUMERIC(18,6) NOT NULL DEFAULT 0,
    variance_usd NUMERIC(18,6) NOT NULL DEFAULT 0,
    reviewed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    reconciliation_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (reconciliation_status IN ('pending','matched','mismatch','reviewed')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (period_end >= period_start)
);

-- 10. GLOBAL SETTINGS, DESIGN, LANGUAGE, POLICIES AND SYSTEM CONTROLS
CREATE TABLE global_settings (
    setting_key VARCHAR(120) PRIMARY KEY,
    setting_value JSONB NOT NULL,
    description TEXT,
    updated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE website_design_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    theme_mode VARCHAR(10) NOT NULL DEFAULT 'dark' CHECK (theme_mode IN ('dark','light')),
    primary_color VARCHAR(20) NOT NULL DEFAULT '#0B1730',
    accent_color VARCHAR(20) NOT NULL DEFAULT '#D4AF37',
    font_family VARCHAR(100),
    animation_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    reduced_motion_supported BOOLEAN NOT NULL DEFAULT TRUE,
    updated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE website_language_settings (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    default_language VARCHAR(10) NOT NULL DEFAULT 'en',
    supported_languages JSONB NOT NULL DEFAULT '["en","bn"]'::jsonb,
    translations JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE global_settings_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    setting_key VARCHAR(120) NOT NULL,
    previous_value JSONB,
    new_value JSONB NOT NULL,
    changed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    change_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE system_controls (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    maintenance_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    registration_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    login_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    task_system_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    reward_system_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    withdrawal_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    read_only_mode BOOLEAN NOT NULL DEFAULT FALSE,
    maintenance_mode BOOLEAN NOT NULL DEFAULT FALSE,
    tasks_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    maintenance_message VARCHAR(300) NOT NULL DEFAULT 'The platform is temporarily unavailable for maintenance.',
    scheduled_activation_at TIMESTAMPTZ,
    updated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ck_system_controls_singleton CHECK (id = 1)
);
INSERT INTO system_controls(id) OVERRIDING SYSTEM VALUE VALUES (1);

CREATE TABLE system_control_actions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    control_key VARCHAR(100) NOT NULL,
    action_type VARCHAR(30) NOT NULL
        CHECK (action_type IN ('enable','disable','emergency_stop','rollback','scheduled_change')),
    previous_value JSONB,
    new_value JSONB,
    scheduled_at TIMESTAMPTZ,
    executed_at TIMESTAMPTZ,
    action_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (action_status IN ('pending','completed','failed','cancelled')),
    reason TEXT,
    created_by_admin_id BIGINT REFERENCES admin_users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE system_control_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    control_key VARCHAR(100) NOT NULL,
    old_value JSONB,
    new_value JSONB NOT NULL,
    changed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    change_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE emergency_controls (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    emergency_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    emergency_message TEXT,
    affected_modules JSONB NOT NULL DEFAULT '[]'::jsonb,
    activated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    activated_at TIMESTAMPTZ,
    deactivated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    deactivated_at TIMESTAMPTZ
);

-- 11. TERMS, POLICIES AND ACCEPTANCE HISTORY
CREATE TABLE policy_documents (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_type VARCHAR(40) NOT NULL,
    language_code VARCHAR(10) NOT NULL,
    title VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    version_number INTEGER NOT NULL CHECK (version_number > 0),
    is_published BOOLEAN NOT NULL DEFAULT FALSE,
    published_at TIMESTAMPTZ,
    created_by_admin_id BIGINT REFERENCES admin_users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(policy_type, language_code, version_number)
);

CREATE TABLE user_policy_acceptances (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id),
    policy_id BIGINT NOT NULL REFERENCES policy_documents(id),
    accepted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ip_address INET,
    UNIQUE(user_id, policy_id)
);

CREATE TABLE policy_change_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_id BIGINT NOT NULL REFERENCES policy_documents(id),
    changed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    change_description TEXT,
    previous_version INTEGER,
    new_version INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 12. HELP CENTER AND COMPLAINTS
CREATE TABLE support_tickets (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_number UUID NOT NULL DEFAULT gen_random_uuid() UNIQUE,
    user_id BIGINT NOT NULL REFERENCES users(id),
    subject VARCHAR(200) NOT NULL,
    category VARCHAR(30) NOT NULL
        CHECK (category IN ('payment','withdrawal','task','referral','account','technical','other')),
    priority VARCHAR(20) NOT NULL DEFAULT 'normal'
        CHECK (priority IN ('low','normal','high','urgent')),
    ticket_status VARCHAR(20) NOT NULL DEFAULT 'open'
        CHECK (ticket_status IN ('open','pending','in_progress','resolved','closed')),
    assigned_admin_id BIGINT REFERENCES admin_users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE support_messages (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id BIGINT NOT NULL REFERENCES support_tickets(id),
    sender_user_id BIGINT REFERENCES users(id),
    sender_admin_id BIGINT REFERENCES admin_users(user_id),
    message TEXT NOT NULL,
    is_internal_note BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (
        (sender_user_id IS NOT NULL AND sender_admin_id IS NULL AND is_internal_note = FALSE)
        OR
        (sender_user_id IS NULL AND sender_admin_id IS NOT NULL)
    )
);

CREATE TABLE support_ticket_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id BIGINT NOT NULL REFERENCES support_tickets(id),
    changed_by_admin_id BIGINT REFERENCES admin_users(user_id),
    old_status VARCHAR(20),
    new_status VARCHAR(20),
    change_note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 13. BACKUP AND RESTORE
CREATE TABLE backup_records (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    backup_type VARCHAR(20) NOT NULL
        CHECK (backup_type IN ('master_pdf','source_code','database','configuration')),
    storage_reference TEXT NOT NULL,
    checksum_sha256 CHAR(64),
    encryption_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    backup_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (backup_status IN ('pending','processing','completed','failed')),
    file_size_bytes BIGINT CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0),
    created_by_admin_id BIGINT REFERENCES admin_users(user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE backup_schedules (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    backup_type VARCHAR(20) NOT NULL
        CHECK (backup_type IN ('master_pdf','source_code','database','configuration')),
    schedule_frequency VARCHAR(10) NOT NULL
        CHECK (schedule_frequency IN ('daily','weekly','monthly')),
    is_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    retention_days INTEGER NOT NULL DEFAULT 90 CHECK (retention_days > 0),
    next_run_at TIMESTAMPTZ,
    updated_by_admin_id BIGINT REFERENCES admin_users(user_id),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(backup_type, schedule_frequency)
);

CREATE TABLE restore_history (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    backup_id BIGINT NOT NULL REFERENCES backup_records(id),
    restored_by_admin_id BIGINT NOT NULL REFERENCES admin_users(user_id),
    restore_status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (restore_status IN ('pending','processing','completed','failed')),
    pre_restore_snapshot_id BIGINT REFERENCES backup_records(id),
    restore_notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- 14. ADMIN AUDIT AND SECURITY MONITORING
CREATE TABLE admin_audit_logs (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_user_id BIGINT NOT NULL REFERENCES admin_users(user_id),
    action VARCHAR(100) NOT NULL,
    module_name VARCHAR(100) NOT NULL,
    target_reference VARCHAR(150),
    old_values JSONB,
    new_values JSONB,
    reason TEXT,
    ip_address INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE security_events (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id BIGINT REFERENCES users(id),
    admin_user_id BIGINT REFERENCES admin_users(user_id),
    event_type VARCHAR(100) NOT NULL,
    severity VARCHAR(20) NOT NULL DEFAULT 'normal'
        CHECK (severity IN ('low','normal','high','critical')),
    ip_address INET,
    device_info TEXT,
    event_details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_admin_audit_admin_date ON admin_audit_logs(admin_user_id, created_at);
CREATE INDEX idx_security_events_date ON security_events(created_at);
CREATE INDEX idx_security_events_type ON security_events(event_type);
CREATE INDEX idx_user_sessions_user_expiry ON user_sessions(user_id, expires_at);
CREATE INDEX idx_referrals_referrer_status ON referrals(referrer_id, referral_status);
CREATE INDEX idx_notifications_created ON notifications(created_at);
CREATE INDEX idx_support_tickets_user_status ON support_tickets(user_id, ticket_status);

-- Add admin foreign keys after admin_users exists (avoids creation-order problems).
ALTER TABLE earnings
    ADD CONSTRAINT fk_earnings_approved_by_admin
    FOREIGN KEY (approved_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE task_daily_settings
    ADD CONSTRAINT fk_task_daily_settings_created_by
    FOREIGN KEY (created_by) REFERENCES admin_users(user_id);

ALTER TABLE referral_settings
    ADD CONSTRAINT fk_referral_settings_updated_by
    FOREIGN KEY (updated_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE monthly_bonus_campaigns
    ADD CONSTRAINT fk_monthly_bonus_campaigns_created_by
    FOREIGN KEY (created_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE monthly_bonus_awards
    ADD CONSTRAINT fk_monthly_bonus_awards_approved_by
    FOREIGN KEY (approved_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE payment_method_settings
    ADD CONSTRAINT fk_payment_method_settings_updated_by
    FOREIGN KEY (updated_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE withdrawal_schedule_settings
    ADD CONSTRAINT fk_withdrawal_schedule_updated_by
    FOREIGN KEY (updated_by_admin_id) REFERENCES admin_users(user_id);

ALTER TABLE telegram_settings
    ADD CONSTRAINT fk_telegram_settings_updated_by
    FOREIGN KEY (updated_by_admin_id) REFERENCES admin_users(user_id);


-- 15. AUDIT/LEDGER IMMUTABILITY GUARD
-- This trigger blocks UPDATE/DELETE. Production must ALSO revoke UPDATE/DELETE
-- privileges from the application role and use a separate migration/owner role.
CREATE OR REPLACE FUNCTION prevent_append_only_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'This table is append-only; UPDATE and DELETE are prohibited';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_wallet_ledger_immutable
BEFORE UPDATE OR DELETE ON wallet_ledger
FOR EACH ROW EXECUTE FUNCTION prevent_append_only_mutation();

CREATE TRIGGER trg_admin_audit_logs_immutable
BEFORE UPDATE OR DELETE ON admin_audit_logs
FOR EACH ROW EXECUTE FUNCTION prevent_append_only_mutation();

CREATE TRIGGER trg_security_events_immutable
BEFORE UPDATE OR DELETE ON security_events
FOR EACH ROW EXECUTE FUNCTION prevent_append_only_mutation();

CREATE TRIGGER trg_global_settings_history_immutable
BEFORE UPDATE OR DELETE ON global_settings_history
FOR EACH ROW EXECUTE FUNCTION prevent_append_only_mutation();

CREATE TRIGGER trg_system_control_history_immutable
BEFORE UPDATE OR DELETE ON system_control_history
FOR EACH ROW EXECUTE FUNCTION prevent_append_only_mutation();

-- Seed only the three allowed payout methods as disabled by default.
INSERT INTO payment_method_settings(method_code, is_enabled)
VALUES ('bkash', FALSE), ('nagad', FALSE), ('binance', FALSE)
ON CONFLICT (method_code) DO NOTHING;

-- Seed the four agreed Admin roles and an explicit least-privilege permission catalogue.
INSERT INTO admin_roles(role_name, description)
VALUES
 ('main_admin','Full access; sensitive operations require re-authentication and audit'),
 ('manager_admin','User, task and referral operations; no finance payout or security administration'),
 ('finance_admin','Finance workflows; no role management or security configuration'),
 ('support_admin','Support workflows and limited user read access')
ON CONFLICT (role_name) DO NOTHING;

INSERT INTO admin_permissions(permission_code, description) VALUES
 ('dashboard.read','View Admin dashboard'),
 ('users.read','View user records'), ('users.manage','Manage user account status'),
 ('registrations.read','Review registrations'),
 ('tasks.read','View tasks'), ('tasks.manage','Create and manage tasks'),
 ('rewards.read','View reward records'), ('rewards.manage','Review task rewards'),
 ('referrals.read','View referrals'), ('referrals.review','Review referral qualification and risk'),
 ('bonus.read','View monthly bonus campaigns and awards'), ('bonus.manage','Manage campaigns and calculate awards'),
 ('wallet.read','View wallet and ledger records'), ('wallet.adjust','Create audited wallet adjustments'),
 ('withdrawals.read','View withdrawal requests'), ('withdrawals.review','Review and decide withdrawal requests'), ('withdrawals.pay','Record externally completed payouts'),
 ('payments.manage','Configure enabled payout methods and limits'),
 ('notifications.read','View notification history'), ('notifications.send','Send individual or bulk in-app notices'),
 ('telegram.manage','Manage Telegram channel settings and announcements'),
 ('reports.read','View reports'), ('reports.export','Export reports'),
 ('admins.manage','Manage Admin users, roles and permission assignments'),
 ('security.read','View security events and audit logs'), ('security.manage','Manage security settings and 2FA policy'),
 ('settings.manage','Manage global website and platform settings'),
 ('policies.manage','Manage policy documents and versions'),
 ('support.read','View support tickets'), ('support.reply','Reply to support tickets'),
 ('backups.manage','Create and restore backups'),
 ('system_controls.manage','Change emergency and system-wide controls');

-- Main Admin receives the complete seeded permission set. Other roles receive limited mappings.
INSERT INTO admin_role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM admin_roles r CROSS JOIN admin_permissions p
WHERE r.role_name = 'main_admin'
ON CONFLICT DO NOTHING;
INSERT INTO admin_role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM admin_roles r JOIN admin_permissions p
  ON p.permission_code IN ('dashboard.read','users.read','users.manage','registrations.read',
    'tasks.read','tasks.manage','rewards.read','rewards.manage','referrals.read','referrals.review',
    'bonus.read','bonus.manage','notifications.read','notifications.send','telegram.manage','reports.read','reports.export','support.read')
WHERE r.role_name = 'manager_admin' ON CONFLICT DO NOTHING;
INSERT INTO admin_role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM admin_roles r JOIN admin_permissions p
  ON p.permission_code IN ('dashboard.read','wallet.read','wallet.adjust','withdrawals.read',
    'withdrawals.review','withdrawals.pay','payments.manage','bonus.read','bonus.manage','reports.read','reports.export')
WHERE r.role_name = 'finance_admin' ON CONFLICT DO NOTHING;
INSERT INTO admin_role_permissions(role_id, permission_id)
SELECT r.id, p.id FROM admin_roles r JOIN admin_permissions p
  ON p.permission_code IN ('dashboard.read','users.read','support.read','support.reply','notifications.read')
WHERE r.role_name = 'support_admin' ON CONFLICT DO NOTHING;

-- Prevent duplicate daily/once-ever task completions. multiple_daily caps still
-- require a serialized API transaction per (user, task, platform_day).
-- The API must enforce once_daily / once_ever / multiple_daily rules while holding
-- a transaction-scoped advisory lock for the user+task+platform_day key. A simple
-- index cannot safely express a predicate that depends on the tasks table.


-- Integrity indexes and read-only derived views.
CREATE INDEX idx_task_completions_user_task_day ON task_completions(user_id, task_id, platform_day);
CREATE UNIQUE INDEX uq_wallet_ledger_withdrawal_hold
    ON wallet_ledger(reference_type, reference_id)
    WHERE entry_type = 'withdrawal_hold' AND reference_type IS NOT NULL AND reference_id IS NOT NULL;
CREATE UNIQUE INDEX uq_wallet_ledger_withdrawal_refund
    ON wallet_ledger(reference_type, reference_id)
    WHERE entry_type = 'withdrawal_refund' AND reference_type IS NOT NULL AND reference_id IS NOT NULL;
CREATE INDEX idx_withdrawals_user_created ON withdrawals(user_id, created_at DESC);
CREATE INDEX idx_withdrawal_review_logs_request ON withdrawal_review_logs(withdrawal_id, created_at DESC);
CREATE INDEX idx_monthly_bonus_awards_status ON monthly_bonus_awards(award_status, created_at DESC);
CREATE INDEX idx_notifications_user_unread ON user_notifications(user_id, created_at DESC) WHERE read_at IS NULL;

CREATE VIEW qualified_referral_counts AS
SELECT r.referrer_id, COUNT(*)::BIGINT AS qualified_referral_count
FROM referrals r
JOIN users referred ON referred.id = r.referred_user_id
WHERE r.referral_status = 'qualified'
  AND r.risk_flag = FALSE
  AND referred.account_status = 'active'
  AND referred.email_verified = TRUE
GROUP BY r.referrer_id;

CREATE VIEW wallet_available_balances AS
SELECT w.id AS wallet_id, w.user_id, w.currency,
       COALESCE(SUM(l.amount_usd), 0)::NUMERIC(18,6) AS available_balance_usd
FROM wallets w LEFT JOIN wallet_ledger l ON l.wallet_id = w.id
GROUP BY w.id, w.user_id, w.currency;

COMMIT;

-- IMPLEMENTATION GAPS TO COMPLETE IN THE BACKEND (not solved by DDL alone):
-- A) Permission catalogue and least-privilege role mappings are seeded above; review before granting real accounts.
-- A1) task_completions intentionally uses transaction-level enforcement for repeat_policy and daily caps:
--     lock the (user_id, task_id, platform_day) key, count completions, then insert atomically.
-- B) Use qualified_referral_counts for current eligibility; referral_status must also be set only by authorized review logic.
-- C) Implement task completion validation, repeat-policy enforcement, daily limits and configured timezone logic.
-- D) Implement withdrawal transaction: lock wallet row, derive balance from ledger, validate threshold/referral
--    policy snapshot, write one negative hold with a unique idempotency key, prevent self-approval, and refund once
--    on rejection. Mark-paid records settlement metadata and must not debit the wallet a second time.
-- E) Enforce no UPDATE/DELETE on ledger/audit tables through DB grants as well as triggers.
-- F) Encrypt destination details with managed keys; never keep encryption keys in this database.
-- G) Keep provider credentials (including Telegram bot token) in a server-side secret manager/environment.
-- H) Add retention, privacy/deletion policy, legal review, backup restore tests, monitoring and disaster recovery.
-- I) Add updated_at triggers and validate every endpoint with server-side RBAC.
-- J) This schema does not establish business legitimacy, payout-provider approval, or regulatory compliance.
