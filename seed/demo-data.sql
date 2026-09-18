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
    '-----BEGIN CERTIFICATE REQUEST-----\nSEED-FAKE-CSR\n-----END CERTIFICATE REQUEST-----',
    '{"platform":"tpm2"}'::jsonb,
    CASE WHEN b.status IN ('installed','installing','approved')
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
    '-----BEGIN CERTIFICATE REQUEST-----\nSEED-TREND\n-----END CERTIFICATE REQUEST-----',
    ('aa:bb:' || lpad(d.days_ago::text, 2, '0') || ':' || lpad(g::text, 3, '0')),
    '-----BEGIN CERTIFICATE-----\nSEED-TREND\n-----END CERTIFICATE-----',
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
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKseedSSHpubkeyFAKEbase64materialxxxxxxxxxxxxxxxx seed@deploy-bot',
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
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKoldSSHpubkeySUPERSEDEDbase64material== seed@old',
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
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKnewSSHpubkeyCURRENTbase64material== seed@new',
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
     '', 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKfrankSSHpubkeyPENDINGbase64materialxxxxxx seed@frank',
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
INSERT INTO issuer_profiles (purpose, backend, vault_mount, vault_role, eku, key_usage, san_template, ttl_hours, key_protection, enabled, created_by, updated_at) VALUES
    ('wifi',      'vault', 'pki', 'wifi-cert',
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
    '-----BEGIN CERTIFICATE REQUEST-----\nSEED-FAKE-CSR\n-----END CERTIFICATE REQUEST-----',
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
