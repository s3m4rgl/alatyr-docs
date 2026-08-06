# Архитектура и PKI

## Компоненты и потоки данных

Alatyr состоит из Go-сервера (единственный компонент, обращающийся к базе
данных и внешним PKI-бэкендам), кросс-платформенного агента (macOS/Windows/
Linux) и Admin UI на React. Агент и Admin UI никогда не обращаются к базе
данных или Vault/SCEP напрямую — весь доступ идёт через REST API сервера.

```mermaid
flowchart LR
    subgraph Devices["Устройства"]
        AgentMac["Агент — macOS<br/>(Secure Enclave)"]
        AgentWin["Агент — Windows<br/>(TPM)"]
        AgentLinux["Агент — Linux<br/>(TPM)"]
    end

    Admin["Admin UI (React)"]

    subgraph Server["Alatyr Server (Go)"]
        Unauth["/enroll, /enroll/user, /enroll/ssh,<br/>/enroll/ssh-key, /requests/:id/checkin, /auth/*<br/>(без авторизации, per-IP rate-limit)"]
        AdminAPI["Admin API<br/>требует роль<br/>(cert-viewer / cert-approver /<br/>cert-admin / cert-auto-approver)"]
        PKIReg["PKI Registry<br/>(независимый PKI-бэкенд на каждый purpose)"]
        Outbox["Webhook outbox<br/>(очередь исходящих событий)"]
        Keyholder["Keyholder API<br/>(без авторизации, per-IP allowlist,<br/>не per-role)"]
    end

    DB[("PostgreSQL<br/>устройства, заявки на выпуск,<br/>SSH-ключи, журнал аудита")]
    Vault[("HashiCorp Vault<br/>PKI engine + SSH secrets engine")]
    SCEPCA[("Внешний SCEP CA<br/>(например, NDES/ADCS)")]

    AgentMac -- "enroll / checkin<br/>HTTPS" --> Unauth
    AgentWin -- "enroll / checkin<br/>HTTPS" --> Unauth
    AgentLinux -- "enroll / checkin<br/>HTTPS" --> Unauth
    Admin -- "OIDC / local auth" --> AdminAPI
    Unauth --> DB
    AdminAPI --> DB
    AdminAPI --> PKIReg
    AdminAPI --> Outbox
    PKIReg --> Vault
    PKIReg --> SCEPCA
    Keyholder --> DB
    Outbox -- "HMAC-signed события<br/>(X-Alatyr-Signature)" --> ExternalHooks["Внешние webhook-получатели"]
```

Keyholder API — не самостоятельный сервис, а отдельная группа маршрутов
внутри того же Go-сервера. От Admin API он отличается моделью доступа:
вместо ролей — allowlist по IP. `sshd` на каждом хосте опрашивает его
через `AuthorizedKeysCommand`,
чтобы получить актуальный список публичных SSH-ключей зарегистрированного
пользователя из PostgreSQL.

Заявки на выпуск всегда создаются через неавторизованные
`/enroll*`-эндпоинты (по токену регистрации устройства, не по учётной
записи администратора) и переходят в статус `pending`; их рассматривает
администратор через Admin API, требующий роль `cert-approver`/`cert-admin`,
либо — без участия человека — сервисный аккаунт с ролью
`cert-auto-approver`, машинной ролью наименьших привилегий, которая умеет
только одобрять заявки, проходящие независимую последовательность
проверок (аппаратная аттестация, purpose, corp-ownership и т.д.); подробно
про роли и это автоодобрение — [Администрирование](administration.md#роли).
Сертификатный SSH не выпускается автоматически: `/enroll/ssh`, как и
`/enroll/user`, всегда оставляет заявку в `pending`. У отдельной
подсистемы SSH Key Registry — своя настройка автоодобрения, см.
[SSH Key Registry](ssh-keys.md). Каждое изменение состояния (одобрение, отзыв,
смена ролей) фиксируется в журнале аудита.

Вебхуки работают через исходящий outbox. События («заявка одобрена»,
«сертификат отозван» и т.п.) складываются в очередь доставки, откуда их
разбирает фоновый воркер: он подписывает тело запроса HMAC-секретом
получателя, отправляет его и при ошибке повторяет попытку с
экспоненциально растущей задержкой. Блокировка на уровне строк позволяет
запускать несколько воркеров параллельно, не дублируя доставку.

## PKI / CA — per-purpose registry

Alatyr не использует единый глобальный CA. Каждый тип сертификата или
ключа (`wifi`, `user_mtls`, `ad_logon`, `ssh`) настраивается на свой
независимый источник выпуска, полностью отдельно от остальных:

```mermaid
flowchart TD
    Reg["Выбор источника выпуска<br/>по типу сертификата/ключа"]
    Reg -->|wifi| B1{"backend?<br/>(если не настроен —<br/>fallback на ALATYR_ISSUER)"}
    Reg -->|user_mtls| B2{"backend?<br/>(источник должен быть<br/>явно настроен)"}
    Reg -->|ad_logon| B3["только SCEP<br/>(Vault PKI не умеет выпускать<br/>расширение, необходимое<br/>для KB5014754)"]
    Reg -->|ssh| B4["только Vault SSH<br/>secrets engine<br/>(без отзыва/ротации через CA —<br/>у этого механизма своя модель)"]

    B1 -->|vault| V1["Vault PKI engine<br/>(mount/role для wifi)"]
    B1 -->|scep| S1["Внешний SCEP CA<br/>(mount/role для wifi)"]
    B2 -->|vault| V2["Vault PKI engine<br/>(mount/role для user_mtls)"]
    B2 -->|scep| S2["Внешний SCEP CA<br/>(mount/role для user_mtls)"]
    B3 --> S3["Внешний SCEP CA<br/>(NDES / ADCS)"]
    B4 --> V4["Vault SSH secrets engine"]
```

Каждый purpose (цель выпуска) настраивается отдельной строкой `issuer_profiles` — можно
держать `wifi` на Vault, а `ad_logon` на корпоративном NDES/ADCS
одновременно. `wifi` — единственный purpose с fallback-поведением: если
для него нет строки в `issuer_profiles` (или она выключена), сервер
использует issuer, заданный переменной окружения `ALATYR_ISSUER`
(по умолчанию `vault`, но может быть и `scep` — см.
[Конфигурация](configuration.md#pki-issuer-vault--внешний-scep-ca)),
сконфигурированный при старте, — это гарантирует, что развёртывания без
per-purpose PKI работают без изменений. У `user_mtls`, `ad_logon` и `ssh`
такого fallback нет: без явно настроенного и включённого профиля выпуск
для этих purpose отклоняется.

`ad_logon` — единственный purpose с жёстко зафиксированным источником
выпуска: сервер всегда требует SCEP для этого purpose, независимо от
настроек, потому что Vault PKI не умеет выпускать расширение
сертификата, необходимое для strong certificate mapping (KB5014754) —
без него Windows-логин по смарт-карте не пройдёт строгую проверку
соответствия. SSH устроен похоже, но ещё строже: OpenSSH-сертификат —
не X.509 (подписывается сырой публичный ключ, а не запрос на
сертификат), и у выпуска SSH-сертификатов нет операции отзыва или
ротации CRL в принципе — у Vault SSH secrets engine такой концепции
попросту нет. Поэтому для purpose `ssh` источником выпуска может быть
только Vault SSH secrets engine — любая другая настройка для этого
purpose считается ошибкой конфигурации.

**Отзыв.** У `wifi`/`user_mtls`/`ad_logon` — стандартный путь CA
(CRL/OCSP). У `ssh` такого пути нет вообще: единственное средство
отзыва — Key Revocation List (KRL, `GET /api/v1/ssh/krl`), который
сервер формирует по списку отозванных ключей в стандартном бинарном
формате OpenSSH (`PROTOCOL.krl`) при каждом запросе; `sshd` регулярно
перечитывает файл через директиву `RevokedKeys`.
