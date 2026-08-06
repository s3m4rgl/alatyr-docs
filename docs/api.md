# REST API

Эта страница — систематический перечень HTTP-эндпоинтов сервера Alatyr:
метод, путь и одна строка назначения. За ролевой матрицей доступа и
подробным разбором ключевых потоков (approve/reject/revoke, сервисные
аккаунты, сети) — в [Администрирование](administration.md); за SSH Key
Registry и Keyholder API отдельно — в [SSH Key Registry](ssh-keys.md).

Базовый префикс — `/api/v1` (кроме `GET /health`). Формат ответа — JSON
(кроме `GET /api/v1/ssh/krl`, отдающего бинарный OpenSSH KRL-файл, и
`GET /api/v1/certificates/{serial}/bundle`, отдающего ZIP).

## Аутентификация

Большинство эндпоинтов требуют `Authorization: Bearer <token>` — либо JWT
(Keycloak или локальная аутентификация), либо токен сервисного аккаунта
(`wca_*`). Ролевая модель (`cert-admin`/`cert-approver`/`cert-viewer`/
`cert-auto-approver`) описана в [Администрирование](administration.md),
раздел «Роли».

Отдельная, не-Bearer схема авторизации — у эндпоинтов, которыми пользуется
агент, а не человек/UI:

- `POST /api/v1/enroll`, `/enroll/user`, `/enroll/ssh`, `/enroll/ssh-key` —
  неаутентифицированы на входе (создание заявки), но подчиняются
  собственным проверкам (nonce, source-auth, corp-verify, rate-limit).
- `GET /api/v1/requests/{id}/status`, `/bundle-version`, `/certificate` и
  `POST /api/v1/requests/{id}/checkin`, `/logs` — заголовок
  `X-Agent-Secret`, выданный при `/enroll`.
- `GET /api/v1/keyholder/keys` — IP-allowlist + rate-limit + опциональный
  токен (см. [SSH Key Registry](ssh-keys.md)).

## Аутентификация и сессия (`auth`)

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/auth/callback` | Обмен PKCE authorization code на access/refresh токены (Keycloak) |
| `POST /api/v1/auth/refresh` | Обновление access-токена по refresh-токену |
| `POST /api/v1/auth/logout` | Выход (инвалидация сессии) |
| `GET /api/v1/auth/me` | Текущий пользователь (email, роль) |
| `GET /api/v1/auth/config` | Публичная конфигурация аутентификации |
| `POST /api/v1/auth/local/login` | Локальный логин по email+паролю |
| `POST /api/v1/auth/change-password` | Смена собственного пароля (локальная аутентификация) |

## Enrollment и агент (`agent`)

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/enroll` | Регистрация устройства и отправка CSR (machine `wifi`) |
| `POST /api/v1/enroll/nonce` | Выдача одноразового nonce (и, для первого TPM-аттестованного enroll, challenge Credential Activation) |
| `POST /api/v1/enroll/user` | Регистрация per-user заявки для уже существующего устройства (`user_mtls`/`ad_logon`) |
| `POST /api/v1/enroll/ssh` | Регистрация SSH-заявки для уже существующего устройства |
| `GET /api/v1/requests/{id}/status` | Статус заявки на выпуск |
| `POST /api/v1/requests/{id}/checkin` | Check-in агента (подтверждение установки сертификата) |
| `POST /api/v1/requests/{id}/logs` | Загрузка снапшота лога агента |
| `GET /api/v1/requests/{id}/bundle-version` | Лёгкий probe версии бандла для steady-state синхронизации SSID — агент вызывает его почти на каждой итерации; тяжёлый `.../certificate` вызывается только при расхождении версии |
| `GET /api/v1/requests/{id}/certificate` | Скачивание подписанного сертификата + CA bundle (поддерживает ETag/If-None-Match для steady-state поллинга) |

## SSH (`ssh`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/ssh/ca-public-key` | Публичный ключ SSH CA в формате authorized-keys (для директивы `TrustedUserCAKeys` в `sshd`) |
| `GET /api/v1/ssh/krl` | Текущий SSH Key Revocation List (для директивы `RevokedKeys` в `sshd`) |

## SSH-ключи (`ssh-keys`)

Подробности модели — в [SSH Key Registry](ssh-keys.md).

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/enroll/ssh-key` | Регистрация «сырого» hardware-backed SSH публичного ключа |
| `GET /api/v1/admin/ssh-keys` | Список всех зарегистрированных SSH-ключей по флоту |
| `POST /api/v1/admin/ssh-keys/{id}/approve` | Одобрение ожидающего SSH-ключа |
| `POST /api/v1/admin/ssh-keys/{id}/reject` | Отклонение ожидающего SSH-ключа |
| `POST /api/v1/admin/ssh-keys/{id}/revoke` | Отзыв активного (или отклонение ожидающего) SSH-ключа |
| `GET /api/v1/devices/{serial}/ssh-keys` | SSH-ключи, зарегистрированные одним устройством |

## Keyholder API (`keyholder`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/keyholder/keys` | Возвращает список активных SSH публичных ключей для логина (для `AuthorizedKeysCommand`) |
| `GET /api/v1/admin/keyholder-tokens` | Список токенов keyholder-серверов (без значений) |
| `POST /api/v1/admin/keyholder-tokens` | Создание нового токена keyholder-сервера |
| `DELETE /api/v1/admin/keyholder-tokens/{id}` | Отзыв токена keyholder-сервера |

## Admin — заявки и устройства

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/requests` | Список заявок на выпуск (с фильтрами) |
| `GET /api/v1/requests.csv` | То же, экспорт CSV |
| `POST /api/v1/requests/approve` | Массовое одобрение заявок |
| `POST /api/v1/requests/check-conflicts` | Проверка конфликтов серийников перед массовым одобрением |
| `POST /api/v1/requests/reject` | Массовое отклонение заявок |
| `GET /api/v1/devices` | Список зарегистрированных устройств |
| `GET /api/v1/devices.csv` | То же, экспорт CSV |
| `GET /api/v1/devices/agent-versions` | Список встречающихся версий агента |
| `PUT /api/v1/devices/{serial}/issue-policy-override` | Установить/снять override issue policy для устройства |
| `GET /api/v1/devices/{serial}/logs` | Список снапшотов логов устройства |
| `GET /api/v1/devices/{serial}/logs/{logId}` | Один снапшот лога (с содержимым) |
| `DELETE /api/v1/devices/{serial}/logs/{logId}` | Удалить снапшот лога |
| `POST /api/v1/devices/{serial}/request-logs` | Запросить свежий снапшот логов с устройства |
| `DELETE /api/v1/devices/{serial}/request-logs` | Отменить ожидающий запрос логов |
| `POST /api/v1/devices/{serial}/rotate-enrollment-token` | Ротация enrollment-токена устройства |
| `POST /api/v1/devices/{serial}/revoke` | Отозвать все активные сертификаты устройства и, если это удалось для каждого из них, освободить license-слот (decommission) — подробнее в [Лицензировании](licensing.md#отзыв-удаление-записи-и-decommission--в-чём-разница) |
| `POST /api/v1/devices/{serial}/unblock` | Снять блокировку устройства (device-block-on-revoke) |
| `POST /api/v1/users/{identity}/revoke-certs` | Отозвать все активные сертификаты пользователя (по identity) |

## Admin — сертификаты и аудит

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/certificates/{serial}/bundle` | Скачать бандл сертификата как ZIP |
| `POST /api/v1/certificates/{serial}/revoke` | Отозвать сертификат (недоступно для SCEP-issued — см. [Диагностика и ограничения](troubleshooting.md)) |
| `GET /api/v1/audit` | Список записей аудит-лога |
| `GET /api/v1/audit.csv` | То же, экспорт CSV |
| `GET /api/v1/admin/stats` | Статистика дашборда |

## Admin — сети

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/networks` | Список корпоративных сетей (Wi-Fi + проводные) |
| `GET /api/v1/admin/networks.csv` | То же, экспорт CSV |
| `POST /api/v1/admin/networks` | Создать сеть (Wi-Fi или проводную) |
| `DELETE /api/v1/admin/networks/{id}` | Полностью удалить сеть |
| `POST /api/v1/admin/networks/{id}/disable` | Отключить сеть (soft delete) |
| `POST /api/v1/admin/networks/{id}/restore` | Восстановить ранее отключённую сеть |
| `PUT /api/v1/admin/networks/{id}/agent-profile-disabled` | Переключатель opt-out агентского профиля для Windows/Linux |
| `PUT /api/v1/admin/networks/{id}/macos-agent-profile-disabled` | Переключатель opt-out MDM-профиля агента для macOS |

## Admin — пользователи

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/users` | Список пользователей с ролями |
| `GET /api/v1/users.csv` | То же, экспорт CSV |
| `POST /api/v1/users/local` | Создать локального (пароль) пользователя |
| `PUT /api/v1/users/{email}/roles` | Назначить роли пользователю |
| `PUT /api/v1/users/{email}/enabled` | Включить/выключить пользователя |
| `PUT /api/v1/users/{email}/password` | Сброс пароля локального пользователя администратором |

## Сервисные аккаунты (`service-accounts`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/service-accounts` | Список сервисных аккаунтов |
| `POST /api/v1/service-accounts` | Создать сервисный аккаунт |
| `PUT /api/v1/service-accounts/{id}/enabled` | Включить/выключить сервисный аккаунт |
| `DELETE /api/v1/service-accounts/{id}` | Удалить сервисный аккаунт |

## Вебхуки (`webhooks`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/webhooks` | Список webhook-эндпоинтов |
| `POST /api/v1/admin/webhooks` | Создать webhook-эндпоинт |
| `PUT /api/v1/admin/webhooks/{id}` | Обновить webhook-эндпоинт |
| `DELETE /api/v1/admin/webhooks/{id}` | Удалить webhook-эндпоинт |
| `PUT /api/v1/admin/webhooks/{id}/enabled` | Включить/выключить webhook-эндпоинт |
| `POST /api/v1/admin/webhooks/{id}/test` | Отправить тестовую доставку |
| `GET /api/v1/admin/webhooks/{id}/deliveries` | Постраничный журнал доставок webhook-эндпоинта — см. [Эксплуатация](operations.md#мониторинг-webhook-очереди-outbox) |

## Settings (`settings`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/settings/system` | Получить системные настройки |
| `PUT /api/v1/settings/system` | Обновить системные настройки |
| `GET /api/v1/settings/issuers` | Список issuer-профилей (по purpose) |
| `GET /api/v1/settings/issuers/{purpose}` | Получить один issuer-профиль |
| `PUT /api/v1/settings/issuers/{purpose}` | Создать/обновить issuer-профиль |
| `POST /api/v1/settings/issuers/{purpose}/test-connection` | Проверить связность issuer-профиля |
| `GET /api/v1/settings/agent-update/stuck` | Служебный список устройств для контроля версий агента |

## Corp-ownership verification (`corp-verify`)

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/corp-allowlist` | Список записей corp-ownership allowlist |
| `POST /api/v1/admin/corp-allowlist` | Добавить устройство в corp-ownership allowlist |
| `DELETE /api/v1/admin/corp-allowlist/{serial}` | Удалить устройство из corp-ownership allowlist |
| `GET /api/v1/settings/sa-auto-approve` | Получить политику corp-ownership verification для SA auto-approve |
| `PUT /api/v1/settings/sa-auto-approve` | Обновить политику corp-ownership verification для SA auto-approve |

## Enroll source-auth (`enroll-source-auth`)

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/enroll/source-nonce` | Выдача source-auth nonce |
| `GET /api/v1/settings/enroll-source-auth` | Получить политику enroll source-auth |
| `PUT /api/v1/settings/enroll-source-auth` | Обновить политику enroll source-auth |

## Лицензия (`license`)

Подробное описание лимита, статусов, decommission и восстановления журнала
учёта — в [Лицензировании](licensing.md).

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/license/status` | Статус лицензии |
| `POST /api/v1/license/activate` | Активировать лицензию |
| `POST /api/v1/license/attest` | Аттестация лицензии |
| `POST /api/v1/license/decommission` | Списать устройство (decommission) из лицензионного учёта |
| `POST /api/v1/license/reanchor` | Re-anchor usage ledger |

## Публичные и служебные

| Метод и путь | Назначение |
|---|---|
| `GET /health` | Health check |
| `GET /api/v1/version` | Версия сервиса (для корреляции с логами, см. [Логирование](logging.md)) |
| `GET /api/v1/features` | Публичные feature-флаги |
| `GET /api/v1/issuer` | Возможности активного issuer'а |
