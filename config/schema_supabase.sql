-- 📦 Schema Supabase - Assessor Pessoal PWA (ADHD-Focused)
-- Versão: 1.0.0
-- Compliance: LGPD/GDPR ready
-- Tenancy: silo_mvp (single-user) → pool_rls (multi-tenant pro tier)

-- ============================================================================
-- EXTENSIONS
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_cron";

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE consent_type AS ENUM (
    'google_calendar_sync',
    'google_tasks_sync',
    'ai_processing',
    'push_notifications',
    'analytics',
    'marketing'
);

CREATE TYPE task_priority AS ENUM ('critical', 'high', 'medium', 'low');

CREATE TYPE task_status AS ENUM ('needsAction', 'completed', 'delegated', 'declined');

CREATE TYPE sync_status AS ENUM ('synced', 'syncing', 'pending', 'error');

CREATE TYPE notification_urgency AS ENUM ('low', 'normal', 'high', 'critical');

CREATE TYPE notification_status AS ENUM ('queued', 'sent', 'delivered', 'failed', 'escalated');

CREATE TYPE tier_type AS ENUM ('free_mvp', 'pro_ai_scheduling', 'enterprise_team');

CREATE TYPE erase_job_status AS ENUM ('pending', 'processing', 'completed', 'failed');

-- ============================================================================
-- CORE TABLES
-- ============================================================================

-- Users (extends Supabase auth.users)
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    supabase_user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    
    -- ADHD Profile
    adhd_profile_active BOOLEAN DEFAULT true NOT NULL,
    buffer_minutes INTEGER DEFAULT 15 CHECK (buffer_minutes BETWEEN 0 AND 60),
    focus_block_minutes INTEGER DEFAULT 45 CHECK (focus_block_minutes BETWEEN 15 AND 120),
    max_consecutive_tasks INTEGER DEFAULT 3 CHECK (max_consecutive_tasks BETWEEN 1 AND 10),
    break_frequency_minutes INTEGER DEFAULT 90 CHECK (break_frequency_minutes BETWEEN 30 AND 180),
    
    -- Preferences
    context_grouping_enabled BOOLEAN DEFAULT true,
    adhd_sound_patterns BOOLEAN DEFAULT true,
    quiet_hours_enabled BOOLEAN DEFAULT false,
    quiet_hours_start TIME,
    quiet_hours_end TIME,
    
    -- Tier & Billing
    tier tier_type DEFAULT 'free_mvp' NOT NULL,
    stripe_customer_id TEXT,
    stripe_subscription_id TEXT,
    
    -- Metadata
    last_login_at TIMESTAMPTZ,
    timezone TEXT DEFAULT 'America/Sao_Paulo'
);

CREATE INDEX idx_users_supabase_id ON users(supabase_user_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_tier ON users(tier);

-- User Consents (LGPD/GDPR compliance)
CREATE TABLE user_consents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    consent_type consent_type NOT NULL,
    granted BOOLEAN NOT NULL DEFAULT false,
    granted_at TIMESTAMPTZ,
    withdrawn_at TIMESTAMPTZ,
    version TEXT NOT NULL,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    
    UNIQUE(user_id, consent_type)
);

CREATE INDEX idx_consents_user_id ON user_consents(user_id);
CREATE INDEX idx_consents_type ON user_consents(consent_type);
CREATE INDEX idx_consents_granted ON user_consents(granted);

-- Priority Rules (weights for AI triage)
CREATE TABLE priority_rules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL UNIQUE,
    deadline_proximity_weight DECIMAL(3,2) DEFAULT 0.40 CHECK (deadline_proximity_weight BETWEEN 0 AND 1),
    task_importance_weight DECIMAL(3,2) DEFAULT 0.30 CHECK (task_importance_weight BETWEEN 0 AND 1),
    energy_match_weight DECIMAL(3,2) DEFAULT 0.20 CHECK (energy_match_weight BETWEEN 0 AND 1),
    context_switching_weight DECIMAL(3,2) DEFAULT 0.10 CHECK (context_switching_weight BETWEEN 0 AND 1),
    max_tasks_per_block INTEGER DEFAULT 3,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_priority_rules_user_id ON priority_rules(user_id);

-- Google OAuth Tokens (encrypted)
CREATE TABLE google_oauth_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL UNIQUE,
    access_token_encrypted BYTEA NOT NULL, -- AES-GCM encrypted
    refresh_token_encrypted BYTEA NOT NULL, -- AES-GCM encrypted
    token_expiry TIMESTAMPTZ NOT NULL,
    refresh_token_expiry TIMESTAMPTZ NOT NULL,
    scope TEXT NOT NULL,
    id_token_encrypted BYTEA, -- AES-GCM encrypted
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    last_rotated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_google_tokens_user_id ON google_oauth_tokens(user_id);

-- Calendar Events (local cache with sync metadata)
CREATE TABLE calendar_events (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    google_event_id TEXT, -- ID do evento no Google Calendar
    summary TEXT NOT NULL,
    description TEXT,
    location TEXT,
    start_datetime TIMESTAMPTZ NOT NULL,
    end_datetime TIMESTAMPTZ NOT NULL,
    timezone TEXT DEFAULT 'America/Sao_Paulo',
    all_day BOOLEAN DEFAULT false,
    
    -- Google Calendar metadata
    color_id TEXT,
    transparency TEXT CHECK (transparency IN ('opaque', 'transparent')),
    visibility TEXT CHECK (visibility IN ('default', 'public', 'private', 'confidential')),
    recurrence_rule TEXT[], -- RRULE array
    parent_event_id TEXT, -- Para eventos recorrentes
    
    -- ADHD-specific metadata
    buffer_before_minutes INTEGER DEFAULT 15,
    buffer_after_minutes INTEGER DEFAULT 15,
    requires_buffer BOOLEAN DEFAULT false,
    priority_override task_priority,
    context_tags TEXT[],
    
    -- Sync metadata
    sync_token TEXT,
    etag TEXT,
    last_synced_at TIMESTAMPTZ,
    sync_status sync_status DEFAULT 'pending',
    conflict_resolution TEXT, -- 'local_wins', 'remote_wins', 'merged'
    
    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    deleted_at TIMESTAMPTZ, -- Soft delete para sync
    
    UNIQUE(user_id, google_event_id)
);

CREATE INDEX idx_events_user_id ON calendar_events(user_id);
CREATE INDEX idx_events_start ON calendar_events(start_datetime);
CREATE INDEX idx_events_end ON calendar_events(end_datetime);
CREATE INDEX idx_events_sync_status ON calendar_events(sync_status);
CREATE INDEX idx_events_deleted ON calendar_events(deleted_at);
CREATE INDEX idx_events_google_id ON calendar_events(google_event_id);

-- Tasks (local cache with sync metadata)
CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    google_task_id TEXT, -- ID da tarefa no Google Tasks
    title TEXT NOT NULL,
    notes TEXT,
    status task_status DEFAULT 'needsAction' NOT NULL,
    due_datetime TIMESTAMPTZ,
    completed_datetime TIMESTAMPTZ,
    
    -- Google Tasks metadata
    position TEXT,
    parent_task_id TEXT,
    order_hint TEXT,
    etag TEXT,
    
    -- AI triage metadata
    priority_score INTEGER CHECK (priority_score BETWEEN 1 AND 10),
    priority_label task_priority,
    reason_code TEXT, -- 'time_pressure', 'context_match', etc.
    reason_detail TEXT,
    estimated_duration_minutes INTEGER,
    suggested_start TIMESTAMPTZ,
    requires_buffer BOOLEAN DEFAULT false,
    context_tags TEXT[],
    
    -- Sync metadata
    sync_token TEXT,
    last_synced_at TIMESTAMPTZ,
    sync_status sync_status DEFAULT 'pending',
    
    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    deleted_at TIMESTAMPTZ -- Soft delete para sync
);

CREATE INDEX idx_tasks_user_id ON tasks(user_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_due ON tasks(due_datetime);
CREATE INDEX idx_tasks_priority ON tasks(priority_score DESC);
CREATE INDEX idx_tasks_sync_status ON tasks(sync_status);
CREATE INDEX idx_tasks_google_id ON tasks(google_task_id);

-- Notifications Queue
CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    body TEXT,
    type TEXT CHECK (type IN ('reminder', 'escalation', 'alert', 'info')) NOT NULL,
    urgency notification_urgency DEFAULT 'normal' NOT NULL,
    
    -- Related entities
    event_id UUID REFERENCES calendar_events(id) ON DELETE SET NULL,
    task_id UUID REFERENCES tasks(id) ON DELETE SET NULL,
    
    -- Scheduling
    scheduled_for TIMESTAMPTZ NOT NULL,
    sent_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    
    -- Escalation
    escalation_level INTEGER DEFAULT 0,
    escalation_config JSONB, -- {levels: [{delay_minutes, method, message}]}
    adhd_optimized BOOLEAN DEFAULT true,
    
    -- Status
    status notification_status DEFAULT 'queued' NOT NULL,
    failure_reason TEXT,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 5,
    next_retry_at TIMESTAMPTZ,
    
    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_notifications_user_id ON notifications(user_id);
CREATE INDEX idx_notifications_scheduled ON notifications(scheduled_for);
CREATE INDEX idx_notifications_status ON notifications(status);
CREATE INDEX idx_notifications_retry ON notifications(next_retry_at) WHERE status = 'queued';

-- Offline Queue (for offline-first sync)
CREATE TABLE offline_queue (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    operation_type TEXT CHECK (operation_type IN ('CREATE', 'UPDATE', 'DELETE')) NOT NULL,
    entity_type TEXT CHECK (entity_type IN ('calendar_event', 'task', 'notification')) NOT NULL,
    entity_id UUID,
    payload JSONB NOT NULL, -- Dados completos da operação
    priority INTEGER DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    
    -- Sync status
    synced BOOLEAN DEFAULT false,
    synced_at TIMESTAMPTZ,
    sync_attempts INTEGER DEFAULT 0,
    last_error TEXT,
    
    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_offline_queue_user_id ON offline_queue(user_id);
CREATE INDEX idx_offline_queue_synced ON offline_queue(synced) WHERE synced = false;
CREATE INDEX idx_offline_queue_priority ON offline_queue(priority DESC, created_at ASC);

-- ============================================================================
-- METERING & BILLING
-- ============================================================================

-- Usage Metering (for billing and limits)
CREATE TABLE usage_metering (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    period_start DATE NOT NULL, -- Primeiro dia do mês
    period_end DATE NOT NULL,   -- Último dia do mês
    
    -- Counters
    google_api_calls INTEGER DEFAULT 0,
    ai_triage_runs INTEGER DEFAULT 0,
    notification_pushes INTEGER DEFAULT 0,
    storage_mb DECIMAL(10,2) DEFAULT 0,
    
    -- Limits by tier
    google_api_calls_limit INTEGER,
    ai_triage_runs_limit INTEGER,
    notification_pushes_limit INTEGER,
    storage_mb_limit INTEGER,
    
    -- Overage
    overage_charges DECIMAL(10,2) DEFAULT 0,
    
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    
    UNIQUE(user_id, period_start)
);

CREATE INDEX idx_metering_user_id ON usage_metering(user_id);
CREATE INDEX idx_metering_period ON usage_metering(period_start, period_end);

-- AI Metering (detailed tracking for cost control)
CREATE TABLE ai_metering (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    request_id UUID NOT NULL,
    model_used TEXT NOT NULL, -- 'gpt-4o-mini', 'qwen-72b', etc.
    input_tokens INTEGER,
    output_tokens INTEGER,
    cost_microcents DECIMAL(10,2), -- Custo em micro-centavos de USD
    latency_ms INTEGER,
    fallback_used BOOLEAN DEFAULT false,
    
    -- Context metadata
    tasks_count INTEGER,
    reason_codes TEXT[],
    
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_ai_metering_user_id ON ai_metering(user_id);
CREATE INDEX idx_ai_metering_created ON ai_metering(created_at);
CREATE INDEX idx_ai_metering_model ON ai_metering(model_used);

-- Feature Flags (per user, for upsell without deploy)
CREATE TABLE feature_flags (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    flag_name TEXT NOT NULL,
    enabled BOOLEAN DEFAULT false NOT NULL,
    metadata JSONB, -- Configurações específicas da flag
    
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    
    UNIQUE(user_id, flag_name)
);

CREATE INDEX idx_feature_flags_user_id ON feature_flags(user_id);
CREATE INDEX idx_feature_flags_enabled ON feature_flags(enabled);

-- Insert default feature flags for new users
INSERT INTO feature_flags (flag_name, enabled, metadata) VALUES
    ('adhd_escalation', true, '{"description": "Alertas escalonados ADHD-friendly"}'),
    ('voice_input', false, '{"description": "Entrada por voz", "tier_required": "pro_ai_scheduling"}'),
    ('multi_calendar', false, '{"description": "Múltiplas contas Google", "tier_required": "pro_ai_scheduling"}'),
    ('ai_scheduling', false, '{"description": "Agendamento automático por IA", "tier_required": "pro_ai_scheduling"}'),
    ('team_collab', false, '{"description": "Colaboração em equipe", "tier_required": "enterprise_team"}'),
    ('custom_themes', false, '{"description": "Temas personalizados", "tier_required": "pro_ai_scheduling"}'),
    ('advanced_analytics', false, '{"description": "Analytics avançado", "tier_required": "pro_ai_scheduling"}')
ON CONFLICT DO NOTHING;

-- ============================================================================
-- COMPLIANCE & AUDIT
-- ============================================================================

-- Audit Trail (immutable, encrypted for sensitive data)
CREATE TABLE audit_trail (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL, -- NULL se usuário deletado
    action TEXT NOT NULL, -- 'create', 'update', 'delete', 'sync', 'consent_grant', etc.
    entity_type TEXT NOT NULL, -- 'user', 'calendar_event', 'task', 'consent', etc.
    entity_id UUID,
    
    -- Change details
    old_values_encrypted BYTEA, -- AES-GCM encrypted (se sensível)
    new_values_encrypted BYTEA, -- AES-GCM encrypted (se sensível)
    changes_summary JSONB, -- Resumo não-sensível das mudanças
    
    -- Context
    ip_address INET,
    user_agent TEXT,
    request_id UUID,
    
    -- Compliance
    lgpd_legal_basis TEXT, -- 'consent', 'legitimate_interest', 'legal_obligation', etc.
    data_category TEXT, -- 'pii', 'sensitive', 'operational', 'anonymized'
    
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_audit_user_id ON audit_trail(user_id);
CREATE INDEX idx_audit_action ON audit_trail(action);
CREATE INDEX idx_audit_entity ON audit_trail(entity_type, entity_id);
CREATE INDEX idx_audit_created ON audit_trail(created_at);
CREATE INDEX idx_audit_lgpd ON audit_trail(lgpd_legal_basis);

-- Data Erase Requests (LGPD/GDPR right to deletion)
CREATE TABLE erase_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    requested_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    deadline TIMESTAMPTZ NOT NULL, -- requested_at + 7 days
    status erase_job_status DEFAULT 'pending' NOT NULL,
    
    -- Processing
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    failure_reason TEXT,
    
    -- Encryption key (efêmera, destruída após processamento)
    encryption_key_id TEXT, -- Referência para chave de criptografia
    
    -- Confirmation
    confirmation_email_sent BOOLEAN DEFAULT false,
    confirmation_sent_at TIMESTAMPTZ,
    webhook_delivered BOOLEAN DEFAULT false,
    webhook_delivered_at TIMESTAMPTZ,
    
    -- Audit
    job_id TEXT UNIQUE, -- ID externo para tracking
    requested_ip INET,
    requested_user_agent TEXT
);

CREATE INDEX idx_erase_requests_user_id ON erase_requests(user_id);
CREATE INDEX idx_erase_requests_status ON erase_requests(status);
CREATE INDEX idx_erase_requests_deadline ON erase_requests(deadline);

-- Data Export Requests (LGPD/GDPR data portability)
CREATE TABLE export_requests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    format TEXT CHECK (format IN ('json', 'ics', 'csv')) NOT NULL,
    include_audit_trail BOOLEAN DEFAULT false,
    date_range_start TIMESTAMPTZ,
    date_range_end TIMESTAMPTZ,
    delivery_method TEXT CHECK (delivery_method IN ('download', 'email')) DEFAULT 'download',
    delivery_email TEXT,
    
    -- Processing
    status TEXT CHECK (status IN ('processing', 'ready', 'failed')) DEFAULT 'processing',
    download_url TEXT,
    url_expires_at TIMESTAMPTZ,
    file_size_bytes BIGINT,
    record_count INTEGER,
    
    -- Audit
    requested_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    completed_at TIMESTAMPTZ,
    failed_at TIMESTAMPTZ,
    failure_reason TEXT
);

CREATE INDEX idx_export_requests_user_id ON export_requests(user_id);
CREATE INDEX idx_export_requests_status ON export_requests(status);

-- DPO Contact Requests
CREATE TABLE dpo_contacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    subject TEXT NOT NULL,
    message TEXT NOT NULL,
    category TEXT CHECK (category IN (
        'data_access', 'data_correction', 'data_deletion',
        'data_portability', 'consent_withdrawal', 'general_inquiry'
    )) NOT NULL,
    email TEXT NOT NULL,
    phone TEXT,
    
    -- Processing
    status TEXT CHECK (status IN ('open', 'in_progress', 'resolved', 'closed')) DEFAULT 'open',
    assigned_to TEXT,
    response TEXT,
    
    -- SLA
    requested_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    first_response_at TIMESTAMPTZ,
    resolved_at TIMESTAMPTZ,
    sla_deadline TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '5 days')
);

CREATE INDEX idx_dpo_contacts_user_id ON dpo_contacts(user_id);
CREATE INDEX idx_dpo_contacts_status ON dpo_contacts(status);
CREATE INDEX idx_dpo_contacts_sla ON dpo_contacts(sla_deadline) WHERE status != 'closed';

-- ============================================================================
-- SYNC METADATA
-- ============================================================================

-- Sync Tokens (per user, per service)
CREATE TABLE sync_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    service TEXT CHECK (service IN ('google_calendar', 'google_tasks')) NOT NULL,
    sync_token TEXT NOT NULL,
    next_sync_token TEXT,
    expiration TIMESTAMPTZ,
    
    -- Status
    last_sync_at TIMESTAMPTZ,
    sync_status sync_status DEFAULT 'pending',
    conflicts_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    
    UNIQUE(user_id, service)
);

CREATE INDEX idx_sync_tokens_user_id ON sync_tokens(user_id);
CREATE INDEX idx_sync_tokens_service ON sync_tokens(service);

-- Conflict Log
CREATE TABLE sync_conflicts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    event_id UUID REFERENCES calendar_events(id) ON DELETE SET NULL,
    conflict_type TEXT CHECK (conflict_type IN (
        'double_booking', 'overlapping', 'time_shift', 'duplicate'
    )) NOT NULL,
    
    -- Versions
    local_version JSONB,
    remote_version JSONB,
    
    -- Resolution
    resolution TEXT CHECK (resolution IN (
        'local_wins', 'remote_wins', 'merged', 'manual_required'
    )) NOT NULL,
    resolution_detail TEXT,
    
    resolved_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    audit_log_id UUID REFERENCES audit_trail(id) ON DELETE SET NULL
);

CREATE INDEX idx_conflicts_user_id ON sync_conflicts(user_id);
CREATE INDEX idx_conflicts_resolved ON sync_conflicts(resolved_at);
CREATE INDEX idx_conflicts_type ON sync_conflicts(conflict_type);

-- ============================================================================
-- TRIGGERS & FUNCTIONS
-- ============================================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to tables with updated_at
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_priority_rules_updated_at BEFORE UPDATE ON priority_rules
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_google_oauth_tokens_updated_at BEFORE UPDATE ON google_oauth_tokens
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_usage_metering_updated_at BEFORE UPDATE ON usage_metering
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_feature_flags_updated_at BEFORE UPDATE ON feature_flags
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================================
-- RLS POLICIES (para multi-tenant pro tier)
-- ============================================================================

-- Enable RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE priority_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE google_oauth_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE offline_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_metering ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_metering ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_trail ENABLE ROW LEVEL SECURITY;
ALTER TABLE erase_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE export_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE dpo_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_conflicts ENABLE ROW LEVEL SECURITY;

-- Policies para usuários acessarem apenas seus próprios dados
CREATE POLICY users_isolation_policy ON users
    FOR ALL USING (supabase_user_id = auth.uid());

CREATE POLICY consents_isolation_policy ON user_consents
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY priority_rules_isolation_policy ON priority_rules
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY google_tokens_isolation_policy ON google_oauth_tokens
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY calendar_events_isolation_policy ON calendar_events
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY tasks_isolation_policy ON tasks
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY notifications_isolation_policy ON notifications
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY offline_queue_isolation_policy ON offline_queue
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY metering_isolation_policy ON usage_metering
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY ai_metering_isolation_policy ON ai_metering
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY feature_flags_isolation_policy ON feature_flags
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY audit_trail_user_policy ON audit_trail
    FOR SELECT USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY erase_requests_isolation_policy ON erase_requests
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY export_requests_isolation_policy ON export_requests
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY dpo_contacts_isolation_policy ON dpo_contacts
    FOR ALL USING (
        user_id IS NULL OR 
        user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid())
    );

CREATE POLICY sync_tokens_isolation_policy ON sync_tokens
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

CREATE POLICY sync_conflicts_isolation_policy ON sync_conflicts
    FOR ALL USING (user_id IN (SELECT id FROM users WHERE supabase_user_id = auth.uid()));

-- ============================================================================
-- CRON JOBS (via pg_cron)
-- ============================================================================

-- Job para processar notificações pendentes (a cada minuto)
SELECT cron.schedule(
    'process-notifications',
    '* * * * *',
    $$
    UPDATE notifications
    SET status = 'failed',
        failure_reason = 'Max retries exceeded',
        next_retry_at = NULL
    WHERE status = 'queued'
      AND retry_count >= max_retries
      AND next_retry_at <= NOW()
    $$
);

-- Job para verificar deadlines de erase requests (diário)
SELECT cron.schedule(
    'check-erase-deadlines',
    '0 0 * * *',
    $$
    UPDATE erase_requests
    SET status = 'failed',
        failed_at = NOW(),
        failure_reason = 'SLA deadline exceeded'
    WHERE status IN ('pending', 'processing')
      AND deadline < NOW()
    $$
);

-- Job para limpar URLs de expiração de export (diário)
SELECT cron.schedule(
    'cleanup-expired-exports',
    '0 2 * * *',
    $$
    UPDATE export_requests
    SET download_url = NULL,
        url_expires_at = NULL
    WHERE url_expires_at < NOW()
    $$
);

-- Job para resetar metering mensal (primeiro dia do mês)
SELECT cron.schedule(
    'reset-monthly-metering',
    '0 0 1 * *',
    $$
    INSERT INTO usage_metering (user_id, period_start, period_end, google_api_calls_limit, ai_triage_runs_limit, notification_pushes_limit, storage_mb_limit)
    SELECT 
        u.id,
        DATE_TRUNC('month', NOW()),
        (DATE_TRUNC('month', NOW()) + INTERVAL '1 month - 1 day')::date,
        CASE u.tier
            WHEN 'free_mvp' THEN 1000
            WHEN 'pro_ai_scheduling' THEN 10000
            WHEN 'enterprise_team' THEN 100000
        END,
        CASE u.tier
            WHEN 'free_mvp' THEN 100
            WHEN 'pro_ai_scheduling' THEN 1000
            WHEN 'enterprise_team' THEN 10000
        END,
        CASE u.tier
            WHEN 'free_mvp' THEN 500
            WHEN 'pro_ai_scheduling' THEN 5000
            WHEN 'enterprise_team' THEN 50000
        END,
        CASE u.tier
            WHEN 'free_mvp' THEN 100
            WHEN 'pro_ai_scheduling' THEN 1000
            WHEN 'enterprise_team' THEN 10000
        END
    FROM users u
    ON CONFLICT (user_id, period_start) DO NOTHING
    $$
);

-- ============================================================================
-- VIEWS (para queries comuns)
-- ============================================================================

-- View para status de sync do usuário
CREATE VIEW user_sync_status AS
SELECT 
    u.id AS user_id,
    u.email,
    st_calendar.sync_status AS calendar_sync_status,
    st_calendar.last_sync_at AS calendar_last_sync,
    st_tasks.sync_status AS tasks_sync_status,
    st_tasks.last_sync_at AS tasks_last_sync,
    (SELECT COUNT(*) FROM calendar_events ce 
     WHERE ce.user_id = u.id AND ce.sync_status = 'pending') AS pending_calendar_changes,
    (SELECT COUNT(*) FROM tasks t 
     WHERE t.user_id = u.id AND t.sync_status = 'pending') AS pending_task_changes,
    (SELECT COUNT(*) FROM sync_conflicts sc 
     WHERE sc.user_id = u.id AND sc.resolved_at > NOW() - INTERVAL '24 hours') AS conflicts_last_24h
FROM users u
LEFT JOIN sync_tokens st_calendar ON st_calendar.user_id = u.id AND st_calendar.service = 'google_calendar'
LEFT JOIN sync_tokens st_tasks ON st_tasks.user_id = u.id AND st_tasks.service = 'google_tasks';

-- View para uso atual vs limites
CREATE VIEW current_usage AS
SELECT 
    u.id AS user_id,
    u.email,
    u.tier,
    um.period_start,
    um.google_api_calls,
    um.google_api_calls_limit,
    um.ai_triage_runs,
    um.ai_triage_runs_limit,
    um.notification_pushes,
    um.notification_pushes_limit,
    um.storage_mb,
    um.storage_mb_limit,
    ROUND((um.google_api_calls::decimal / NULLIF(um.google_api_calls_limit, 0)) * 100, 2) AS google_api_usage_pct,
    ROUND((um.ai_triage_runs::decimal / NULLIF(um.ai_triage_runs_limit, 0)) * 100, 2) AS ai_triage_usage_pct,
    ROUND((um.notification_pushes::decimal / NULLIF(um.notification_pushes_limit, 0)) * 100, 2) AS notification_usage_pct,
    ROUND((um.storage_mb::decimal / NULLIF(um.storage_mb_limit, 0)) * 100, 2) AS storage_usage_pct,
    um.overage_charges
FROM users u
LEFT JOIN usage_metering um ON um.user_id = u.id 
    AND um.period_start = DATE_TRUNC('month', NOW());

-- View para feature flags ativas do usuário
CREATE VIEW user_feature_flags AS
SELECT 
    u.id AS user_id,
    ff.flag_name,
    ff.enabled,
    ff.metadata,
    u.tier
FROM users u
JOIN feature_flags ff ON ff.user_id = u.id;

-- ============================================================================
-- INITIAL DATA
-- ============================================================================

-- Inserir feature flags padrão (já feito acima com ON CONFLICT)

-- Comentar: Executar migrations via Supabase CLI em produção
-- supabase db push
