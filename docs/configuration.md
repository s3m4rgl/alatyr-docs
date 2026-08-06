# Конфигурация

На этой странице перечислены все переменные окружения, поддерживаемые
сервером Alatyr: значения по умолчанию, обязательность и назначение.

Эта страница — про переменные окружения **сервера**. Флаги и переменные
агента (`WIFI_CERT_SERVER`, `CORP_EMAIL` и т.д.) описаны в разделе «Агент»
на странице [Установка](installation.md).

## Сервер: базовые параметры

| Переменная | По умолчанию | Обязательна | Описание |
|---|---|---|---|
| `ALATYR_SERVER_PORT` | `8090` | нет | HTTP listen порт. |
| `ALATYR_DB_URL` | — | **да** | Строка подключения к PostgreSQL, например `postgres://user:pass@host:5432/alatyr`. |
| `ALATYR_CORS_ORIGINS` | — | нет | Список разрешённых CORS-origin через запятую. По умолчанию (пусто) — localhost dev-порты. |
| `ALATYR_LOG_LEVEL` | `info` | нет | `debug` \| `info` \| `warn` \| `error`. |
| `ALATYR_DEFAULT_SSID` | `CorpWiFi` | нет | Wi-Fi SSID, засеиваемый по умолчанию при первом старте, если список сетей пуст. |
| `ALATYR_DEV_MODE` | `false` | нет | Dev-режим: принимать `Bearer dev-token` как `cert-admin` без Keycloak. **Никогда не включайте в продакшене.** |

## Локальная аутентификация (email + пароль)

Сосуществует с Keycloak SSO — оба провайдера могут быть активны одновременно.

| Переменная | По умолчанию | Обязательна | Описание |
|---|---|---|---|
| `ALATYR_LOCAL_AUTH_ENABLED` | `false` | нет | Включить локальную email+password аутентификацию наряду с Keycloak. |
| `ALATYR_LOCAL_JWT_SECRET` 🔒 | — | условно | HS256-секрет для подписи локальных сессий, ≥32 байт. **Обязателен**, когда включена локальная аутентификация — иначе сервер падает при старте с ошибкой валидации. |
| `ALATYR_LOCAL_ADMIN_EMAIL` | — | нет | Email первого локального admin-аккаунта, создаваемого при пустой таблице пользователей (bootstrap). |
| `ALATYR_LOCAL_ADMIN_PASSWORD` 🔒 | — | нет | Пароль bootstrap-администратора. Уберите из манифеста развёртывания после первого запуска. |
| `ALATYR_LOCAL_ACCESS_TTL_MIN` | `15` | нет | TTL локального access-токена, минуты. |
| `ALATYR_LOCAL_REFRESH_TTL_DAYS` | `30` | нет | TTL локального refresh-токена, дни. |

🔒 — значение помечено как секрет: в примерах документации и в логах оно
маскируется (`<secret>`), никогда не печатается в открытом виде.

## Функциональные флаги, логи устройств, вебхуки

| Переменная | По умолчанию | Обязательна | Описание |
|---|---|---|---|
| `ALATYR_REMOTE_LOGS_ENABLED` | `false` | нет | Включить сбор логов с устройств по запросу (on-demand device-log collection). |
| `ALATYR_PLACEHOLDER_CONTINUITY_MERGE_ENABLED` | `false` | нет | Opt-in: разрешить устройству с placeholder-серийным номером повторно привязаться к своей прежней строке `devices` по `continuity_key`, избегая расхода нового license-слота при переустановке. По умолчанию выключено (security-favoring): каждый placeholder-serial enroll всегда получает новую строку — криптографически доказать «это та же машина» по неаттестованному железу через неаутентифицированный канал невозможно, это осознанный компромисс, управляемый оператором. |
| `ALATYR_MACOS_AGENT_PROFILE_DISABLED` | `false` | нет | Не отдавать macOS Wi-Fi/wired `.mobileconfig` в ответе агенту (агент пропускает собственную установку профиля). Включайте, когда macOS-профили раскатываются через MDM. На admin-bundle ZIP не влияет. |
| `ALATYR_WEBHOOKS_ENABLED` | `false` | нет | Включить исходящие вебхуки (эндпоинты, подписанная доставка, воркер). |
| `ALATYR_WEBHOOK_ENC_KEY` 🔒 | — | условно | AES-256 ключ (64 hex-символа) для шифрования секретов вебхуков at rest. **Обязателен**, когда вебхуки включены — сервер падает при старте, если ключ отсутствует или не декодируется в ровно 32 байта. |
| `ALATYR_WEBHOOK_POLL_SECONDS` | `10` | нет | Интервал опроса очереди доставки вебхуков, секунды. |
| `ALATYR_WEBHOOK_RETENTION_DAYS` | `30` | нет | Сколько дней хранить записи о доставке вебхуков перед удалением. |
| `ALATYR_WEBHOOK_MAX_ATTEMPTS` | `6` | нет | Максимум попыток доставки, после которых доставка помечается как неудавшаяся. |

## PKI-issuer (Vault / внешний SCEP CA)

| Переменная | По умолчанию | Обязательна | Описание |
|---|---|---|---|
| `ALATYR_ISSUER` | `vault` | нет | Backend выпуска сертификатов: `vault` \| `scep`. |
| `ALATYR_SCEP_URL` | — | условно | URL внешнего SCEP CA. **Обязателен**, когда `ALATYR_ISSUER=scep`. |
| `ALATYR_SCEP_CHALLENGE` 🔒 | — | условно | SCEP challenge password. **Обязателен**, когда `ALATYR_ISSUER=scep`. |
| `ALATYR_SCEP_CA_FINGERPRINT` | — | условно | Ожидаемый SHA-256 отпечаток сертификата SCEP CA. **Обязателен**, когда `ALATYR_ISSUER=scep`. |
| `ALATYR_SCEP_CA_IDENTIFIER` | — | нет | Идентификатор CA для multi-CA инсталляций (NDES). Опционально. |
| `ALATYR_SCEP_ENC_KEY` 🔒 | — | условно | AES-256 ключ (64 hex-символа) для шифрования SCEP poll-состояния at rest. **Обязателен**, когда `ALATYR_ISSUER=scep`. |
| `ALATYR_SCEP_POLL_SECONDS` | `30` | нет | Интервал опроса pending-заявок SCEP, секунды. |
| `ALATYR_AGENT_UPDATE_ALERT_MINUTES` | `30` | нет | Сколько минут устройство может провести в состоянии `agent_update_pending_since`, прежде чем фоновая сверка пометит его и отметит в алертах как никогда не отчитавшееся о принудительном обновлении. |

При `ALATYR_ISSUER=scep` смотрите также раздел про SCEP на странице
[Архитектура и PKI](architecture.md) и известные ограничения (нет revoke,
поллинг предполагает одну реплику сервера) на странице
[Отказоустойчивость](ha.md).

## TPM / аттестация

| Переменная | По умолчанию | Описание |
|---|---|---|
| `TPM_CA_DIR` | `./tpm-ca` | Каталог с доверенными CA-сертификатами производителей TPM. |
| `TPM_INTEL_EK_RECOVERY` | `true` | Best-effort онлайн-восстановление отсутствующих Intel PTT EK-сертификатов. Отключайте на air-gapped серверах. |
| `TPM_INTEL_EK_SERVER_URL` | — | Переопределить URL сервиса Intel EK (для тестов/зеркал). |
| `TPM_REJECT_UNATTESTED` | `false` | Отклонять TPM-резидентные ключи, для которых недостижим EK-сертификат (high-assurance режим). |
| `TPM_REJECT_SOFTWARE` | `false` | Отклонять proof'ы с `platform=software` (нет ни TPM, ни Secure Enclave вообще). По умолчанию выключено, чтобы не ломать существующий безаппаратный enroll; включайте для high-assurance флота. |
| `TPM_REQUIRE_AK_CERTIFY` | `false` | Флотовый переключатель принудительного контроля TPM2_Certify AK-to-EK proof-of-possession: отклоняет `platform=tpm2` proof'ы без прошедшей AK-Certify верификации, вместо того чтобы просто сообщать об этом через `ak_verified`. По умолчанию выключено (информационный rollout). |

## Vault

| Переменная | По умолчанию | Описание |
|---|---|---|
| `VAULT_ADDR` | — | Адрес Vault-сервера. |
| `VAULT_TOKEN` 🔒 | — | Статический Vault-токен (используется, когда `VAULT_ROLE_ID` пуст). |
| `VAULT_ROLE_ID` | — | Vault AppRole `role_id` (рекомендуется для продакшена). |
| `VAULT_SECRET_ID` 🔒 | — | Vault AppRole `secret_id` (продакшен). |
| `VAULT_PKI_MOUNT` | `pki` | Путь монтирования PKI-движка Vault. |
| `VAULT_PKI_ROLE` | `alatyr` | Имя PKI-роли Vault. |
| `VAULT_CA_CERT_PATH` | — | Опциональный PEM-бандл для доверия TLS Vault. |
| `VAULT_CERT_TTL_HOURS` | `26280` | TTL выпускаемого сертификата в часах (по умолчанию 3 года). |

## Keycloak

| Переменная | По умолчанию | Описание |
|---|---|---|
| `KEYCLOAK_URL` | — | Базовый URL Keycloak. |
| `KEYCLOAK_REALM` | — | Realm Keycloak. |
| `KEYCLOAK_CLIENT_ID` | — | OIDC client id Keycloak. |
| `KEYCLOAK_CLIENT_SECRET` 🔒 | — | OIDC client secret (confidential client). |

## Валидация при старте

Сервер выполняет две проверки при запуске:

**Фатальные проверки** — сервер не стартует, если хоть одна
не выполнена:

- `ALATYR_DB_URL` не задан → `ALATYR_DB_URL is not set — provide the
  PostgreSQL connection string, e.g. postgres://user:pass@host:5432/alatyr`.
- Локальная аутентификация включена, но `ALATYR_LOCAL_JWT_SECRET` короче
  32 байт → `ALATYR_LOCAL_JWT_SECRET must be at least 32 bytes when
  ALATYR_LOCAL_AUTH_ENABLED=true`.
- Вебхуки включены, но `ALATYR_WEBHOOK_ENC_KEY` не задан или не
  декодируется в ровно 32 байта hex → соответствующая ошибка,
  предлагающая `openssl rand -hex 32`.
- `ALATYR_ISSUER=scep`, но не хватает одного из `ALATYR_SCEP_URL` /
  `ALATYR_SCEP_CHALLENGE` / `ALATYR_SCEP_CA_FINGERPRINT` / корректного
  `ALATYR_SCEP_ENC_KEY` → соответствующая ошибка per-переменной.
- `ALATYR_ISSUER` — не `vault`, не `scep` и не пусто → `ALATYR_ISSUER must
  be 'vault' or 'scep', got "<значение>"`.

Все найденные проблемы объединяются в одно сообщение вида
`configuration error:\n  - <проблема 1>\n  - <проблема 2>...` — сервер
покажет сразу весь список, а не только первую ошибку.

**Предупреждающая проверка** — не фатальна, только
предупреждение в лог: если не настроен ни `VAULT_TOKEN`, ни пара
`VAULT_ROLE_ID`+`VAULT_SECRET_ID`, сервер всё равно стартует, но подписание
сертификатов будет падать до тех пор, пока Vault не сконфигурирован.

## `DB_PASSWORD` — переменная только для docker-compose

`docker-compose.yml` использует host-only переменную `DB_PASSWORD`,
которая подставляется в `ALATYR_DB_URL` самим `docker-compose.yml` до старта
контейнера — сервер её напрямую никогда не читает и не знает о её
существовании. Не путайте с переменными сервера выше.
