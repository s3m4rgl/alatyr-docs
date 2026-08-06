# Администрирование

Эта страница — про Admin UI и админский REST API: роли, кто что может
делать, и три конкретных сквозных потока, которые чаще всего вызывают
вопросы — approve/reject/revoke, блокировка устройства при отзыве и
сервисные аккаунты. Про сами переменные окружения и установку сервера —
[Конфигурация](configuration.md) и [Установка](installation.md).

## Роли

Ровно четыре роли, назначаются через `PUT /api/v1/users/{email}/roles`
(`cert-admin` only) или, для локальных пользователей, при создании через
`POST /api/v1/users/local`:

| Роль | Кому назначается | Доступ |
|---|---|---|
| `cert-admin` | Людям | Полный доступ: все read-эндпоинты + весь write (approve/reject/revoke, block/unblock, пользователи и роли, сети, сервисные аккаунты, вебхуки, лицензия, настройки). |
| `cert-approver` | Людям | Чтение заявок/устройств/аудита/сетей/статистики + `approve`. **Не может** `reject`, `revoke`, управлять пользователями/сетями/сервисными аккаунтами. |
| `cert-viewer` | Людям | Только чтение — те же read-эндпоинты, что у `cert-approver`, без `approve`. |
| `cert-auto-approver` | **Только сервисным аккаунтам** — людям эта роль не назначается | Наименьшие привилегии: `POST /requests/approve` + чтение `/requests` и `/requests/check-conflicts`. Не видит `/audit`, `/devices`, сети, статистику — только то, что нужно, чтобы обнаружить заявку и проверить конфликты перед одобрением. |

**Первый залогинившийся пользователь автоматически получает `cert-admin`**
(атомарная вставка в пустую `user_roles`, работает и для Keycloak, и для
локальной аутентификации).

!!! warning "Keycloak-only деплой без local-admin bootstrap"
    Если API открыт наружу раньше, чем оператор сам первый раз залогинился,
    «первый залогинившийся» — это буквально первый обладатель валидного
    токена сконфигурированного Keycloak-клиента, а не обязательно оператор.
    Закрывайте это до открытия API наружу: либо залогиньтесь первым сами,
    либо настройте local-admin bootstrap (`ALATYR_LOCAL_AUTH_ENABLED` +
    `ALATYR_LOCAL_ADMIN_EMAIL`/`ALATYR_LOCAL_ADMIN_PASSWORD`, см.
    [Конфигурация](configuration.md)), либо предзаполните нужную строку
    `user_roles` вручную.

## Обзор разделов Admin UI

| Раздел | Доступ на чтение | Доступ на запись |
|---|---|---|
| Dashboard / статистика | `cert-admin`/`cert-approver`/`cert-viewer` | — |
| Заявки (Requests) | + `cert-auto-approver` (только список и check-conflicts) | approve — `cert-admin`/`cert-approver`/`cert-auto-approver`; reject — `cert-admin` |
| Устройства (Devices), логи устройств | `cert-admin`/`cert-approver`/`cert-viewer` | request/cancel/delete логов, revoke enrollment-token, revoke/unblock устройства — `cert-admin` |
| Сертификаты | `cert-admin`/`cert-approver`/`cert-viewer` (bundle) | revoke сертификата — `cert-admin` |
| SSH Keys | `cert-admin`/`cert-approver`/`cert-viewer` | approve/reject/revoke — `cert-admin`; см. [SSH Key Registry](ssh-keys.md) |
| Аудит | `cert-admin`/`cert-approver`/`cert-viewer` | — (аудит только читается) |
| Пользователи и роли | `cert-admin` | `cert-admin` |
| Сети (Wi-Fi/802.1X) | `cert-admin`/`cert-approver`/`cert-viewer` | `cert-admin` |
| Сервисные аккаунты | `cert-admin` (недоступно самим сервисным аккаунтам) | `cert-admin` |
| Вебхуки | `cert-admin` | `cert-admin` |
| Настройки — Issuers / Issue Policy / Security Defaults / Licensing / Agent Update | любая admin-роль (read) | `cert-admin` |
| Настройки — Corp Verify (allowlist), SSH-ключи (keyholder tokens) | `cert-admin` (read тоже, не «любая admin-роль») | `cert-admin` |

!!! note "Настройки — не единый блок прав"
    Вкладка «Настройки» неоднородна по доступу на чтение. Issuers /
    Issue Policy / Security Defaults / Licensing / Agent Update
    (`GET /api/v1/settings/system`, `GET
    /api/v1/settings/sa-auto-approve`) читает любая admin-роль — пишет
    только `cert-admin`. А вот Corp Verify allowlist (`GET
    /api/v1/admin/corp-allowlist`) и список/CRUD keyholder-токенов на
    вкладке SSH-ключи (`GET/POST/DELETE
    /api/v1/admin/keyholder-tokens`) зарегистрированы в том же
    cert-admin-only route group, что и запись — там нет отдельного
    read-доступа для `cert-approver`/`cert-viewer`, в отличие от
    остальных вкладок настроек.

## Approve / reject / revoke заявок

Заявки на выпуск создаются только через неавторизованные
`/enroll*`-эндпоинты (по `enrollment_token` устройства) и всегда попадают в
`pending` — ни один purpose (`wifi`/`user_mtls`/`ad_logon`/`ssh`) не
выдаётся автоматически при регистрации, обязательно ручное или
сервис-аккаунтное решение.

- **`POST /api/v1/requests/approve`** (bulk) — `cert-admin`, `cert-approver`
  или сервисный аккаунт с ролью `cert-auto-approver`. Прежде чем одобрить,
  сервис-аккаунтные вызовы проходят независимую последовательность
  проверок: аппаратная аттестация, соответствие purpose, при включённой
  corp-ownership-проверке — allowlist/webhook (см. ниже), и блокировка
  устройства (см. следующий раздел). При интерактивном одобрении человеком
  эти проверки не выполняются — approve всегда разрешён (кроме терминальных
  статусов заявки).
- **`POST /api/v1/requests/reject`** (bulk) — только `cert-admin`.
- **`POST /api/v1/certificates/{serial}/revoke`** — только `cert-admin`.
  Для SCEP-выпущенных сертификатов недоступен (у SCEP нет операции отзыва
  — кнопка отключена в UI, API вернёт 400); отзывайте на стороне CA
  напрямую.

**Corp-ownership verification для сервис-аккаунтного auto-approve**
(`system_settings.sa_auto_approve_verifier`, `GET/PUT
/api/v1/settings/sa-auto-approve`) — дополнительный, независимый от
аппаратной аттестации сигнал: `off` (по умолчанию), `allowlist` (серийный
номер должен быть в `corp_device_allowlist`, CRUD — `cert-admin`,
`/api/v1/admin/corp-allowlist`), `webhook` (SSRF-safe запрос на
админ-настроенный URL), либо комбинаторы `allowlist_or_webhook` /
`allowlist_and_webhook`. Отсутствие настройки или ошибка проверки никогда
не трактуется как разрешение — оба verifier'а fail-closed.

## Блокировка устройства при отзыве (device-block-on-revoke)

Полный отзыв устройства — `POST /api/v1/devices/{serial}/revoke` (`cert-admin`)
— отзывает все активные сертификаты устройства и, **только если абсолютно
все они отозвались успешно**, дополнительно ставит на устройство постоянную
блокировку: `blocked_at`/`blocked_by`/`blocked_reason`, аудит-запись
`device.block`. Частичный сбой отзыва (HTTP 207) блокировку не ставит —
тот же гейт, что уже защищает освобождение license-слота.

- **`POST /api/v1/devices/{serial}/unblock`** (`cert-admin`, идемпотентен) —
  единственный способ снять блокировку: явное, обратимое человеческое
  действие. Повторный вызов на уже разблокированном устройстве — success,
  без ошибки. Unblock не трогает `pending`-заявки.
- Пока устройство заблокировано, все три enroll-эндпоинта (`/enroll`,
  `/enroll/user`, `/enroll/ssh`) по-прежнему создают обычную `pending`
  заявку — **никогда не 403** — но помечают её `enrolled_while_blocked =
  true`. Этот флаг постоянный: последующий unblock устройства его не
  очищает, это точечная историческая запись про конкретную заявку.
- Проверка блокировки устройства при сервис-аккаунтном одобрении безусловно
  отклоняет заявку, если `enrolled_while_blocked = true` ИЛИ устройство
  заблокировано **сейчас** — проверяются оба сигнала независимо, чтобы
  заявка, оставшаяся `pending` на
  момент блокировки устройства (а значит не помеченная флагом задним
  числом), тоже не проскочила автоматическое одобрение. Человек может
  одобрить такую заявку интерактивно в любой момент — это не снимает
  блокировку устройства, для этого нужен отдельный явный unblock.

!!! danger "Известное ограничение"
    Блокировка привязана к строке `devices`, которая резолвится по
    заявленному агентом `serial_number` — устройство, физически
    контролирующее собственный агент (ровно модель угрозы этой фичи),
    может обойти блок, заявив другой серийный номер (новая
    незаблокированная строка) или, для placeholder-серийников, просто не
    предъявив `continuity_key` при повторном enroll. Это не новая брешь —
    то же самое уже верно для отзыва сертификата на уровне устройства.
    Также блокировка не останавливает уже выданные SSH-ключи из SSH Key
    Registry — см. предупреждение на странице [SSH Key
    Registry](ssh-keys.md).

## Сервисные аккаунты

Машинные идентичности для API-based approve (CI/автоматизация) вместо
интерактивного логина. Управление — **только `cert-admin`, недоступно
самим сервисным аккаунтам** (guard против privilege escalation — SA не
может создать или изменить другой SA):

| Метод и путь | Назначение |
|---|---|
| `GET /api/v1/service-accounts` | Список |
| `POST /api/v1/service-accounts` | Создать; токен `wca_*` показывается один раз в ответе |
| `PUT /api/v1/service-accounts/{id}/enabled` | Включить/выключить |
| `DELETE /api/v1/service-accounts/{id}` | Удалить |

- В БД хранится только SHA-256-хэш токена; сырое значение — только при
  создании.
- Токен с префиксом `wca_` распознаётся до проверки JWT; fail-closed (401
  на неизвестный/выключенный токен или ошибку БД).
- **Срок действия** — `expires_in_days` при создании (0–3650; 0/пусто —
  бессрочный). Истёкший токен отклоняется (401), fail-closed.
- **Аудит** — `audit_log.actor_kind` различает `user` (веб-сессия) и
  `service_account` (API-токен); UI показывает тег «API» на действиях
  сервисного аккаунта.
- Единственное мутирующее действие, которое достижимо SA-токеном —
  `POST /requests/approve`; `reject`/`revoke`/управление пользователями и
  сетями остаются `cert-admin`-only независимо от токена.

## Пользователи и роли

`PUT /api/v1/users/{email}/roles` и `PUT /api/v1/users/{email}/enabled`
(`cert-admin`) управляют ролями и активностью учётной записи. Локальные
(не-SSO) пользователи создаются и управляются отдельными эндпоинтами
(`POST /api/v1/users/local`, `PUT /api/v1/users/{email}/password`) — детали
локальной аутентификации и bootstrap первого администратора см. в разделе
про локальную аутентификацию на странице [Конфигурация](configuration.md).

## Сети (Wi-Fi + проводной 802.1X)

`cert-admin` создаёт/отключает/восстанавливает/удаляет записи в едином
списке сетей (`kind` = `wifi` или `wired`, не более одной активной
`wired`-сети). Там же, для каждой сети отдельно, три переключателя
«распространять профиль через агента» — по одному на macOS/Windows/Linux —
для флотов, где эти профили раскатываются через MDM/GPO/config management,
а не самим агентом. Механика этих переключателей и их fleet-wide аналог для
macOS — на странице [Агенты](agents.md#agent-profile-disabled).
