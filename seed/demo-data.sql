-- НАСТОЯЩИЕ CSR, А НЕ ЗАГЛУШКИ (GitLab dexion #890).
--
-- Здесь стояло `'-----BEGIN CERTIFICATE REQUEST-----\nSEED-FAKE-CSR\n-----END …'`
-- в ОБЫЧНЫХ кавычках, то есть `\n` попадал в базу обратным слэшем и буквой, а
-- не переводом строки. Все 766 заявок были неодобряемы: сервер справедливо
-- отвечал `csr: invalid PEM`, а четыре ключа — `ssh_public_key: invalid OpenSSH
-- public key`. Демонстрация, которую README обещает «посмотреть за одну
-- команду», обрывалась на первом же осмысленном действии — нажатии «Одобрить».
--
-- Теперь это настоящий CSR (EC P-256) в escape-строке `E'…'`, где `\n` —
-- перевод строки. Ключ один на все строки: демонстрационные данные показывают
-- очередь и интерфейс, а не парк уникальных устройств.

-- seed-dev-data.sql — deterministic, idempotent fake data for local dev / e2e.
--
-- Seeds devices, cert_requests (every purpose × every lifecycle status,
-- including non-wifi purposes and ca_pending/superseded, + revoked + soon-
-- expiring + a 30-day creation trend), audit_log (every UI-filterable
-- action, including a service_account actor), networks (active/disabled
-- wifi + wired, one with the macOS-MDM toggle on), service_accounts,
-- webhook_endpoints + webhook_deliveries, issuer_profiles (all 5 purposes),
-- system_settings (non-default values on every tab), and local_credentials
-- for two seed users. Inserts directly into Postgres — bypasses Vault/
-- Keycloak so it runs against a bare dev DB.
--
-- Idempotent for devices/cert_requests/networks/service_accounts/webhooks:
-- tagged and purged on re-run.
--   devices.serial_number         LIKE 'SEED-%'
--   networks.ssid                 LIKE 'SEED-%'
--   service_accounts.name         LIKE 'SEED-%'
--   webhook_endpoints.name        LIKE 'SEED-%'
-- issuer_profiles/system_settings are singletons per purpose / per instance
-- -- upserted (INSERT ... ON CONFLICT DO UPDATE), not purged.
-- audit_log seed rows (actor = 'seed@wifi.local' or a SEED service account)
-- are NOT purged -- see the append-only note below -- and accumulate across
-- re-runs instead.
--
-- Usage:  make seed-dev      (or)  psql "$DB_URL" -f scripts/seed-dev-data.sql
--
-- These cert_requests inserts bypass the license usage ledger (Go-side only,
-- server/internal/license/ledger.go) -- license/status will report
-- tamper=true (anchor_absent_with_prior_usage) after this runs until you
-- also call `make reanchor-license` (or POST /api/v1/license/reanchor) with
-- the server running. `make e2e-local` already does this for you.

BEGIN;

-- ── purge previous seed (FK-safe order) ──────────────────────────────────────
-- audit_log is intentionally NOT purged here: migration 034 made it
-- append-only at the DB level (trigger-enforced, no bypass by design --
-- dexion #40) specifically so nothing, including this script, can delete
-- rows. Re-running this script accumulates additional seed@wifi.local
-- audit rows rather than resetting them -- consistent with audit_log's own
-- append-only contract, and harmless for local dev.
-- scep_pending.cert_request_id and local_credentials.email both cascade
-- (ON DELETE CASCADE) from cert_requests/users respectively -- no explicit
-- purge needed for either.
DELETE FROM cert_requests
 WHERE device_id IN (SELECT id FROM devices WHERE serial_number LIKE 'SEED-%');
DELETE FROM device_logs
 WHERE device_id IN (SELECT id FROM devices WHERE serial_number LIKE 'SEED-%');
DELETE FROM devices    WHERE serial_number LIKE 'SEED-%';
DELETE FROM networks   WHERE ssid LIKE 'SEED-%' OR display_name LIKE 'SEED-%';
DELETE FROM user_roles WHERE email LIKE '%seed.wifi.local';
DELETE FROM users      WHERE email LIKE '%seed.wifi.local';
DELETE FROM webhook_deliveries
 WHERE endpoint_id IN (SELECT id FROM webhook_endpoints WHERE name LIKE 'SEED-%');
DELETE FROM webhook_endpoints  WHERE name LIKE 'SEED-%';
DELETE FROM service_accounts   WHERE name LIKE 'SEED-%';

-- ── devices: 45 across OS (macos 50% / windows 33% / linux 17%) ──────────────
INSERT INTO devices (serial_number, username, os, last_seen_at, agent_version, os_version, created_at)
SELECT
    ('SEED-' || lpad(i::text, 4, '0')),
    ('user' || lpad(i::text, 2, '0') || '@wifi.local'),
    CASE WHEN i % 6 < 3 THEN 'macos'
         WHEN i % 6 < 5 THEN 'windows'
         ELSE 'linux' END,
    NOW() - (i || ' hours')::interval,                       -- last_seen spread
    -- Some devices report no version (old agents) so the "— без версии" filter
    -- has data to match.
    CASE WHEN i % 7 = 0 THEN '' WHEN i % 6 < 3 THEN '1.4.5' ELSE '1.4.2' END,
    CASE WHEN i % 6 < 3 THEN '15.5'  WHEN i % 6 < 5 THEN '11 24H2' ELSE 'Ubuntu 24.04' END,
    NOW() - (i || ' days')::interval                         -- created over ~45d
FROM generate_series(1, 45) AS s(i);

-- ── cert_requests: one per device, status by bucket ─────────────────────────
-- Buckets (by device serial ordinal):
--   1..10  pending      11..15 approved     16..18 installing
--   19..38 installed    39..42 rejected     43..45 vault_failed
-- Of the installed: serials 19..24 expire within 7 days (dashboard "expiring"),
-- serials 25..29 are revoked (installed + revoked_at set).
INSERT INTO cert_requests (
    device_id, status, csr_pem, attestation, attest_result,
    approved_by, approved_at, rejected_by, rejected_at, reject_reason,
    vault_serial, cert_pem, expires_at, revoked_at, revoked_by,
    created_at, updated_at
)
SELECT
    d.id,
    b.status,
    E'-----BEGIN CERTIFICATE REQUEST-----\nMIHZMIGAAgEAMB4xHDAaBgNVBAMME2RlbW9AYWxhdHlyLmV4YW1wbGUwWTATBgcq\nhkjOPQIBBggqhkjOPQMBBwNCAATtcCWwl4xtQtA4peRpvIHIrrFdFnlSUaWwqHjn\nhgOYLM3r00LagoRRUTABjTyLIlKxlIXaKaaZGLS0ZtFjiu2AoAAwCgYIKoZIzj0E\nAwIDSAAwRQIhAL2Nv4yu/Z+C14lfGvYG2dCxLTC3JqfEcBiPm6ApzCj7AiBxamD3\nQz7rIoXj4WST0Bq0XrbxIMR5A0t2z9xEzkQq3w==\n-----END CERTIFICATE REQUEST-----',
    '{"platform":"tpm2"}'::jsonb,
    -- `pending` получает вердикт НАРАВНЕ с остальными (GitLab dexion #890).
    --
    -- Раньше здесь стояло только ('installed','installing','approved'), то есть
    -- у заявок в ожидании вердикта не было вовсе. На ступени `required` сервер
    -- справедливо отвечал «вердикт аттестации по заявке отсутствует», и первое
    -- же осмысленное действие в демонстрации — нажать «Одобрить» — не работало
    -- НИ НА ОДНОЙ заявке. Легенда строки это и так утверждает: рядом стоит
    -- attestation = '{"platform":"tpm2"}'.
    CASE WHEN b.status IN ('installed','installing','approved','pending')
         THEN jsonb_build_object(
                'ok', true,
                'level', b.attest_level,
                'manufacturer', CASE d.os WHEN 'macos' THEN 'Apple'
                                          WHEN 'windows' THEN 'Intel'
                                          ELSE 'Generic TPM' END)
         ELSE NULL END,
    CASE WHEN b.status IN ('approved','installing','installed') THEN 'admin@wifi.local' END,
    CASE WHEN b.status IN ('approved','installing','installed') THEN NOW() - '2 days'::interval END,
    CASE WHEN b.status = 'rejected' THEN 'admin@wifi.local' END,
    CASE WHEN b.status = 'rejected' THEN NOW() - '3 days'::interval END,
    CASE WHEN b.status = 'rejected' THEN 'Attestation failed: untrusted TPM' END,
    CASE WHEN b.status IN ('installing','installed')
         THEN ('1a:2b:' || lpad(b.n::text,2,'0') || ':' || lpad(b.n::text,2,'0')) END,
    CASE WHEN b.status = 'installed'
         THEN '-----BEGIN CERTIFICATE-----\nSEED-FAKE-CERT\n-----END CERTIFICATE-----' END,
    b.expires_at,
    b.revoked_at,
    CASE WHEN b.revoked_at IS NOT NULL THEN 'admin@wifi.local' END,
    -- Quadratic day offset (n² mod 30) clusters issuance onto some days and
    -- leaves others empty → a varied trend chart instead of a flat fence.
    NOW() - (((b.n * b.n) % 30) || ' days')::interval,
    NOW() - '1 day'::interval
FROM (
    SELECT
        n,
        ('SEED-' || lpad(n::text, 4, '0')) AS serial,
        CASE
            WHEN n <= 10 THEN 'pending'
            WHEN n <= 15 THEN 'approved'
            WHEN n <= 18 THEN 'installing'
            WHEN n <= 38 THEN 'installed'
            WHEN n <= 42 THEN 'rejected'
            ELSE 'vault_failed'
        END AS status,
        CASE WHEN n % 4 = 0 THEN 'full'
             WHEN n % 4 = 1 THEN 'hardware'
             WHEN n % 4 = 2 THEN 'hardware_no_ekcert'
             ELSE 'software' END AS attest_level,
        -- expires: 19..24 soon (<7d), other installed in 1-3y, else NULL
        CASE
            WHEN n BETWEEN 19 AND 24 THEN NOW() + ((n - 18) || ' days')::interval
            WHEN n BETWEEN 25 AND 38 THEN NOW() + ((n * 20) || ' days')::interval
            ELSE NULL
        END AS expires_at,
        -- revoked: 25..29 (installed + revoked)
        CASE WHEN n BETWEEN 25 AND 29 THEN NOW() - '5 days'::interval ELSE NULL END AS revoked_at
    FROM generate_series(1, 45) AS g(n)
) b
JOIN devices d ON d.serial_number = b.serial;

-- ── trend filler: varied issuance per day so the dashboard chart shows a real
--    shape with 1-, 2- and 3-digit days (not a flat fence). These extra
--    'installed' requests hang off SEED-0001 and are purged by the same
--    device_id cleanup above. Days without an entry render as a zero/empty bar.
--    Marked revoked (revoked_at set) so they fall outside
--    idx_cert_requests_active_purpose's partial WHERE (status IN
--    (...) AND revoked_at IS NULL) -- otherwise every row past the first
--    collides on (device_id, purpose, user_identity) since they all hang off
--    the same SEED-0001 device/purpose. GetCertTrend's query only filters on
--    status, not revoked_at, so the chart count is unaffected.
INSERT INTO cert_requests (device_id, status, csr_pem, vault_serial, cert_pem, expires_at, revoked_at, revoked_by, created_at, updated_at)
SELECT
    (SELECT id FROM devices WHERE serial_number = 'SEED-0001'),
    'installed',
    E'-----BEGIN CERTIFICATE REQUEST-----\nMIHZMIGAAgEAMB4xHDAaBgNVBAMME2RlbW9AYWxhdHlyLmV4YW1wbGUwWTATBgcq\nhkjOPQIBBggqhkjOPQMBBwNCAATtcCWwl4xtQtA4peRpvIHIrrFdFnlSUaWwqHjn\nhgOYLM3r00LagoRRUTABjTyLIlKxlIXaKaaZGLS0ZtFjiu2AoAAwCgYIKoZIzj0E\nAwIDSAAwRQIhAL2Nv4yu/Z+C14lfGvYG2dCxLTC3JqfEcBiPm6ApzCj7AiBxamD3\nQz7rIoXj4WST0Bq0XrbxIMR5A0t2z9xEzkQq3w==\n-----END CERTIFICATE REQUEST-----',
    ('aa:bb:' || lpad(d.days_ago::text, 2, '0') || ':' || lpad(g::text, 3, '0')),
    E'-----BEGIN CERTIFICATE-----\nMIIBkTCCATegAwIBAgIUGhKanCuzP6gW9SYjmi/Z9z1bnHgwCgYIKoZIzj0EAwIw\nHjEcMBoGA1UEAwwTZGVtb0BhbGF0eXIuZXhhbXBsZTAeFw0yNjA5MjAxNTM4MDBa\nFw0zNjA5MTcxNTM4MDBaMB4xHDAaBgNVBAMME2RlbW9AYWxhdHlyLmV4YW1wbGUw\nWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATtcCWwl4xtQtA4peRpvIHIrrFdFnlS\nUaWwqHjnhgOYLM3r00LagoRRUTABjTyLIlKxlIXaKaaZGLS0ZtFjiu2Ao1MwUTAd\nBgNVHQ4EFgQU7YF6x9VrdGdmpCX+9UhA044eMTEwHwYDVR0jBBgwFoAU7YF6x9Vr\ndGdmpCX+9UhA044eMTEwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBF\nAiEAuYwQRD0qOmRZhbLWnVa0PW0OncFgw2IILzk7VUf/2eoCIAbH3oojnojZwqa8\nokh2dCCuX7zAPGspWKjDhG2iAoRf\n-----END CERTIFICATE-----',
    NOW() + '365 days'::interval,
    NOW() - (d.days_ago || ' days')::interval + '1 minute'::interval,
    'seed@wifi.local',
    NOW() - (d.days_ago || ' days')::interval,
    NOW()
FROM (VALUES
    (1, 7), (2, 142), (3, 1), (4, 23), (5, 4), (6, 88), (8, 12),
    (10, 2), (12, 56), (14, 113), (16, 3), (18, 31), (20, 9),
    (23, 167), (26, 5), (29, 44)
) AS d(days_ago, cnt)
CROSS JOIN generate_series(1, d.cnt) AS g;

-- ── audit_log: every action in requests.go's validActions whitelist, spread
--    over 14 days, alternating actor_kind so the "API" badge (service
--    account channel) shows up too, not just human web-session rows.
INSERT INTO audit_log (actor, actor_kind, action, target_id, details, created_at)
SELECT
    CASE WHEN i % 5 = 0 THEN 'SEED-CI-Approver' ELSE 'seed@wifi.local' END,
    CASE WHEN i % 5 = 0 THEN 'service_account' ELSE 'user' END,
    (ARRAY[
        'approve','reject','revoke','enroll','request_logs','cancel_logs_request','delete_device_log',
        'network.create','network.disable','network.restore','network.delete',
        'create_service_account','delete_service_account','enable_service_account','disable_service_account',
        'rotate_enrollment_token',
        'create_local_user','change_password','reset_local_password',
        'local_login_success','local_login_failed',
        'create_webhook','update_webhook','delete_webhook','enable_webhook','disable_webhook','test_webhook',
        'test_issuer_connection','upsert_issuer_profile',
        'update_system_settings','set_device_issue_policy_override',
        'ssh_allowed_principals_changed',
        'user.set_roles','device.revoke','device.revoke.cert','user.revoke_certs','user.revoke_certs.cert'
    ])[1 + (i % 36)],
    NULL,
    jsonb_build_object(
        'serial_number', ('SEED-' || lpad((1 + (i % 45))::text, 4, '0')),
        'vault_serial',  ('1a:2b:' || lpad(i::text,2,'0') || ':' || lpad(i::text,2,'0')),
        'note',          format('seed audit entry %s', i)
    ),
    NOW() - (i || ' hours')::interval
FROM generate_series(1, 108) AS s(i);

-- ── users: every role combination + a disabled one + a no-roles one ─────────
INSERT INTO users (email, username, enabled) VALUES
    ('admin.only@seed.wifi.local',     'admin.only@seed.wifi.local',     true),
    ('approver.only@seed.wifi.local',  'approver.only@seed.wifi.local',  true),
    ('viewer.only@seed.wifi.local',    'viewer.only@seed.wifi.local',    true),
    ('admin.approver@seed.wifi.local', 'admin.approver@seed.wifi.local', true),
    ('approver.viewer@seed.wifi.local','approver.viewer@seed.wifi.local',true),
    ('admin.viewer@seed.wifi.local',   'admin.viewer@seed.wifi.local',   true),
    ('all.roles@seed.wifi.local',      'all.roles@seed.wifi.local',      true),
    ('no.roles@seed.wifi.local',       'no.roles@seed.wifi.local',       true),
    ('blocked.viewer@seed.wifi.local', 'blocked.viewer@seed.wifi.local', false);

INSERT INTO user_roles (email, roles) VALUES
    ('admin.only@seed.wifi.local',     ARRAY['cert-admin']),
    ('approver.only@seed.wifi.local',  ARRAY['cert-approver']),
    ('viewer.only@seed.wifi.local',    ARRAY['cert-viewer']),
    ('admin.approver@seed.wifi.local', ARRAY['cert-admin','cert-approver']),
    ('approver.viewer@seed.wifi.local',ARRAY['cert-approver','cert-viewer']),
    ('admin.viewer@seed.wifi.local',   ARRAY['cert-admin','cert-viewer']),
    ('all.roles@seed.wifi.local',      ARRAY['cert-admin','cert-approver','cert-viewer']),
    ('no.roles@seed.wifi.local',       ARRAY[]::TEXT[]),
    ('blocked.viewer@seed.wifi.local', ARRAY['cert-viewer']);

-- ── networks: 3 active wifi + 1 disabled wifi + 1 active wired ──────────────
INSERT INTO networks (kind, ssid, display_name, disabled_at) VALUES
    ('wifi',  'SEED-Corp',   'Corporate Wi-Fi',  NULL),
    ('wifi',  'SEED-Guest',  'Guest Wi-Fi',      NULL),
    ('wifi',  'SEED-IoT',    'IoT Network',      NULL),
    ('wifi',  'SEED-Legacy', 'Legacy (retired)', NOW() - '10 days'::interval),
    ('wired', NULL,          'SEED-Corp Wired',  NULL);

-- One network with the per-network macOS-MDM toggle on, so the "macOS через
-- MDM" column shows both states, not always off.
UPDATE networks SET macos_agent_profile_disabled = true WHERE ssid = 'SEED-IoT';

-- ── non-wifi purposes + statuses the main bucket generator above never
--    produces (ca_pending, superseded) -- each row hangs off one of
--    SEED-0001..SEED-0012's EXISTING wifi cert_request; purpose differs, so
--    idx_cert_requests_active_purpose/idx_cert_requests_pending_dedup never
--    collide with that device's wifi row (different (purpose,user_identity)
--    slot). ssh rows: csr_pem is NOT NULL but empty ('') per 029_ssh.sql --
--    the real key material is ssh_public_key -- and vault_serial is a plain
--    decimal string (Vault SSH CA convention), not the hex-colon X.509 style.
INSERT INTO cert_requests (
    device_id, purpose, user_identity, status, csr_pem, ssh_public_key,
    attestation, attest_result, approved_by, approved_at,
    rejected_by, rejected_at, reject_reason,
    vault_serial, vault_error, cert_pem, expires_at, revoked_at, revoked_by,
    created_at, updated_at
)
SELECT
    (SELECT id FROM devices WHERE serial_number = v.serial),
    v.purpose, v.user_identity, v.status, v.csr_pem, v.ssh_public_key,
    v.attestation, v.attest_result, v.approved_by, v.approved_at,
    v.rejected_by, v.rejected_at, v.reject_reason,
    v.vault_serial, v.vault_error, v.cert_pem, v.expires_at, v.revoked_at, v.revoked_by,
    v.created_at, v.updated_at
FROM (VALUES
    -- user_mtls: installed
    ('SEED-0001', 'user_mtls', 'alice@wifi.local', 'installed',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-MTLS-CSR\n-----END CERTIFICATE REQUEST-----'::text, NULL::text,
     '{"platform":"secure_enclave"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Apple'),
     'admin@wifi.local'::text, NOW() - '4 days'::interval,
     NULL::text, NULL::timestamptz, NULL::text,
     '2a:2b:01:01'::text, NULL::text,
     '-----BEGIN CERTIFICATE-----\nSEED-MTLS-CERT\n-----END CERTIFICATE-----'::text,
     NOW() + '2 years'::interval, NULL::timestamptz, NULL::text,
     NOW() - '4 days'::interval, NOW() - '3 days'::interval),
    -- user_mtls: pending
    ('SEED-0002', 'user_mtls', 'bob@wifi.local', 'pending',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-MTLS-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"secure_enclave"}'::jsonb, NULL,
     NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '2 hours'::interval, NOW() - '2 hours'::interval),
    -- ad_logon: approved (not yet issued)
    ('SEED-0003', 'ad_logon', 'CORP\carol', 'approved',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-ADLOGON-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'hardware', 'manufacturer', 'Intel'),
     'admin@wifi.local', NOW() - '1 hour'::interval,
     NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '3 hours'::interval, NOW() - '1 hour'::interval),
    -- ad_logon: ca_pending (async SCEP issuance in flight -- see scep_pending insert below)
    ('SEED-0004', 'ad_logon', 'CORP\dave', 'ca_pending',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-ADLOGON-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Intel'),
     'admin@wifi.local', NOW() - '30 minutes'::interval,
     NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '1 hour'::interval, NOW() - '30 minutes'::interval),
    -- ssh: installed
    ('SEED-0005', 'ssh', 'deploy-bot', 'installed',
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIOWmDpLVNCUxL+4yOG2f3aj6VnM3cW92W+WfgE1M9Sf demo@alatyr.example',
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Infineon'),
     'admin@wifi.local', NOW() - '6 days'::interval,
     NULL, NULL, NULL,
     '4815162342'::text, NULL,
     'ssh-ed25519-cert-v01@openssh.com SEEDFAKEsshCERTbase64material==',
     NOW() + '90 days'::interval, NULL, NULL,
     NOW() - '6 days'::interval, NOW() - '5 days'::interval),
    -- k8s: installed -- a live kubectl credential (GitLab dexion #162).
    -- expires_at is deliberately HOURS away, not years: the k8s purpose is
    -- 12h by design because a Kubernetes API server performs no revocation
    -- check, so expiry is the only control that withdraws access. Seed data
    -- that showed a year here would misrepresent the whole point of the
    -- purpose on the demo instance.
    ('SEED-0011', 'k8s', 'alice@wifi.local', 'installed',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-K8S-CSR\n-----END CERTIFICATE REQUEST-----'::text, NULL::text,
     '{"platform":"secure_enclave"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Apple'),
     'admin@wifi.local'::text, NOW() - '3 hours'::interval,
     NULL::text, NULL::timestamptz, NULL::text,
     '5c:0d:e5:01'::text, NULL::text,
     '-----BEGIN CERTIFICATE-----\nSEED-K8S-CERT\n-----END CERTIFICATE-----'::text,
     NOW() + '9 hours'::interval, NULL::timestamptz, NULL::text,
     NOW() - '3 hours'::interval, NOW() - '3 hours'::interval),
    -- k8s: pending -- awaiting a human. This purpose is never auto-approved,
    -- which matters more here than elsewhere: a certificate issued in error
    -- cannot be called back, only waited out.
    ('SEED-0012', 'k8s', 'bob@wifi.local', 'pending',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-K8S-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"tpm2"}'::jsonb, NULL,
     NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '30 minutes'::interval, NOW() - '30 minutes'::interval),
    -- ssh: superseded (old identity slot) -- replaced by the row right after it
    ('SEED-0006', 'ssh', 'alice', 'superseded',
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIOWmDpLVNCUxL+4yOG2f3aj6VnM3cW92W+WfgE1M9Sf demo@alatyr.example',
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Infineon'),
     'admin@wifi.local', NOW() - '20 days'::interval,
     NULL, NULL, NULL,
     '9192631770'::text, NULL,
     'ssh-ed25519-cert-v01@openssh.com SEEDOLDsshCERTbase64material==',
     NOW() + '60 days'::interval, NULL, NULL,
     NOW() - '20 days'::interval, NOW() - '10 days'::interval),
    -- ssh: installed, same (device,purpose,user_identity) slot as the superseded
    -- row above -- the CURRENT active one; only one non-superseded row may
    -- occupy this slot, which is exactly what idx_cert_requests_active_purpose
    -- enforces (superseded is excluded from its WHERE, so no conflict).
    ('SEED-0006', 'ssh', 'alice', 'installed',
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIOWmDpLVNCUxL+4yOG2f3aj6VnM3cW92W+WfgE1M9Sf demo@alatyr.example',
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Infineon'),
     'admin@wifi.local', NOW() - '9 days'::interval,
     NULL, NULL, NULL,
     '2718281828'::text, NULL,
     'ssh-ed25519-cert-v01@openssh.com SEEDNEWsshCERTbase64material==',
     NOW() + '90 days'::interval, NULL, NULL,
     NOW() - '9 days'::interval, NOW() - '8 days'::interval),
    -- ssh: pending
    ('SEED-0007', 'ssh', 'frank', 'pending',
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIOWmDpLVNCUxL+4yOG2f3aj6VnM3cW92W+WfgE1M9Sf demo@alatyr.example',
     '{"platform":"tpm2"}'::jsonb, NULL,
     NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '15 minutes'::interval, NOW() - '15 minutes'::interval),
    -- user_mtls: rejected
    ('SEED-0008', 'user_mtls', 'grace@wifi.local', 'rejected',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-MTLS-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"software"}'::jsonb, NULL,
     NULL, NULL,
     'admin@wifi.local', NOW() - '2 days'::interval, 'Attestation failed: untrusted TPM',
     NULL, NULL, NULL, NULL, NULL, NULL,
     NOW() - '2 days'::interval, NOW() - '2 days'::interval),
    -- ad_logon: vault_failed (with a real vault_error message)
    ('SEED-0009', 'ad_logon', 'CORP\heidi', 'vault_failed',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-ADLOGON-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'hardware', 'manufacturer', 'Intel'),
     'admin@wifi.local', NOW() - '1 day'::interval,
     NULL, NULL, NULL,
     NULL, 'Vault PKI unreachable: dial tcp 10.0.1.5:8200: connect: connection refused',
     NULL, NULL, NULL, NULL,
     NOW() - '1 day'::interval, NOW() - '1 day'::interval),
    -- user_mtls: installed + revoked
    ('SEED-0010', 'user_mtls', 'ivan@wifi.local', 'installed',
     '-----BEGIN CERTIFICATE REQUEST-----\nSEED-MTLS-CSR\n-----END CERTIFICATE REQUEST-----', NULL,
     '{"platform":"tpm2"}'::jsonb,
     jsonb_build_object('ok', true, 'level', 'hardware_no_ekcert', 'manufacturer', 'unknown (no EK certificate)'),
     'admin@wifi.local', NOW() - '15 days'::interval,
     NULL, NULL, NULL,
     '3141592653', NULL,
     '-----BEGIN CERTIFICATE-----\nSEED-MTLS-CERT\n-----END CERTIFICATE-----',
     NOW() + '1 year'::interval, NOW() - '3 days'::interval, 'admin@wifi.local',
     NOW() - '15 days'::interval, NOW() - '3 days'::interval)
) AS v(serial, purpose, user_identity, status, csr_pem, ssh_public_key,
       attestation, attest_result, approved_by, approved_at,
       rejected_by, rejected_at, reject_reason,
       vault_serial, vault_error, cert_pem, expires_at, revoked_at, revoked_by,
       created_at, updated_at);

-- SCEP async-issuance outbox row matching SEED-0004's ca_pending request
-- above (021_scep_pending.sql: cert_request_id UNIQUE, ON DELETE CASCADE --
-- purged automatically with its parent cert_requests row).
INSERT INTO scep_pending (cert_request_id, poll_ref_enc, attempts, next_poll_at, last_error)
SELECT cr.id, '\x5345454420504c414345484f4c4445525f504f4c4c524546'::bytea, 2,
       NOW() + '30 seconds'::interval, 'CA returned PENDING (seed placeholder)'
FROM cert_requests cr
JOIN devices d ON d.id = cr.device_id
WHERE d.serial_number = 'SEED-0004' AND cr.purpose = 'ad_logon' AND cr.status = 'ca_pending';

-- ── real-world detail on a few of the main bucket's already-inserted rows:
--    an attestation ERROR (not just NULL) on the rejected bucket, ak_verified
--    on a couple of the installed/full rows, and a vault_error message on
--    the vault_failed bucket -- the main generator above leaves all three
--    NULL/false, so these UI paths (error tooltip, AK-verified badge,
--    vault-error-takes-precedence banner) were never exercised.
UPDATE cert_requests SET attest_result = jsonb_build_object(
    'ok', false, 'level', 'hardware',
    'error', 'EK certificate chain does not terminate at a trusted manufacturer root')
WHERE device_id IN (SELECT id FROM devices WHERE serial_number IN ('SEED-0039', 'SEED-0040'))
  AND status = 'rejected';

UPDATE cert_requests SET attest_result = attest_result || '{"ak_verified": true}'::jsonb
WHERE device_id IN (SELECT id FROM devices WHERE serial_number IN ('SEED-0019', 'SEED-0020'))
  AND attest_result IS NOT NULL;

-- ДОКАЗАТЕЛЬСТВО РЕЗИДЕНТНОСТИ КЛЮЧА — ЗАЯВКАМ В ОЖИДАНИИ (GitLab dexion #890).
--
-- Без него одобрение упирается в следующую ступень: `device did not prove its
-- private key is resident in a TPM or Secure Enclave`. Ступень правильная, а
-- фикстура была неполной: строка утверждает `platform: tpm2` и уровень
-- `hardware`, но доказательства при этом не несёт.
--
-- Даётся ТОЛЬКО аппаратным строкам. Программные (`level = software`) остаются
-- без него намеренно: отказ на них — не дефект демонстрации, а её польза,
-- человек видит, как ступень работает.
UPDATE cert_requests r
SET    attest_result = r.attest_result
       || jsonb_build_object('ak_verified', true)
       -- ПЛАТФОРМА ЖИВЁТ ВНУТРИ ВЕРДИКТА, а не только в соседней колонке
       -- `attestation`. `IsHardwareAttested()` разбирает `attest_result.platform`
       -- ПО ИЗВЕСТНЫМ значениям, и неизвестное (в том числе отсутствующее) даёт
       -- false — это защита от «строка клиента выключает проверку» (#371).
       -- Без этого поля вердикт с level=hardware и ak_verified=true всё равно
       -- читался как «доказательств нет», и одобрение отказывало.
       || jsonb_build_object('platform',
              CASE d.os WHEN 'macos' THEN 'secure_enclave' ELSE 'tpm2' END)
FROM   devices d
WHERE  d.id = r.device_id
  AND  r.status = 'pending'
  AND  r.attest_result IS NOT NULL
  AND  r.attest_result->>'level' IN ('full', 'hardware');

-- ЦЕЛИ НАЗНАЧЕНЫ УСТРОЙСТВАМ (GitLab dexion #890).
--
-- Пятая и последняя стена демонстрации: сервер отвечал
-- `device is not assigned the purpose wifi`. Таблица `device_purposes` была
-- ПУСТА, то есть ни одно демонстрационное устройство не имело ни одной цели —
-- хотя рядом лежали 766 заявок на эти самые цели.
--
-- Назначается ровно то, на что в данных есть заявка: цель берётся из самой
-- заявки, дубликаты отсекаются. Состояние `approved` — то же, что ставит
-- администратор из карточки устройства.
INSERT INTO device_purposes (device_id, purpose, state, requested_by, decided_at, decided_by)
SELECT DISTINCT r.device_id, r.purpose, 'approved', 'seed', now(), 'admin@wifi.local'
FROM   cert_requests r
WHERE  r.purpose IS NOT NULL
ON CONFLICT DO NOTHING;

UPDATE cert_requests SET vault_error = CASE
    WHEN d.serial_number = 'SEED-0043' THEN 'Vault PKI unreachable: dial tcp 10.0.1.5:8200: connect: connection refused'
    WHEN d.serial_number = 'SEED-0044' THEN 'Vault sign error: certificate TTL exceeds role max_ttl (26280h)'
    END
FROM devices d
WHERE cert_requests.device_id = d.id
  AND d.serial_number IN ('SEED-0043', 'SEED-0044')
  AND cert_requests.status = 'vault_failed';

-- ── device-level flags the main INSERT never sets: placeholder serial,
--    per-device issue-policy override, agent-update stuck (one not-yet-
--    alerted, one already-alerted), and a pending remote-log request.
UPDATE devices SET is_placeholder_serial = true      WHERE serial_number = 'SEED-0031';
UPDATE devices SET issue_policy_override = 'both'    WHERE serial_number = 'SEED-0032';
UPDATE devices SET agent_update_pending_since = NOW() - '3 hours'::interval
    WHERE serial_number = 'SEED-0033';
UPDATE devices SET agent_update_pending_since = NOW() - '2 days'::interval,
                    agent_update_alert_sent_at = NOW() - '1 day'::interval
    WHERE serial_number = 'SEED-0034';
UPDATE devices SET logs_requested_at = NOW() - '10 minutes'::interval
    WHERE serial_number = 'SEED-0035';

-- ── device_logs: realistic multi-line zap-JSON agent output (matching the
--    real log lines agent/cmd/alatyr-agent/main.go emits) across three
--    devices/scenarios, so DeviceLogsModal shows what admins actually see:
--    a clean happy-path enroll, a hardware retry-then-succeed, and a
--    network failure followed by a successful retry an hour later. Two
--    uploads on SEED-0036 (enroll + a later checkin) demonstrate repeated
--    on-demand requests accumulating, not just a single upload.
INSERT INTO device_logs (device_id, uploaded_at, size_bytes, content)
SELECT id, NOW() - '2 hours'::interval, length(c), c FROM devices, (VALUES (
E'{"level":"info","ts":"2026-07-15T09:12:01.102+0300","msg":"alatyr-agent starting","version":"1.4.5","os":"macos"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:12:01.340+0300","msg":"hardware serial detected","serial":"SEED-0036"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:12:01.891+0300","msg":"generating CSR and enrolling"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:12:02.455+0300","msg":"waiting for admin approval","request_id":"3f9a2e10-88b1-4c3a-9e2d-7a1b5c6d8e0f"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:12:32.120+0300","msg":"polling for approval"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:13:05.671+0300","msg":"status received","status":"approved"}\n' ||
E'{"level":"info","ts":"2026-07-15T09:13:06.203+0300","msg":"certificate installed successfully","serial_number":"1a:2b:36:36"}'
)) AS t(c)
WHERE serial_number = 'SEED-0036';
INSERT INTO device_logs (device_id, uploaded_at, size_bytes, content)
SELECT id, NOW() - '1 hour'::interval, length(c), c FROM devices, (VALUES (
E'{"level":"info","ts":"2026-07-15T15:00:00.010+0300","msg":"state machine tick","status":"installed"}\n' ||
E'{"level":"info","ts":"2026-07-15T15:00:00.512+0300","msg":"certificate already installed — running steady-state sync (no re-enrollment)"}'
)) AS t(c)
WHERE serial_number = 'SEED-0036';

INSERT INTO device_logs (device_id, uploaded_at, size_bytes, content)
SELECT id, NOW() - '30 hours'::interval, length(c), c FROM devices, (VALUES (
E'{"level":"info","ts":"2026-07-14T08:00:11.221+0300","msg":"alatyr-agent starting","version":"1.4.2","os":"windows"}\n' ||
E'{"level":"warn","ts":"2026-07-14T08:00:12.004+0300","msg":"TPM busy, retrying key provisioning","attempt":1}\n' ||
E'{"level":"warn","ts":"2026-07-14T08:00:14.552+0300","msg":"TPM busy, retrying key provisioning","attempt":2}\n' ||
E'{"level":"info","ts":"2026-07-14T08:00:19.887+0300","msg":"user-key provisioned and submitted"}\n' ||
E'{"level":"info","ts":"2026-07-14T08:00:45.213+0300","msg":"certificate installed successfully","serial_number":"1a:2b:37:37"}'
)) AS t(c)
WHERE serial_number = 'SEED-0037';

INSERT INTO device_logs (device_id, uploaded_at, size_bytes, content)
SELECT id, NOW() - '18 hours'::interval, length(c), c FROM devices, (VALUES (
E'{"level":"info","ts":"2026-07-13T22:10:00.001+0300","msg":"alatyr-agent starting","version":"1.4.5","os":"linux"}\n' ||
E'{"level":"error","ts":"2026-07-13T22:10:03.442+0300","msg":"enroll request failed","error":"dial tcp: connect: connection refused"}\n' ||
E'{"level":"info","ts":"2026-07-13T23:10:00.001+0300","msg":"alatyr-agent starting","version":"1.4.5","os":"linux"}\n' ||
E'{"level":"info","ts":"2026-07-13T23:10:02.118+0300","msg":"generating CSR and enrolling"}\n' ||
E'{"level":"info","ts":"2026-07-13T23:10:35.664+0300","msg":"certificate installed successfully","serial_number":"1a:2b:38:38"}'
)) AS t(c)
WHERE serial_number = 'SEED-0038';

-- ── service_accounts: enabled/disabled × never-expires/expired/valid ────────
INSERT INTO service_accounts (name, description, token_hash, created_by, enabled, created_at, last_used_at, expires_at) VALUES
    ('SEED-CI-Approver',   'Auto-approves hardware-attested wifi requests from the CI runner pool',
     'seedtokenhash0000000000000000000000000000000000000000000000001', 'admin@wifi.local', true,
     NOW() - '60 days'::interval, NOW() - '2 hours'::interval, NULL),
    ('SEED-Legacy-Deploy', 'Old deploy integration, disabled after migration to SEED-CI-Approver',
     'seedtokenhash0000000000000000000000000000000000000000000000002', 'admin@wifi.local', false,
     NOW() - '200 days'::interval, NOW() - '90 days'::interval, NULL),
    ('SEED-Temp-Audit',    'Time-boxed read-only token for a Q1 security audit',
     'seedtokenhash0000000000000000000000000000000000000000000000003', 'admin@wifi.local', true,
     NOW() - '10 days'::interval, NOW() - '1 day'::interval, NOW() - '1 day'::interval),
    ('SEED-Future-Rotate', 'Scheduled to expire at end of quarter',
     'seedtokenhash0000000000000000000000000000000000000000000000004', 'admin@wifi.local', true,
     NOW() - '5 days'::interval, NULL, NOW() + '30 days'::interval);

-- ── webhook_endpoints + webhook_deliveries: enabled/disabled endpoints,
--    every valid event type, and delivered/failed history. secret_ciphertext
--    is a fixed-length dummy nonce||ct||tag blob -- never decrypted for
--    listing/detail views, only by the live delivery worker, which this
--    seed avoids triggering by never inserting a 'pending' row (see
--    webhook_delivery_repo.go: ClaimDue only picks up status='pending').
INSERT INTO webhook_endpoints (name, url, secret_ciphertext, events, enabled, description, created_by, created_at, last_status, last_attempt_at) VALUES
    ('SEED-SIEM-Ingest', 'https://siem.example.internal/hooks/wifi-certs',
     decode('000000000000000000000000' || repeat('00', 28), 'hex'),
     ARRAY['request.approved','request.rejected','cert.revoked'], true,
     'Forwards approval/revocation events to the SIEM', 'admin@wifi.local',
     NOW() - '30 days'::interval, 'delivered', NOW() - '10 minutes'::interval),
    ('SEED-Slack-Alerts', 'https://hooks.slack.example.com/services/SEED/PLACEHOLDER/TOKEN',
     decode('000000000000000000000000' || repeat('00', 28), 'hex'),
     ARRAY['request.vault_failed','request.enrolled'], false,
     'Old Slack channel integration, disabled after channel archive', 'admin@wifi.local',
     NOW() - '90 days'::interval, 'failed', NOW() - '45 days'::interval);

INSERT INTO webhook_deliveries (endpoint_id, event_type, payload, status, attempts, last_response_code, last_error, created_at, delivered_at)
SELECT id, 'request.approved', jsonb_build_object('serial_number', 'SEED-0011', 'purpose', 'wifi'),
       'delivered', 1, 200, NULL, NOW() - '2 hours'::interval, NOW() - '2 hours'::interval + '400 milliseconds'::interval
FROM webhook_endpoints WHERE name = 'SEED-SIEM-Ingest';
INSERT INTO webhook_deliveries (endpoint_id, event_type, payload, status, attempts, last_response_code, last_error, created_at, delivered_at)
SELECT id, 'cert.revoked', jsonb_build_object('serial_number', 'SEED-0010', 'purpose', 'user_mtls'),
       'delivered', 1, 200, NULL, NOW() - '3 days'::interval, NOW() - '3 days'::interval + '1 second'::interval
FROM webhook_endpoints WHERE name = 'SEED-SIEM-Ingest';
INSERT INTO webhook_deliveries (endpoint_id, event_type, payload, status, attempts, last_response_code, last_error, created_at, delivered_at)
SELECT id, 'request.vault_failed', jsonb_build_object('serial_number', 'SEED-0043', 'purpose', 'wifi'),
       'failed', 5, 503, 'endpoint returned 503 after 5 attempts (Slack channel archived)',
       NOW() - '45 days'::interval, NULL
FROM webhook_endpoints WHERE name = 'SEED-Slack-Alerts';

-- ── issuer_profiles: one row per purpose, mixed backends (vault/scep) and
--    enabled state -- Settings→Issuers currently shows all 4 purposes as
--    "no profile, env fallback" without this. Upsert (singleton per
--    purpose), not purged.
-- РОЛЬ VAULT НАЗВАНА ТАК ЖЕ, КАК ЕЁ ЗАВОДИТ vault-init (GitLab dexion #890).
--
-- У цели `wifi` здесь стояло `wifi-cert` — имя ДО переименования продукта в
-- Alatyr. Демонстрационный vault-init заводит роли `alatyr`, `user-mtls` и
-- `k8s-client`, роли `wifi-cert` в нём нет. Одобрение доходило до самого
-- конца и падало у Vault:
--     vault error 400: {"errors":["unknown role: wifi-cert"]}
-- В интерфейсе это выглядит как `vault_failed` — то есть отказ показывался
-- там, где он ни при чём, а причина лежала в фикстуре.
INSERT INTO issuer_profiles (purpose, backend, vault_mount, vault_role, eku, key_usage, san_template, ttl_hours, key_protection, enabled, created_by, updated_at) VALUES
    ('wifi',      'vault', 'pki', 'alatyr',
     ARRAY['clientAuth'], ARRAY['digitalSignature','keyEncipherment'], ARRAY['{{.Username}}'], 26280, 'silent', true,
     'admin@wifi.local', NOW() - '20 days'::interval),
    ('k8s',       'vault', 'pki', 'k8s-client',
     ARRAY['clientAuth'], ARRAY['digitalSignature','keyEncipherment'], ARRAY['{{.Username}}'], 12, 'biometric', true,
     'admin@wifi.local', NOW() - '2 days'::interval),
    ('user_mtls', 'vault', 'pki', 'user-mtls',
     ARRAY['clientAuth','smartCardLogon'], ARRAY['digitalSignature'], ARRAY['{{.Username}}'], 17520, 'biometric', true,
     'admin@wifi.local', NOW() - '15 days'::interval),
    ('ad_logon',  'scep', NULL, NULL,
     ARRAY['clientAuth','smartCardLogon'], ARRAY['digitalSignature','keyEncipherment'], ARRAY['{{.Username}}@corp.local'], 8760, NULL, false,
     'admin@wifi.local', NOW() - '5 days'::interval),
    ('ssh',       'vault_ssh', 'ssh-client-signer', 'ssh-user',
     ARRAY[]::text[], ARRAY[]::text[], ARRAY['{{.Username}}'], 168, NULL, true,
     'admin@wifi.local', NOW() - '2 days'::interval)
ON CONFLICT (purpose) DO UPDATE SET
    backend = EXCLUDED.backend, vault_mount = EXCLUDED.vault_mount, vault_role = EXCLUDED.vault_role,
    eku = EXCLUDED.eku, key_usage = EXCLUDED.key_usage, san_template = EXCLUDED.san_template,
    ttl_hours = EXCLUDED.ttl_hours, key_protection = EXCLUDED.key_protection, enabled = EXCLUDED.enabled,
    created_by = EXCLUDED.created_by, updated_at = EXCLUDED.updated_at;

-- ── system_settings: singleton row, non-default value on every Settings
--    tab it backs (IssuePolicyTab/SecurityDefaultsTab/AgentUpdateTab). The
--    migration INSERTs id=1 with defaults on every fresh DB -- UPDATE, not
--    INSERT.
UPDATE system_settings SET
    issue_user_mtls = true,
    issue_ad_logon = false,
    security_default_biometric = 'biometry_current_set',
    agent_update_min_version = '1.5.0',
    agent_update_rollout_percent = 25,
    agent_update_targets = (SELECT jsonb_agg(id) FROM devices WHERE serial_number IN ('SEED-0033','SEED-0034')),
    ssh_unlock_window_minutes = 15,
    updated_by = 'admin@wifi.local',
    updated_at = NOW() - '1 day'::interval
WHERE id = 1;

-- ── local_credentials: two of the seed users get a local (email+password)
--    credential alongside their SSO identity, so Users→"локальный вход"
--    isn't SSO-only for every row. Password for both is "Seed1234!" (bcrypt
--    cost 12, same as auth/password.go's bcryptCost) -- fine to share since
--    this is throwaway dev data, never a real credential.
INSERT INTO local_credentials (email, password_hash, password_changed_at) VALUES
    ('admin.only@seed.wifi.local', '$2a$12$k4H82rV6lQZ1QlYrkJDYcus9aNaAexYD.z5HydSGehEBFaWIbT0Eq', NOW() - '30 days'::interval),
    ('all.roles@seed.wifi.local',  '$2a$12$k4H82rV6lQZ1QlYrkJDYcus9aNaAexYD.z5HydSGehEBFaWIbT0Eq', NOW() - '5 days'::interval);

-- ── long-string stress rows: verify the UI truncates with ellipsis instead of
--    wrapping and breaking table/drawer layout. Long serial, email, agent
--    version, OS string, SSID, audit target. Cleaned by the SEED-/seed@ keys.
INSERT INTO devices (serial_number, username, os, last_seen_at, agent_version, os_version, created_at) VALUES
    ('SEED-LONG-0000000000-VERY-LONG-HARDWARE-SERIAL-NUMBER-THAT-SHOULD-ELLIPSIZE-NOT-WRAP-1234567890ABCDEF',
     'extremely.long.corporate.username.for.layout.testing.purposes@subdomain.department.example-corporation.wifi.local',
     'windows',
     NOW() - '1 hour'::interval,
     '1.4.5-rc.1+build.20260620.commit.0123456789abcdef-very-long-version-string',
     'Windows 11 Enterprise LTSC 24H2 (Build 26100.1742) — Insider Preview Long Edition Name',
     NOW() - '1 day'::interval);

INSERT INTO cert_requests (
    device_id, status, csr_pem, attestation, attest_result,
    approved_by, approved_at, vault_serial, cert_pem, expires_at,
    created_at, updated_at
)
SELECT
    d.id, 'installed',
    E'-----BEGIN CERTIFICATE REQUEST-----\nMIHZMIGAAgEAMB4xHDAaBgNVBAMME2RlbW9AYWxhdHlyLmV4YW1wbGUwWTATBgcq\nhkjOPQIBBggqhkjOPQMBBwNCAATtcCWwl4xtQtA4peRpvIHIrrFdFnlSUaWwqHjn\nhgOYLM3r00LagoRRUTABjTyLIlKxlIXaKaaZGLS0ZtFjiu2AoAAwCgYIKoZIzj0E\nAwIDSAAwRQIhAL2Nv4yu/Z+C14lfGvYG2dCxLTC3JqfEcBiPm6ApzCj7AiBxamD3\nQz7rIoXj4WST0Bq0XrbxIMR5A0t2z9xEzkQq3w==\n-----END CERTIFICATE REQUEST-----',
    '{"platform":"tpm2"}'::jsonb,
    jsonb_build_object('ok', true, 'level', 'full', 'manufacturer', 'Intel Corporation — Platform Trust Technology (fTPM) Long Manufacturer Name'),
    'admin@wifi.local', NOW() - '2 days'::interval,
    '1a:2b:3c:4d:5e:6f:7a:8b:9c:0d:1e:2f:3a:4b:5c:6d:7e:8f',
    '-----BEGIN CERTIFICATE-----\nSEED-FAKE-CERT\n-----END CERTIFICATE-----',
    NOW() + '400 days'::interval,
    NOW() - '2 days'::interval, NOW() - '1 day'::interval
FROM devices d
WHERE d.serial_number LIKE 'SEED-LONG-%';

-- audit.target_id is a uuid column, so the long stress string goes in details
-- (serial_number) which the Audit table/drawer renders — must ellipsize there.
INSERT INTO audit_log (actor, action, target_id, details, created_at) VALUES
    ('seed@wifi.local', 'revoke', NULL,
     jsonb_build_object(
        'serial_number', 'SEED-LONG-0000000000-VERY-LONG-HARDWARE-SERIAL-NUMBER-THAT-SHOULD-ELLIPSIZE-NOT-WRAP-1234567890ABCDEF',
        'note', 'long stress row — must ellipsize in the Audit table, full value in tooltip/drawer'),
     NOW() - '30 minutes'::interval);

INSERT INTO users (email, username, enabled) VALUES
    ('extremely.long.corporate.username.for.layout.testing.purposes@subdomain.department.example-corporation.seed.wifi.local',
     'extremely.long.corporate.username.for.layout.testing.purposes@subdomain.department.example-corporation.seed.wifi.local',
     true);
INSERT INTO user_roles (email, roles) VALUES
    ('extremely.long.corporate.username.for.layout.testing.purposes@subdomain.department.example-corporation.seed.wifi.local',
     ARRAY['cert-admin','cert-approver','cert-viewer']);

-- ssid CHECK ≤32, display_name CHECK ≤64 — use the exact maxes (realistic worst
-- case) to verify the SSID column ellipsizes the longest valid values.
INSERT INTO networks (kind, ssid, display_name, disabled_at) VALUES
    ('wifi', 'SEED-Corp-Guest-VLAN-Floor3-2026',
     'Очень длинное отображаемое имя сети Wi-Fi для проверки эллипсиса',
     NULL);

COMMIT;

-- ── summary ─────────────────────────────────────────────────────────────────
\echo '--- seed summary ---'
SELECT 'devices'        AS table, count(*) FROM devices    WHERE serial_number LIKE 'SEED-%'
UNION ALL SELECT 'cert_requests', count(*) FROM cert_requests
    WHERE device_id IN (SELECT id FROM devices WHERE serial_number LIKE 'SEED-%')
UNION ALL SELECT 'audit_log',     count(*) FROM audit_log  WHERE actor IN ('seed@wifi.local', 'SEED-CI-Approver')
UNION ALL SELECT 'networks',      count(*) FROM networks   WHERE ssid LIKE 'SEED-%' OR display_name LIKE 'SEED-%'
UNION ALL SELECT 'service_accounts', count(*) FROM service_accounts WHERE name LIKE 'SEED-%'
UNION ALL SELECT 'webhook_endpoints', count(*) FROM webhook_endpoints WHERE name LIKE 'SEED-%'
UNION ALL SELECT 'webhook_deliveries', count(*) FROM webhook_deliveries
    WHERE endpoint_id IN (SELECT id FROM webhook_endpoints WHERE name LIKE 'SEED-%')
UNION ALL SELECT 'issuer_profiles', count(*) FROM issuer_profiles
UNION ALL SELECT 'local_credentials', count(*) FROM local_credentials WHERE email LIKE '%seed.wifi.local'
UNION ALL SELECT 'device_logs', count(*) FROM device_logs
    WHERE device_id IN (SELECT id FROM devices WHERE serial_number LIKE 'SEED-%');

\echo '--- cert_requests by purpose × status ---'
SELECT purpose, status, count(*),
       count(*) FILTER (WHERE revoked_at IS NOT NULL) AS revoked
FROM cert_requests
WHERE device_id IN (SELECT id FROM devices WHERE serial_number LIKE 'SEED-%')
GROUP BY purpose, status ORDER BY purpose, status;

-- ЛИЧНОСТЬ В CSR ДОЛЖНА СОВПАДАТЬ С ЗАЯВЛЕННОЙ (GitLab dexion #890).
--
-- Одного настоящего CSR на все строки НЕ хватило: сервер сверяет личность
-- внутри CSR с личностью устройства и отвечает
-- `csr identity binding: csr identity does not match declared identity`.
-- Поэтому здесь по одному настоящему CSR (EC P-256) на каждую из 46
-- демонстрационных личностей: CN = имя пользователя (обрезано до 64 символов,
-- как требует X.509), SAN email = полное имя.
UPDATE cert_requests r
SET    csr_pem = v.csr
FROM   (VALUES
    ('extremely.long.corporate.username.for.layout.testing.purposes@subdomain.department.example-corporation.wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBmjCCAT8CAQAwSzFJMEcGA1UEAwxAZXh0cmVtZWx5LmxvbmcuY29ycG9yYXRl\nLnVzZXJuYW1lLmZvci5sYXlvdXQudGVzdGluZy5wdXJwb3Nlc0BzdTBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABOB3fgRM5+ViGJNwdknQVpJgFactWrLQP/C6STnQ\n8tkFvtphMPu5hINEpZygTXIYJAy58qpQZ4u4ztyhNzWS/duggZEwgY4GCSqGSIb3\nDQEJDjGBgDB+MHwGA1UdEQR1MHOBcWV4dHJlbWVseS5sb25nLmNvcnBvcmF0ZS51\nc2VybmFtZS5mb3IubGF5b3V0LnRlc3RpbmcucHVycG9zZXNAc3ViZG9tYWluLmRl\ncGFydG1lbnQuZXhhbXBsZS1jb3Jwb3JhdGlvbi53aWZpLmxvY2FsMAoGCCqGSM49\nBAMCA0kAMEYCIQDEtrVqj8nWJlaUSQcmG8mzcPSeFVDyJ3QkIC4zQfr6OwIhAM90\nnFiZGargWFSFwoEcTcNdNAm+nxZFCdX6kcr3Panv\n-----END CERTIFICATE REQUEST-----'),
    ('user01@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDFAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABL2il2tIXqggNC2ZYp1CQuo/GNVFobCN5mj29tTn\nJnXGQgJiDCWxFOcaLRkgjqc6S0iqd6E3Wk2t+DqzvKW8d1qgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwMUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDVvJxpjIb/pX/8/oEplnWPPKHOKSy58C8swOYStMWvHgIgLAX2xQ3o\n943gq+mDFiR/PCcNWXIXg7XfMhMJ195IpvU=\n-----END CERTIFICATE REQUEST-----'),
    ('user02@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDJAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABMN/cu0vnt7HfSrLsr9lCQGMSGEsLVjXb7ZhQAYo\nYANIcveEOepcgpIYvbXquDG0JfysRSfje+++g+K9PzQnl5CgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwMkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCK0m/aHO33DBUhq/8gUssrq91SX4CwPa0nA1B+GnsZDQIhAINbQrJQ\nI2F3VODVQ/R5YgPCa+etfV4hzbkeWEC428au\n-----END CERTIFICATE REQUEST-----'),
    ('user03@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDNAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABGnscZ1qbpfKO0iIZH8tTBr5Bfiba6HY/P9PlUTF\nmBa6WXz36op0uApj4qPkOaXCxYo+cMlBSKQjeMivmTGtv0ygLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwM0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIBsuuvBqx8upAQUS/EFijcAJeYq2qN6YJS2zvq4WzGSCAiEA78FdS3OY\nbFl5JcHmZ9T/lW7q1HuA3eeTiEDMi5x74NE=\n-----END CERTIFICATE REQUEST-----'),
    ('user04@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDRAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABHnmbvc87I75T+ScNZf8DLOTv+V3fOpDfHJmL65t\n+GtapaNYL6Q7KqAQRvnNldBD84+zEHuxyzNSgnyZJPut1HagLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwNEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIEXdP2+GszLt5Y6eTDGTgc/aedK8XSHuqMPE+uY49tYxAiAR3m2mv45M\nfaJ4l9FuamSK+NVZCFaSN6ZVGMoBLQ8LfQ==\n-----END CERTIFICATE REQUEST-----'),
    ('user05@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDVAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABA2ugefxJCJ45bFj4WFFPgc8Wd0jGUtHDZ3ybTDP\nWhDeYLkZMzlSox0lw4QwNWaPTQjkBPSx+yU/ktkGDMbjlvegLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwNUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCiwCPZv5nmMs7NZ+49hQv0txRDcjAsKpur/yvhq0KLtgIhAPd0hquC\n23TsImmjNuExqJZ7jRuHEilrfzuKKnGnDM+g\n-----END CERTIFICATE REQUEST-----'),
    ('user06@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDZAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABJYqyzqG8FY9bq+reZBPUdhg1hr9sbzj18bmkGKv\nb7+YUivfcVv3Sw/iHmog0cDheCW2hZUb98A/J9MAsjtPIQ+gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwNkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDEEbUWSmFeeBXMKxUD86dAFUcQLYoEJPHOPZH796rPLAIhAMbtxNec\nZtO3tpGKiTuN92wE8TGGcPvFPfwTFETPsxsy\n-----END CERTIFICATE REQUEST-----'),
    ('user07@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDdAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABGmasVtr+FendGOWque9pSb/vKOFWLZSnFr+O5K5\nTKtrHNevzh9uTPYT1dHi+z7yaCQ9biAC9IIntsbsYUr6yuGgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwN0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIFkcbcvSrwzOqaniEW/NJRmef4UZzxrySoSA05gC7sB0AiBkgGNiey5Y\noviMAqQvPGvn8mWsFhFla+R1R0SsWRNWiw==\n-----END CERTIFICATE REQUEST-----'),
    ('user08@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDhAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABFh+4MKYH5BEXuwnqCXvAq4U8Gxw/1aTpr7EfjDy\nLSAft2lVAIrpYPJybDriJZbtbL3wYYvV3mV59quZAy48MVigLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwOEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQCuADccz+yo+4va9zxbzZqSBomA4nlaQNRvjwMw+yeJ3AIgSPV7Rvp7\nmFsWeylH1/Of3aGRKEhtnTgqYgfV5cIyUlA=\n-----END CERTIFICATE REQUEST-----'),
    ('user09@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMDlAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABN0Jyti1sIeWw6htInxLealERWaU0huET5Y1ejp1\nTvWOkfoOQZ3WXSKdJmO+IT+lmqRbzDxRuwbf+8dDdZ3Fhy2gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIwOUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIEYf0PLnCNOrcM01ey8QivLd1Hr8qULCocB3tLqgT0NVAiEA287Q6oY2\nmJmF+n0y8XEXVV03lUFxuZSribKnkHin7Es=\n-----END CERTIFICATE REQUEST-----'),
    ('user10@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTBAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABDJz4+Pc8sVtCZW1bWYTqEa8H7E9fMQP/aQcuZgN\n3mmEEX/EK736adynlU7St59M7jveyz/cUsnGstFuJJEIG56gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxMEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDKaaKvtUAmU1WrNbmwzc3cIv+dsSqgqkhyWXs+faBAqQIhAPx0mxiu\nNOlRMNNwfQLMe5cjRsINDSwUnuaD/EpqSre0\n-----END CERTIFICATE REQUEST-----'),
    ('user11@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTFAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABLeVzljfy8aXnfAwSRSbZqaWC9kBSE7RyuqjicRJ\nFT+6Mw/Zba4DkV2fcoPOZdxDyVf/GIzU5BPr74fVr2AVDlegLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxMUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIF2zsh95vV1PExB+LvdnFOCHOEyHNzX2nOrN5KUtpS29AiEAhtsWyzmh\nAajUcDeLkwEDKFpj0s2BkfVzv9EMwrem6Cw=\n-----END CERTIFICATE REQUEST-----'),
    ('user12@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTJAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABP9K1/eUVsZ39RRCwyaRpI4dFk4JKR2AXAUPXme6\nen1uMwK86S16Y4e07HZLhfemvjsBu9UqGYWGy12V0fOWAFWgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxMkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCHNyc5N7azL/HxgOe5o9vHra+Uv3pwJ/K4dEaKCOzwnwIhAMv2rNdQ\nEXeeuysFzFtnkD+0L8dhpwTSDrDsr39xnv2p\n-----END CERTIFICATE REQUEST-----'),
    ('user13@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTNAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABM9r96taUKL1Wf5uKOGuky5PJJC3sEd34bXzz6wS\nKFJBl7csRYjCEhVFoMwleRq0gryC/wpqXg0i2uk+iUH2Jc2gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxM0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDNNcGnuo/Goa4uQuEzwB0dZ/Fl3pcqqZi0a4RSgSK+AgIhALCpQtIv\nMbbgvew6NuXynTpQ9uXtBtj+lEcSuuD+T/lU\n-----END CERTIFICATE REQUEST-----'),
    ('user14@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTRAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABGhDUmnqoil9xgqlYPNQCLZd2YU2SntnlJhgLoHd\n82HZ6sk3NiR3kZkFbl4N30bDS37PVpOl6tX6YRbCkLoRQuygLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxNEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQD3RmT5AX4rQ71u7+MelE1ALmMqZ9nFk84HxG1s0jiunAIgcb6NY40Q\nYftfJW1D/p93wnDAaQwnZZ/jkhbnKmbkwFU=\n-----END CERTIFICATE REQUEST-----'),
    ('user15@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTVAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABClpHhpZUeo43YOV7n2wAV9xWOUXtjB199KYYC7P\nOVtU6Z6jbX+6dO6s1tSduQizTOI6Ir6amgB1DCQnNwvz76egLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxNUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIBmTCMzHsGfapqUJW//WFrzCq13yTzjMcM9NSR6IrQ+JAiEAxjEVrDnk\nFSyZySJpmxUf6X6xDYYVjSdFGKPkb2nIc5A=\n-----END CERTIFICATE REQUEST-----'),
    ('user16@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTZAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABALtZZzWKgikcRlenaqiOuS7PsX1EC9clY9jG50+\nBYiS06jFBHcKvjUlgT+zVwYIrc6RBTrsqlr7yOVqiooX4uCgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxNkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDTbbsktqpDCkaWcsh9Edga5HdaiNBXTS/xMx29f9nFBwIgNpsbn+pZ\nfoJAaY6ed06ovys1DCyVRlYxXtGh7Mwfw9s=\n-----END CERTIFICATE REQUEST-----'),
    ('user17@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTdAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABFUTbjbZIBuHZ0VTLUWShB1iD7ZE6/+cSpdo/ILQ\ngml+df0Pj8rWPgCCYKrWVHLRsr3yXAof58JUUXv/RopNLOWgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxN0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQCw0rmAvVGQTo7higLvUEoxng14yasTnKsKJ3wAtEB8OwIgEUy3X5Sh\nKv48hH5nOpTG6EBpZ8yQQVhgVr/eN/NltcY=\n-----END CERTIFICATE REQUEST-----'),
    ('user18@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMThAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABHNT9a6qAQyiMbeW7WD8l/pO9gOh3vZjYuw/4BkH\n8xX4UWfbdDH1frqBEqSoOsbr4rPPCaUhVup8kC/cyDbXMXWgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxOEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDNJQZZfNL+vfxNANSp/v8qdjkHwo10o1q1iPgQqP4czAIhAJYBzqkT\n9BdAO+zSFAe55XiYgqut+R3facrcLK3PhMZK\n-----END CERTIFICATE REQUEST-----'),
    ('user19@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMTlAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABIwcQfjNs+HOFlGQd/qjbbP7h8dtcNddfKETo5tM\n3ZGST/P/1WV+E2849kSmJfx5orzOqgP1Aftw5pH1BAv2ke6gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIxOUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQC71vKEqvPvR1ZoLVBTZ5xzqfNnnX7KX743X0o65M4eCQIhAIxv0B8B\nHFoUs1ESmxQs1tCTZ9/hLBtItgfM3cl8DpC+\n-----END CERTIFICATE REQUEST-----'),
    ('user20@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjBAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABH2sO87X118myQjSBKiqMRZNErZERkCpDFLS9Yox\nEwUjHuV9YC+7ELp4mmPEJ94ZEdgJrdwANuAzAwyPxJVKx5igLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyMEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQCDD5RzxpFdje7W2PBVP2zFmqhEumjjmPjagbKx0GdHzgIgRIPGl3ih\nic6MzGvFCA+EEnhTQgo8x3Un5wwjYPYmr5c=\n-----END CERTIFICATE REQUEST-----'),
    ('user21@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjFAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABMBxzK42ADEv7ngYen7afJFqtaMnwCAGg3MTUA+y\nfqNonzOy/E2yV0GuBavaXRhIls5FOQ2oO5G19cmOUEqbZmugLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyMUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIGVKMCfgdMXfFW2j/ve+FNIkrfsGJb8zp+vvv9lgC8BnAiEA2unvgHXg\nT+WO6sWGtdwN0Dj4LXcau1a3N4kqyB3Ify8=\n-----END CERTIFICATE REQUEST-----'),
    ('user22@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjJAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABOwrbHJovZFICs/R4E/9ILOVIBqBE7LNSR9sStfD\nPItkL5Vu30Wu56aKzjpR19PfWvLqzABoZupUyHRpSjbc6pigLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyMkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIANm0C/dl2I3rKtKkCKIDxLzs90071PajfB9lfbSQv3WAiEAwVWkxHp6\nMfxYyBWoOeJPunyo/VLJF8wOR6f+Gpe+sLo=\n-----END CERTIFICATE REQUEST-----'),
    ('user23@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjNAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABESsebrU8u9rvOv6iBY1i9nldoQSAoPDI90+E+9n\nvxQ+vIYKoIWrnjYTR9P0iy1HtC6w2RHmxt0POxrgPk6SU62gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyM0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDfD8ovtjk5OacRPOnvQ5jNHYYuDGR5V8fh8S2ZuEzSUAIgWDZZgnCJ\nC/cpGvwfxxpHtUpeaSDeeR083hAdffYU3VA=\n-----END CERTIFICATE REQUEST-----'),
    ('user24@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjRAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABGzve5hvZO4HWQy5mLbuJg/F1iKTJSVzRMw08weU\n762W6luLpsPzwUrb7pO/Y0l3J3xagKAwjJr09TqM3FFJRs+gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyNEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIEGdVWm+2GsaFT0Z1fx7hsUcDxmeZ0B9BzrtdNc9x4VNAiBcp7VLHD5j\nzqs1PJmn82ls2pRw4FEQtgR4oEvtvuFXLw==\n-----END CERTIFICATE REQUEST-----'),
    ('user25@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjVAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABO9D23Cv/357E1EdqZPb5SvyBcrayiir7rWEXzU/\nXq5XQP3v4orZMkQCtzMbQK1MfWQWUMZw+wiGV4P5u6M1jJugLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyNUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIFbfz/u+iM5e2+4hTg98xUbO16dwiS2/yGiZ/WESEliFAiEAy50ILo0/\ngmZdYQ31TN4i9B2eXIth54rlP3XvEinxPLY=\n-----END CERTIFICATE REQUEST-----'),
    ('user26@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjZAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABKRj/bxhxHr6Q8GvK7pJslRUKpPqe1wE2aOUQBHa\niXLLKTX11xqsZCBg8IBs27MWHml9BV6oApk26bbQRBeG+eSgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyNkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDYlaLgws82fd8Rw79+9BmajIEHmt9ggEx+uFSlaYkB2AIgNsq0DwDz\nGdBvuBqJPowNrauhjAa0Q0ff8gGk1ovk0Go=\n-----END CERTIFICATE REQUEST-----'),
    ('user27@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjdAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABKKKNd7CP+qy4Q8v40ROs4/CLCcvH2yRKinB3ShJ\namKnw5C9/4q8hgfrLQY4r1qXWVZ1DDenhEuZzaiqdjz8nqSgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyN0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQCdtjUKkmtM6H8jnLbFxW/ypS+zKsTHz8erqLL3nQgmvwIgbbrOwZAC\nAnGVbL/4boT3B3CYiqdChJSXk9k74taiv8g=\n-----END CERTIFICATE REQUEST-----'),
    ('user28@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjhAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABLZsEvqrea06SRx9eDLxH8WE8kmhvVacwRcPPH7p\nungcu4xyaorbAKrHPsbDlLOWJ5+pYgovT7BljoHWzmEXVICgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyOEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIFQawKuYcymjmcRjlvjViSTSTgS7vFAr9uGH0dbR5I0bAiEAjGKXAP3v\niaitn3RKHHKBLlBWodm1kdGwFBw6i+AFK5g=\n-----END CERTIFICATE REQUEST-----'),
    ('user29@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMjlAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABMgU1Ab2VeKFm3n+fTepyC2tzu7j4jkuwXrNOaf2\ngYvK3x2txbSGc1q9sPminUwJbZt0T1FqZ4lqO+nsz5FLWsOgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIyOUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIFUs/BHyjeNp8FvMJKrOreDuuFsLIk5COwgv70y8aojiAiEAw+gllcXW\nyhawUDwtqFT3rB3qPKMsVdIB4Er0mL4pQxM=\n-----END CERTIFICATE REQUEST-----'),
    ('user30@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzBAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABJyR3XSNKlLPjvLV71mo7cxIBG0qANK2iJKGoitr\nkhsoBmCywYC5aEUzFJ7VZzdhJQfa3/tKxlx6fnEmenOi7ZigLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzMEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCc188AppjKG+afATzHKkYPP33BHFHo4p1Y17LfXB8cJQIhAL6kDDgq\nRAj0VEDqj22D1WpKW2qjfY2NwvAUBTUySc3L\n-----END CERTIFICATE REQUEST-----'),
    ('user31@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzFAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABHD7kPFk5yu5UuWcbT861oHs5gN0P7oz/SC5bWc0\nFDPAydwB3XUkx8855fZs1MVSQlO+CLzg/Pb0bstltJ9i6OegLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzMUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIF7AdGqJ8Viax0JjJ59GCZp6CxnS7UzQnSlhswyqvqavAiBfVeLxjU3E\n0679J4awcVjCw2VVkqSPIC1cowpJ80uyjA==\n-----END CERTIFICATE REQUEST-----'),
    ('user32@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzJAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABFoPPXlh4pjyLa+xcnXCna0HFXLLrMMyLL9m0CKE\nCPP2cmjlE/idIYZQOSubRDDmOh6tzWslK3Kkpf+I+ofw+yygLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzMkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIF2sn6VijhwGRKSwIMBp1DFZlJVr0ox6nIT2NPmnAW1ZAiBtO/9vlPSC\ne3ajvBgj/9bx/TTKAlgm8GiAmtAeByp8RA==\n-----END CERTIFICATE REQUEST-----'),
    ('user33@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzNAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABId39vrmAz0j4hbVuHH1c4/Y86L/tgX+E3zcPpWi\nxpjsKdZYhw99srN9MAI4myTQAIJbLh1Rpz0y9D/QJAxHtjqgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzM0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIGqODxuEIs+mb6iJ1HuIcK7q+Wo7IgxDsAqyNBcAhemeAiArAIP5tBuD\n/aLjpvvlwRD+JWE4H1wH7ZT9sdj5KTeWdw==\n-----END CERTIFICATE REQUEST-----'),
    ('user34@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzRAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABB+EEbXVSThZaWkLDd3yGd+4JT2JGb0ytrworGnw\nuEpl1eUeX+PLAbxtj73ocIxECsydMenLKteemO+Kh1O5gGygLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzNEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIFIyZdoNUPN9HyStSFra5nAllOE7sGbC70ZMhxl2A+6PAiEA9VKDBr1k\nmFgA5IfDc0pT+8qqh9HRRN5gfnnyiRs1Qkk=\n-----END CERTIFICATE REQUEST-----'),
    ('user35@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzVAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABCGyC1o7yjPEODuu/ZfzKudOAhgNTQkVu8RyMa6T\nUIZLCmvh23N2tK9m8r5J7s+efkIzCeNEbjxPA5iBPIbxvBugLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzNUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDovOtH5JrAhnlI5XKKHWhMCoJZZqW8S6oUwzyqu88UTwIgJ0RCgOG2\neIS+DJFt69JYh/k4d57wED1Z4U4PPWRoSD8=\n-----END CERTIFICATE REQUEST-----'),
    ('user36@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzZAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABEqqGMMm03H1iOEvbdIKjqwSJ0Yl6RgMT3wSwFbl\n+rov7At3U5gfkWElxVXd7NVHqOivlXj6LaIO1szLj8E0a8igLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzNkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIGmnaTL3wztY+CRzr1aUZ8rHIPfSjEsQbCmba3rMsBUZAiAa7jwSeNVE\nkqxjt/dI6RFp3kOye+iB1p+EEBvGqrBuRA==\n-----END CERTIFICATE REQUEST-----'),
    ('user37@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzdAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABE+Cbco8nOo+OxGJKHsA0mFb3bx0m3de9usjJMhd\ndcRw5zP21OmuOoToJS6ewpiABqcG5kv0v1xpPYgtsHRKAX2gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzN0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIFsKaQJZHHJFbN8UMR1lDnYLPCOq6ntZzxHAuNGKdO3/AiB7CBPs6QTm\n6yKdhZrjW9LRJRouetWVi+zuONTp1VtBZw==\n-----END CERTIFICATE REQUEST-----'),
    ('user38@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzhAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABIx4h39klm7bCWCM53HLURFANU6Lycb+2WShqnQV\nmw0i1enuV/qbJ8i2I9INC86/CJSZzUUklMWasB0M7VOvk1ugLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzOEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCZyDGxtV6Yl5v9LiiRqN91merzWVD6+VEMaPsTalaiUwIhAJv4d8es\nvWCzfv5mkYAqW/SyJTNCesl7B2iTBH7LOwZd\n-----END CERTIFICATE REQUEST-----'),
    ('user39@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyMzlAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABGCrM7cv7OU7E9P0wgZY9Yz/mkc0mnicoUEFfUlz\neuBd5WDilObFFJWor+2OUDBrbzMGjwKP/x2mLV3rFjed2DCgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXIzOUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQCvsj4KTlANemnPepL69WADf/cy4dNkGDNErBUlLlgT0AIhAJxhxnlM\nzJ6R5Xw0uKUKmjZnBZTcCn+AOTc4dUf0ac/D\n-----END CERTIFICATE REQUEST-----'),
    ('user40@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBTCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDBAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABF6aXVuAcaMKUkdnCA7f7IRatavwx8qzSi+UDtmR\n0+t6kVvbLuZsXFNYfiDAR8cQCUBVMh7xbh20KM3Jhe0nMUegLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0MEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0cAMEQCIGRAvOij0bIlE0zzpMRo3GrmMJ0bAOtwNYl7Ix1w9GK0AiAX9wtnCs78\nlHtCjt+3JnkwfJUg/X/yQGcDpuEdlMvUNA==\n-----END CERTIFICATE REQUEST-----'),
    ('user41@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDFAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABIlmmd5STi+mkqEcW5AGKvZEUuhTmTlpAgGZ+jV3\ncPSR4KOhp0xcHAaa+KoSevHypxwvyuq38Vz4bijHQQ8wRdGgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0MUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDbQMu8GeIJhWTjbJKfdJRcWpxbhGevpn/YwYK5pINTewIhAIHNVBJ/\nQL1CLbA+4fW/0wnce927TQv5k+rtnatqshZ2\n-----END CERTIFICATE REQUEST-----'),
    ('user42@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBzCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDJAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABF8thK6yLeP78LL0Qf0tFZ/CsqD9EB8iv8CzD/ht\nH7yHayzKh8Z4u3Gn/NcTcCIaJgaFYVPj2OxMqfMuv5Xk6MagLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0MkB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0kAMEYCIQDE6Ias5EqaFM3O98Q914wcrZpeTGprecUR3vSofU1+KAIhAPN0oaLt\nOufbK4Xo2KJPjv89ec30zvdYXoLA1hyxVoGa\n-----END CERTIFICATE REQUEST-----'),
    ('user43@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDNAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABFke81rcekC1fqcD/SSQqyDkc9vmvVQSGEhMNHDH\ndxvYzvfqt3BZMHHfO3ATkbVdGRqlGvrJJCYyQ6tteZGD7iqgLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0M0B3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIQDf7vkfGycZy7LfOcFFt0S4T2pQa//t7HkLG7XRVssXSgIgMma2eyP2\n4rw9MLP2UXYRoyDzbCVR9HxjI64lztNRP68=\n-----END CERTIFICATE REQUEST-----'),
    ('user44@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDRAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABNkaB1Xq9jh3md1rQkBKUXwzUM5/fIENPODh3ygJ\nVmjBO4Yi8W2JJUbNbovf8G8KQW8u9VomJG2pQGe+9rmxQz6gLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0NEB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIFvbPrm71R3VE1wh9OduzUU/plYWhXrl65SttDD3/ClQAiEAzmeWQvLX\nEsyJq/yY3vD2XY52JCdORUeZdjltl1ibxqU=\n-----END CERTIFICATE REQUEST-----'),
    ('user45@wifi.local', E'-----BEGIN CERTIFICATE REQUEST-----\nMIIBBjCBrQIBADAcMRowGAYDVQQDDBF1c2VyNDVAd2lmaS5sb2NhbDBZMBMGByqG\nSM49AgEGCCqGSM49AwEHA0IABJJf+JbIZQucrjpz+3BLlwyLCbb2FKcFwK60inKn\nGuQ3I0iwRS3bSoGQRSogYkLcItI+QTe14eughruEUtd9JBigLzAtBgkqhkiG9w0B\nCQ4xIDAeMBwGA1UdEQQVMBOBEXVzZXI0NUB3aWZpLmxvY2FsMAoGCCqGSM49BAMC\nA0gAMEUCIEOsk4Yaa9zmd7APFO5rnxJAn56xvNeihHmKTGThE29WAiEA4qoK30el\nYhRBqV5h1C6AE+3agBbQ2euA87fy0ui6RjA=\n-----END CERTIFICATE REQUEST-----')
       ) AS v(username, csr)
WHERE  v.username = (SELECT d.username FROM devices d WHERE d.id = r.device_id);
