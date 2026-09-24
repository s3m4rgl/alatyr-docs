# REST API

Эта страница — систематический перечень HTTP-эндпоинтов сервера Alatyr:
метод, путь и одна строка назначения. За ролевой матрицей доступа и
подробным разбором ключевых потоков (approve/reject/revoke, сервисные
аккаунты, сети) — в [Администрирование](administration.md); за SSH Key
Registry и Keyholder API отдельно — в [Реестре ключей](ssh/registry.md).

Базовый префикс — `/api/v1`. Вне его живут три служебных пути: `GET /health`,
`GET /metrics` и интерактивная спецификация `GET /swagger/`.

Формат ответа — JSON, кроме четырёх мест:

| Путь | Что отдаёт |
|---|---|
| `GET /api/v1/ssh/krl` | двоичный файл OpenSSH KRL |
| `GET /api/v1/keyholder/krl` | то же, для целевого сервера |
| `GET /api/v1/certificates/{serial}/bundle` | ZIP |
| `GET /metrics` | текстовая экспозиция Prometheus |

## Аутентификация

Большинство эндпоинтов требуют `Authorization: Bearer <token>` — либо JWT
(Keycloak или локальная аутентификация), либо токен сервисного аккаунта
(`wca_*`). Ролевая модель (`cert-admin`/`cert-approver`/`cert-viewer`/
`cert-auto-approver`) описана в [Администрирование](administration.md),
раздел «Роли».

Отдельная, не-Bearer схема авторизации — у эндпоинтов, которыми пользуется
агент, а не человек или UI:

- `POST /api/v1/enroll` и остальные `/enroll/*` — сессии администратора не
  требуют, но подчиняются собственным проверкам: nonce, `enrollment_token`
  устройства, source-auth, corp-verify, ограничение частоты.
- `GET /api/v1/requests/{id}/status`, `/bundle-version`, `/certificate` и
  `POST /api/v1/requests/{id}/checkin`, `/logs` — заголовок
  `X-Agent-Secret`, выданный при `/enroll`.
- `/api/v1/keyholder/*` — разрешённые сети (CIDR) плюс ограничение частоты
  плюс необязательный серверный токен. Разбор — в
  [Реестре ключей](ssh/registry.md).
- `POST /api/v1/k8s/credential` — взаимный TLS на отдельном слушателе, см.
  раздел «Выдача credential для Kubernetes» ниже.

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
| `POST /api/v1/enroll` | Регистрация устройства и отправка CSR (машинная цель `wifi`) |
| `POST /api/v1/enroll/nonce` | Выдача одноразового nonce (и, для первого TPM-аттестованного enroll, challenge Credential Activation) |
| `POST /api/v1/enroll/source-nonce` | Выдача nonce для подписи источника заявки (source-auth) |
| `POST /api/v1/enroll/user` | Регистрация пользовательской заявки для уже существующего устройства (`user_mtls`/`ad_logon`) |
| `POST /api/v1/enroll/ssh` | Регистрация SSH-заявки для уже существующего устройства |
| `POST /api/v1/enroll/ssh-key` | Регистрация «сырого» hardware-backed SSH публичного ключа |
| `POST /api/v1/enroll/ssh-key/status` | Текущий статус SSH-ключей этого устройства (агент показывает его в своём окне) |
| `POST /api/v1/enroll/token-recover` | Восстановление `enrollment_token` устройства по доказательству владения закреплённым аппаратным ключом |
| `POST /api/v1/enroll/app-attest/challenge` | Challenge для Apple App Attest |
| `POST /api/v1/enroll/app-attest` | Приём аттестации Apple App Attest |
| `POST /api/v1/enroll/identity-sid` | Поиск SID пользователя по UPN — для машин вне домена, см. [Настройка входа по карте](ad-logon/setup.md#шаг-5-настройте-каталог-если-машины-вне-домена) |
| `POST /api/v1/enroll/purposes` | Какие цели назначены этому устройству |
| `POST /api/v1/enroll/purpose-request` | Запрос цели с самого устройства (сотрудник просит, администратор решает) |
| `POST /api/v1/enroll/crl` | Списки отзыва для клиента вне домена, см. [Вход по RDP](ad-logon/rdp.md#клиент-вне-домена-списки-отзыва-контроллера) |
| `POST /api/v1/enroll/issuance-directives/{id}/report` | Отчёт устройства об исходе адресного предписания на выдачу |
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

Подробности модели — в [Реестре ключей](ssh/registry.md).

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/ssh-keys` | Список всех зарегистрированных SSH-ключей по флоту |
| `POST /api/v1/admin/ssh-keys/{id}/approve` | Одобрение ожидающего SSH-ключа |
| `POST /api/v1/admin/ssh-keys/{id}/reject` | Отклонение ожидающего SSH-ключа |
| `POST /api/v1/admin/ssh-keys/{id}/revoke` | Отзыв активного (или отклонение ожидающего) SSH-ключа |
| `GET /api/v1/devices/{serial}/ssh-keys` | SSH-ключи, зарегистрированные одним устройством |

### Общие учётные записи (`principal-aliases`)

Псевдоним — одна учётная запись на сервере (`deploy`, `svc-backup`), за
которой стоит несколько людей. Он отвечает на вопрос «кто на самом деле вошёл
под общим логином».

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/principal-aliases` | Список псевдонимов общих учётных записей |
| `POST /api/v1/admin/principal-aliases` | Создать псевдоним |
| `DELETE /api/v1/admin/principal-aliases/{alias}` | Удалить псевдоним |
| `PUT /api/v1/admin/principal-aliases/{alias}/enabled` | Включить/выключить псевдоним |
| `GET /api/v1/admin/principal-aliases/{alias}/keys` | Кто стоит за псевдонимом: ключи и их владельцы |
| `POST /api/v1/admin/principal-aliases/{alias}/members` | Добавить участника |
| `DELETE /api/v1/admin/principal-aliases/{alias}/members/{member}` | Убрать участника |

## Keyholder API (`keyholder`)

Группа маршрутов для **целевых серверов**, а не для людей. Доступ к ней
определяется разрешёнными сетями, а не ролями; подробности и порядок
проверок — в [Реестре ключей](ssh/registry.md).

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/keyholder/keys` | Список активных SSH публичных ключей для логина (для `AuthorizedKeysCommand`) |
| `GET /api/v1/keyholder/krl` | Список отзыва для директивы `RevokedKeys` на целевом сервере |
| `GET /api/v1/keyholder/principals` | Какими именами учётных записей сертификат ещё вправе пользоваться — онлайновая проверка вместо файла KRL |
| `GET /api/v1/keyholder/revocations` | Лента отзывов для сторожа сессий на целевом хосте: `sshd` проверяет право на вход один раз, и уже открытую сессию закрывает сам хост |

Управление серверными токенами — обычные админские маршруты:

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/keyholder-token-gate` | Текущая ступень требования токена (выключен / наблюдение / обязателен) |
| `GET /api/v1/admin/keyholder-tokens` | Список токенов keyholder-серверов (без значений) |
| `POST /api/v1/admin/keyholder-tokens` | Создание нового токена keyholder-сервера |
| `PUT /api/v1/admin/keyholder-tokens/{id}/principals` | Ограничить токен списком имён учётных записей |
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
| `GET /api/v1/devices/{serial}/purposes` | Какие цели назначены устройству |
| `PUT /api/v1/devices/{serial}/purposes` | Назначить устройству цели |
| `POST /api/v1/devices/{serial}/purposes/{purpose}/decision` | Решение по цели, запрошенной с самого устройства |
| `GET /api/v1/admin/purpose-requests` | Очередь целей, запрошенных с устройств и ждущих решения |
| `PUT /api/v1/devices/{serial}/owner` | Сменить владельца устройства |
| `PUT /api/v1/devices/{serial}/purpose-overrides` | Переопределить системную политику выдачи для устройства, по каждой цели отдельно (`наследовать`/`разрешить`/`запретить`) |
| `GET /api/v1/admin/purpose-overrides/{purpose}/cost` | Сколько устройств и переопределений затронет массовый сброс переопределений цели |
| `DELETE /api/v1/admin/purpose-overrides/{purpose}` | Сбросить переопределения цели у всего парка |
| `GET /api/v1/devices/{serial}/logs` | Список снапшотов логов устройства |
| `GET /api/v1/devices/{serial}/logs/{logId}` | Один снапшот лога (с содержимым) |
| `DELETE /api/v1/devices/{serial}/logs/{logId}` | Удалить снапшот лога |
| `POST /api/v1/devices/{serial}/request-logs` | Запросить свежий снапшот логов с устройства |
| `DELETE /api/v1/devices/{serial}/request-logs` | Отменить ожидающий запрос логов |
| `POST /api/v1/devices/{serial}/rotate-enrollment-token` | Ротация enrollment-токена устройства |
| `POST /api/v1/devices/{serial}/revoke` | Отозвать все активные сертификаты устройства и, если это удалось для каждого из них, освободить license-слот (decommission) — подробнее в [Лицензировании](licensing.md#отзыв-удаление-записи-и-decommission--в-чём-разница) |
| `POST /api/v1/devices/{serial}/unblock` | Снять блокировку устройства (device-block-on-revoke) |
| `POST /api/v1/users/{identity}/revoke-certs` | Отозвать все активные сертификаты пользователя (по identity) |

### Отвязка аппаратных ключей устройства

Четыре разные привязки, и каждая снимается отдельно. Снятие означает «Alatyr
забывает закреплённый ключ», после чего устройство закрепляет новый на
следующем обращении.

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/devices/{serial}/unbind-tpm` | Снять привязку к TPM, чтобы устройство могло закрепиться заново |
| `POST /api/v1/devices/{serial}/release-tpm-pin` | Забыть AK, подтверждённый Credential Activation, чтобы устройство аттестовалось заново |
| `POST /api/v1/devices/{serial}/release-enroll-key` | Забыть ключ заявки, закреплённый за устройством |
| `POST /api/v1/devices/{serial}/release-continuity-key` | Сбросить ключ непрерывности устройства |

### Адресные предписания на выдачу (`issuance-directives`)

Предписание адресует цель конкретному человеку на конкретном устройстве —
чтобы заявка ушла от того, от кого ожидается, а не от того, кто первым сел за
машину.

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/issuance-directives` | Очередь предписаний по всему флоту |
| `POST /api/v1/devices/{serial}/issuance-directives` | Адресовать цель человеку на этом устройстве |
| `GET /api/v1/devices/{serial}/issuance-directives` | Предписания одного устройства |
| `DELETE /api/v1/admin/issuance-directives/{id}` | Отменить предписание |

## Admin — сертификаты и аудит

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/certificates/{serial}/bundle` | Скачать бандл сертификата как ZIP |
| `POST /api/v1/certificates/{serial}/revoke` | Отозвать сертификат |
| `PUT /api/v1/certificates/{serial}/key-protection` | Назначить конкретному сертификату ступень подтверждения владельца |
| `GET /api/v1/audit` | Список записей аудит-лога |
| `GET /api/v1/audit.csv` | То же, экспорт CSV |
| `GET /api/v1/admin/stats` | Статистика дашборда |

!!! note "Отзыв там, где издатель отзыва не умеет"
    У SCEP операции отзыва нет вовсе. Запрос всё равно выполняется: строка в
    Alatyr помечается отозванной, а в ответе приходит
    `ca_revoke_unsupported=true` и предупреждение — **на стороне внешнего УЦ
    сертификат остаётся действительным**, и снять его там нужно руками.
    Отказом (`404`) отвечает только случай, когда серийник неизвестен ни
    издателю, ни базе: сообщать об отзыве, которого не было, продукт не
    станет. Подробнее — [Известные ограничения](limitations.md#scep).

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
| `PUT /api/v1/admin/networks/{id}/radius-server-names` | Имена RADIUS-сервера для этой сети; пустой массив означает, что имя не проверяется |

Что означают эти настройки и как их задают в админке — [Wi-Fi и проводной
802.1X](wifi/index.md).

## Admin — доступ к Kubernetes

Реестр кластеров: что именно поедет на устройство, к какому кластеру и под
каким субъектом. Как это настраивается — [Доступ к
Kubernetes](k8s/setup.md#шаг-4-заведите-кластеры-в-реестре).

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/admin/k8s-clusters` | Реестр кластеров Kubernetes |
| `POST /api/v1/admin/k8s-clusters` | Завести кластер |
| `PUT /api/v1/admin/k8s-clusters/{id}` | Изменить кластер |
| `DELETE /api/v1/admin/k8s-clusters/{id}` | Удалить кластер |

### Выдача credential для Kubernetes

| Метод и путь | Назначение |
|---|---|
| `POST /api/v1/k8s/credential` | Выдать эфемерный клиентский сертификат для кластера (10 минут) |

Этот маршрут **не входит в общий HTTP-слушатель сервера**: у него свой
слушатель со взаимным TLS, адрес которого задаёт `ALATYR_K8S_BROKER_URL`.
Поэтому ни Bearer-токен, ни разрешённые сети Keyholder к нему не относятся:
клиент предъявляет сертификат, и им же определяется, кто просит. Настройка —
[Доступ к Kubernetes](k8s/setup.md#шаг-3-включите-брокер-на-сервере-alatyr).

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
| `PUT /api/v1/service-accounts/{id}/allowed-purposes` | Какие цели этому токену разрешено одобрять автоматически |
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
| `GET /api/v1/settings/agent-update/stuck` | Служебный список устройств, застрявших посреди принудительного обновления агента |
| `GET /api/v1/settings/platform-update` | Уведомление об обновлении платформы (сервер + фронтенд) |

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
| `GET /api/v1/settings/enroll-source-auth` | Получить политику enroll source-auth |
| `PUT /api/v1/settings/enroll-source-auth` | Обновить политику enroll source-auth |

Nonce для подписи источника выдаёт `POST /api/v1/enroll/source-nonce` — он в
таблице агентских маршрутов выше.

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
| `GET /metrics` | Метрики Prometheus — см. [Эксплуатация](operations.md#метрики-prometheus) |
| `GET /swagger/` | Интерактивная спецификация OpenAPI этого же сервера |
| `GET /api/v1/version` | Версия сервиса (для корреляции с логами, см. [Логирование](logging.md)) |
| `GET /api/v1/features` | Публичные feature-флаги |
| `GET /api/v1/issuer` | Возможности активного issuer'а |

!!! warning "`/metrics` не аутентифицируется"
    Это сделано намеренно: у сборщика Prometheus нет учётных данных, а
    эндпоинт за аутентификацией тихо перестают собирать. Идентификаторов
    устройств и людей там нет по построению, но объём запросов и доля ошибок
    — тоже сведения о развёртывании. Закрывайте его на уровне ingress, как
    любой внутренний адрес: сам обработчик этого сделать не может.
