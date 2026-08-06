# Архитектура

## Компоненты и потоки данных

Alatyr состоит из Go-сервера (единственный компонент, обращающийся к базе
данных и внешним PKI-бэкендам), кросс-платформенного агента (macOS/Windows/
Linux) и Admin UI на React. Агент и Admin UI никогда не обращаются к базе
данных или Vault/SCEP напрямую — весь доступ идёт через REST API сервера.

```mermaid
flowchart LR
    subgraph Devices["Устройства"]
        AgentMac["Агент — macOS\n(Secure Enclave)"]
        AgentWin["Агент — Windows\n(TPM)"]
        AgentLinux["Агент — Linux\n(TPM)"]
    end

    Admin["Admin UI (React)"]

    subgraph Server["Alatyr Server (Go)"]
        Unauth["/enroll, /enroll/user, /enroll/ssh,\n/enroll/ssh-key, /requests/:id/checkin, /auth/*\n(без авторизации, per-IP rate-limit)"]
        AdminAPI["Admin API\nтребует роль\n(cert-viewer / cert-approver / cert-admin)"]
        PKIReg["PKI Registry\n(независимый backend на каждую цель)"]
        Outbox["Webhook outbox\n(очередь исходящих событий)"]
        Keyholder["Keyholder API\n(без авторизации, per-IP allowlist,\nне per-role)"]
    end

    DB[("PostgreSQL\nустройства, заявки на выпуск,\nSSH-ключи, журнал аудита")]
    Vault[("HashiCorp Vault\nPKI engine + SSH secrets engine")]
    SCEPCA[("Внешний SCEP CA\n(например, NDES/ADCS)")]

    AgentMac -- "enroll / checkin\nHTTPS" --> Unauth
    AgentWin -- "enroll / checkin\nHTTPS" --> Unauth
    AgentLinux -- "enroll / checkin\nHTTPS" --> Unauth
    Admin -- "OIDC / local auth" --> AdminAPI
    Unauth --> DB
    AdminAPI --> DB
    AdminAPI --> PKIReg
    AdminAPI --> Outbox
    PKIReg --> Vault
    PKIReg --> SCEPCA
    Keyholder --> DB
    Outbox -- "HMAC-signed события\n(X-Alatyr-Signature)" --> ExternalHooks["Внешние webhook-получатели"]
```

Keyholder API — не отдельный, внешний по отношению к остальной системе
сервис, а отдельная группа маршрутов того же Go-сервера, со своей моделью
доступа (per-IP allowlist вместо ролей) вместо обычной авторизации Admin
API. `sshd` на каждом хосте опрашивает его через `AuthorizedKeysCommand`,
чтобы получить актуальный список публичных SSH-ключей зарегистрированного
пользователя из PostgreSQL.

Заявки на выпуск всегда создаются через неавторизованные
`/enroll*`-эндпоинты (по токену регистрации устройства, не по учётной
записи администратора) и переходят в статус `pending`; их рассматривает
администратор через Admin API, требующий роль `cert-approver`/`cert-admin`.
Сертификатный SSH не выпускается автоматически: `/enroll/ssh`, как и
`/enroll/user`, всегда оставляет заявку в `pending`. У отдельной
подсистемы SSH Key Registry — своя настройка автоодобрения, см.
[SSH Key Registry](ssh-keys.md). Каждое изменение состояния (одобрение, отзыв,
смена ролей) фиксируется в журнале аудита.

Вебхуки — исходящий outbox: события (например, «заявка одобрена»,
«сертификат отозван») складываются в очередь доставки, а фоновый воркер
вычитывает готовые к отправке события — блокировка на уровне строк
позволяет запускать несколько воркеров параллельно без дублирования
доставки, — подписывает тело запроса HMAC-секретом получателя и
ретраит с экспоненциальным backoff при ошибке.

## PKI / CA — per-purpose registry

Alatyr не использует единый глобальный CA. Каждый тип сертификата или
ключа (`wifi`, `user_mtls`, `ad_logon`, `ssh`) настраивается на свой
независимый источник выпуска, полностью отдельно от остальных:

```mermaid
flowchart TD
    Reg["Выбор источника выпуска\nпо типу сертификата/ключа"]
    Reg -->|wifi| B1{"backend?\n(если не настроен —\nfallback на Vault)"}
    Reg -->|user_mtls| B2{"backend?\n(источник должен быть\nявно настроен)"}
    Reg -->|ad_logon| B3["только SCEP\n(Vault PKI не умеет выпускать\nрасширение, необходимое\nдля KB5014754)"]
    Reg -->|ssh| B4["только Vault SSH\nsecrets engine\n(без отзыва/ротации через CA —\nу этого механизма своя модель)"]

    B1 -->|vault| V1["Vault PKI engine\n(mount/role для wifi)"]
    B1 -->|scep| S1["Внешний SCEP CA\n(mount/role для wifi)"]
    B2 -->|vault| V2["Vault PKI engine\n(mount/role для user_mtls)"]
    B2 -->|scep| S2["Внешний SCEP CA\n(mount/role для user_mtls)"]
    B3 --> S3["Внешний SCEP CA\n(NDES / ADCS)"]
    B4 --> V4["Vault SSH secrets engine"]
```

Каждый purpose настраивается отдельной строкой `issuer_profiles` — можно
держать `wifi` на Vault, а `ad_logon` на корпоративном NDES/ADCS
одновременно. `wifi` — единственный purpose с fallback-поведением: если
для него нет строки в `issuer_profiles` (или она выключена), сервер
использует Vault-issuer, сконфигурированный переменными окружения при
старте — это гарантирует, что развёртывания без per-purpose PKI работают
без изменений. У `user_mtls`, `ad_logon` и `ssh` такого fallback нет:
без явно настроенного и включённого профиля выпуск для этих целей
отклоняется.

`ad_logon` — единственная цель с жёстко зафиксированным источником
выпуска: сервер всегда требует SCEP для этой цели, независимо от
настроек, потому что Vault PKI не умеет выпускать расширение
сертификата, необходимое для strong certificate mapping (KB5014754) —
без него Windows-логин по смарт-карте не пройдёт строгую проверку
соответствия. SSH устроен похоже, но ещё строже: OpenSSH-сертификат —
не X.509 (подписывается сырой публичный ключ, а не запрос на
сертификат), и у выпуска SSH-сертификатов нет операции отзыва или
ротации CRL в принципе — у Vault SSH secrets engine такой концепции
попросту нет. Поэтому для цели `ssh` источником выпуска может быть
только Vault SSH secrets engine — любая другая настройка для этой
цели считается ошибкой конфигурации.

**Отзыв.** У `wifi`/`user_mtls`/`ad_logon` — стандартный путь CA
(CRL/OCSP). У `ssh` такого пути нет вообще: единственное средство
отзыва — Key Revocation List (KRL, `GET /api/v1/ssh/krl`), который
сервер формирует по списку отозванных ключей в стандартном бинарном
формате OpenSSH (`PROTOCOL.krl`) при каждом запросе; `sshd` регулярно
перечитывает файл через директиву `RevokedKeys`.
