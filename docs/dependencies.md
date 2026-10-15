---
description: "Какие зависимости набор развёртывания Alatyr поднимает сам, а какие берёт ваши: PostgreSQL, Vault с PKI, сертификат админки, вход через Keycloak. Переключатель COMPOSE_PROFILES, подготовка и проверка до подъёма."
---

# Своё или внешнее

У организации база, Vault и провайдер входа часто уже есть. Набор
развёртывания из выпуска (`alatyr-deploy-<версия>.tar.gz`) умеет и поднять
их сам, и взять ваши. Выбор делается в `.env` набора, файлы compose не
правятся. Начиная с выпуска 1.6.0.

## Одна строка выбирает состав

```bash
COMPOSE_PROFILES=bundled-postgres,bundled-vault   # всё своё — умолчание
```

Профиль в списке — набор поднимает свою службу. Убрали профиль — служба не
поднимается, а в `.env` заполняется подключение к вашей. Остальное
(миграции базы, настройка Vault, профили издателей, сертификат админки)
работает в обоих режимах: те же службы ходят либо в свою зависимость, либо в
вашу.

| Профиль | Что поднимает набор |
|---|---|
| `bundled-postgres` | своя база: служба `postgres`, том `postgres_data` |
| `bundled-vault` | свой Vault с PKI: службы `vault` и `pki-public`, том `vault_data` |

Сочетания:

```bash
COMPOSE_PROFILES=bundled-postgres,bundled-vault   # всё своё
COMPOSE_PROFILES=bundled-vault                    # база ваша, Vault свой
COMPOSE_PROFILES=bundled-postgres                 # Vault ваш, база своя
COMPOSE_PROFILES=                                 # база и Vault ваши
```

## Что подготовить

| Зависимость | Своя (по умолчанию) | Ваша: что вписать в `.env` | Что подготовить заранее |
|---|---|---|---|
| PostgreSQL | профиль `bundled-postgres` | `ALATYR_DB_HOST`, `ALATYR_DB_PORT`, `ALATYR_DB_NAME`, `ALATYR_DB_USER`, `ALATYR_DB_PASSWORD`, `ALATYR_DB_SSLMODE`, `ALATYR_DB_SSLROOTCERT` | PostgreSQL 13 или новее (проверено на 15); база и её владелец — [ниже](#ваш-postgresql); доступ по сети с машины набора; резервные копии — ваши |
| Vault и PKI | профиль `bundled-vault` | `ALATYR_OWN_VAULT_ADDR`, `ALATYR_VAULT_CA_FILE` и учётка: одноразовый `ALATYR_VAULT_ADMIN_TOKEN` **или** `ALATYR_VAULT_ROLE_ID` + `ALATYR_VAULT_SECRET_ID` | Vault 1.11 или новее (проверено на 1.17), распечатанный; `OWN-VAULT.md` в архиве набора; адрес списков отзыва открывается из сети агентов — [ниже](#адрес-pki-в-сертификатах) |
| Сертификат админки | `ALATYR_TLS=on`: выпускает служба `tls-cert` издателем `pki_web` — в своём Vault или в вашем | `ALATYR_TLS=files` (ваш сертификат в `./tls`) или `ALATYR_TLS=off` (TLS на вашем обратном прокси) | файлы `./tls/cert.pem` и `./tls/key.pem`; либо прокси и его адрес в `ALATYR_EXTRA_ORIGINS` — [Установка → Свой сертификат для админки](installation.md#свой-сертификат-для-админки) |
| Вход через IdP (Keycloak, OIDC) | по умолчанию вход только по паролю; встроенный Keycloak — накладка для ознакомления | накладка `docker-compose.keycloak.yml` и `ALATYR_KEYCLOAK_*` | реалм и клиент в вашем Keycloak — `KEYCLOAK.md` в архиве набора |
| Каталог AD, NDES | в наборе их нет | `ALATYR_DIRECTORY_*`, `ALATYR_SCEP_*`, корень ЦС домена в `./trust` | [Вход в домен по смарт-карте](ad-logon/setup.md) |

**Корни ваших УЦ** (TLS базы, TLS Vault, ЦС домена) кладутся в каталог
`./trust` рядом с `docker-compose.yml` с правами `644` — сервер в контейнере
работает не от вашего пользователя. В `.env` вписывается путь **внутри**
контейнера: `/etc/alatyr/trust/<файл>`.

**Docker Compose 2.20 или новее.** Зависимость от выключенной службы в
`docker-compose.yml` помечена `required: false`, и Compose старее отвергает
файл целиком — в том числе при «всё своё». `first-up.sh` проверяет версию
до подъёма; проверить самому — `docker compose version`.

## Выбор проверяется до подъёма

Служба `deps-check` сверяет строку `COMPOSE_PROFILES` с переменными
подключения и отказывает, назвав причину: ваша база без `ALATYR_DB_HOST`,
ваш Vault без `ALATYR_OWN_VAULT_ADDR`, свой и ваш Vault одновременно,
неизвестный профиль, половина учётки AppRole, нечитаемый корень УЦ,
недоступная база или вход в неё не тем TLS, ключ `./tls/key.pem` не от
сертификата. Остальные службы её ждут, и `docker compose up -d` отвечает
ошибкой с её именем:

```bash
docker compose logs deps-check
# [deps-check] PostgreSQL: внешний, db.corp.example:5432, база alatyr, пользователь alatyr, sslmode=verify-full
# [deps-check] Vault: внешний, https://vault.corp.example:8200; учётка сервера — AppRole из ...
# [deps-check] выбор согласован
```

`./first-up.sh` проверяет то же самое ещё до `docker compose` и пароль
вашей базы не придумывает: его задаёт администратор базы.

## Ваш PostgreSQL

Администратор базы заводит пользователя и базу, владельцем которой он будет.
Таблицы, индексы и расширение `pgcrypto` сервер создаёт сам при первом
старте (с PostgreSQL 13 расширение доверенное, и владельцу базы права
суперпользователя для этого не нужны):

```sql
CREATE ROLE alatyr LOGIN PASSWORD '<пароль>';
CREATE DATABASE alatyr OWNER alatyr;
-- PostgreSQL 12 и старее: CREATE EXTENSION pgcrypto; в базе alatyr от суперпользователя
```

В `.env`:

```bash
COMPOSE_PROFILES=bundled-vault
ALATYR_DB_HOST=db.corp.example
ALATYR_DB_PORT=5432
ALATYR_DB_NAME=alatyr
ALATYR_DB_USER=alatyr
ALATYR_DB_PASSWORD=<пароль>                          # любой, спецсимволы экранирует сервер
ALATYR_DB_SSLMODE=verify-full                        # умолчание для вашей базы
ALATYR_DB_SSLROOTCERT=/etc/alatyr/trust/db-ca.pem    # корень УЦ сертификата базы
```

**TLS до вашей базы — по умолчанию `verify-full`**: имя и сертификат базы
проверяются по корню из `ALATYR_DB_SSLROOTCERT`. Допустимы `verify-full`,
`verify-ca` и `require`; `allow` и `prefer` отвергаются — они молча
откатываются на открытый текст. Без TLS (`disable`) — только написанным в
`.env` явно, и `deps-check` предупреждает об этом при каждом подъёме.
Заданный, но нечитаемый `ALATYR_DB_SSLROOTCERT` — отказ запуска сервера с
именем переменной. Своя база (`bundled-postgres`) ходит без TLS внутри сети
compose, как прежде.

Резервные копии вашей базы набор не снимает: перед обновлением это ваша
обычная процедура (`pg_dump`).

## Ваш Vault

Встроенный Vault выключается тем, что из `COMPOSE_PROFILES` убирается
`bundled-vault`. Службы `vault` и `pki-public` тогда не поднимаются, а
`vault-init`, `tls-cert` и сервер ходят в ваш Vault. Накладка
`docker-compose.own-vault.yml` прежних выпусков больше не нужна (и
продолжает работать).

```bash
COMPOSE_PROFILES=bundled-postgres                     # база своя, Vault ваш
ALATYR_OWN_VAULT_ADDR=https://vault.corp.example:8200
ALATYR_VAULT_CA_FILE=/etc/alatyr/trust/vault-ca.pem   # если TLS Vault не от публичного УЦ
ALATYR_VAULT_ADMIN_TOKEN=<токен>                      # или две строки AppRole ниже
#ALATYR_VAULT_ROLE_ID=<role_id>
#ALATYR_VAULT_SECRET_ID=<secret_id>
```

Учётку выбирают одним из двух способов.

### Способ 1. Токен администратора, разово

`ALATYR_VAULT_ADMIN_TOKEN` — токен с правом заводить движки, политики и
AppRole. Служба `vault-init` выполняет против вашего Vault тот же сценарий,
что против встроенного: промежуточный УЦ на каждую цель (`pki_wifi`,
`pki_user_mtls`, `pki_vpn`, `pki_k8s`, `pki_web`) под корнем `pki`, роли,
движок SSH, политики `alatyr-server` и `alatyr-tls`, обе AppRole — и кладёт
учётки служб на тома. Переопределённые `ALATYR_VAULT_PKI_MOUNT` /
`ALATYR_VAULT_PKI_ROLE` с этим способом не работают — свои точку и роль
задают вторым способом.

**Существующее — только с явного согласия.** Перед первой записью
`vault-init` перечисляет движки, политики и AppRole вашего Vault. Если там
уже есть что-то из `pki`, `pki_*`, `ssh-client-signer`, политик или AppRole
`alatyr-server` и `alatyr-tls`, а заводил их не этот набор, подъём
останавливается с перечнем найденного, и в Vault не записывается ничего:

```
ОТКАЗ: в Vault https://vault.corp.example:8200 уже есть то, что набор завёл бы сам:
    движок pki/
    политика alatyr-server
```

Принять найденное как своё (например, это прежняя установка Alatyr) —
`ALATYR_VAULT_ADOPT=1` в `.env` и снова `docker compose up -d`. С флагом:

- корневой движок `pki`, заведённый не набором, **не меняется** — ни срок,
  ни адреса, ни издатели; промежуточные УЦ набора подписываются вашим
  корнем;
- роли и политики `alatyr-*` перезаписываются такими же, как во встроенном
  УЦ; суженные роли — только вторым способом;
- прежние `secret_id` ролей `alatyr-server` и `alatyr-tls` уничтожаются,
  когда набор выписывает свой. Без флага уничтожаются только те, что выписал
  сам набор, остальные `vault-init` лишь называет;
- решение «корень `pki` чужой» запоминается и действует на всех следующих
  подъёмах, с флагом и без.

**После первого подъёма токен убирают:**

1. удалите из `.env` строки `ALATYR_VAULT_ADMIN_TOKEN` и `ALATYR_VAULT_ADOPT`;
2. выполните `docker compose up -d` — `vault-init` пересоздастся и проверит
   учётки служб на томах уже без токена;
3. администратор Vault отзывает токен: `vault token revoke <токен>`.

`first-up.sh` напоминает об этом, пока строка с токеном остаётся в `.env`.

### Способ 2. Подготовка администратором Vault

Администратор Vault заводит промежуточные УЦ целей, роли, политику и AppRole
`alatyr-server` по разделу 1 `OWN-VAULT.md` из архива набора, а в `.env`
вписываются `ALATYR_VAULT_ROLE_ID` и `ALATYR_VAULT_SECRET_ID`. В Vault набор
тогда не пишет ничего: `vault-init` кладёт учётку на том сервера и проверяет
её входом и правами — подпись по роли цели `wifi` обязана быть разрешена,
подпись промежуточных УЦ запрещена, политики `root` быть не должно. Не
прошло — подъём останавливается с ответом Vault
(`docker compose logs vault-init`).

Сертификат админки из вашего Vault (`ALATYR_TLS=on`) при этом способе
требует второй AppRole — `alatyr-tls` с правом выпуска по `pki_web`
(`ALATYR_VAULT_TLS_ROLE_ID` / `ALATYR_VAULT_TLS_SECRET_ID`); без неё —
`ALATYR_TLS=files` или `off`.

Точка и роль цели `wifi` по умолчанию — `pki_wifi` и `alatyr`; если в вашем
Vault они названы иначе — `ALATYR_VAULT_PKI_MOUNT` и `ALATYR_VAULT_PKI_ROLE`.

### Проверить подключение

```bash
docker compose logs vault-init | grep 'alatyr-server'
#   alatyr-server: политики [alatyr-server default]; pki_wifi/sign/alatyr — разрешён, pki/root/sign-intermediate — запрещён
docker compose logs server | grep 'vault auth'
# "msg":"vault auth: AppRole"
```

Издатели целей в админке — [Установка → Шаг 4](installation.md#шаг-4-направьте-цели-в-их-издатели).

## Адрес PKI в сертификатах

Каждый выданный сертификат несёт внутри адреса **AIA** (`CA Issuers`, где
взять сертификат издателя) и **CRL** (точка распространения списка отзыва).
Клиент — macOS, Windows, приёмник — ходит по ним при проверке цепочки,
поэтому адрес обязан разрешаться и открываться **из сети клиентов**, а не
только с сервера.

**Никогда — внутреннее имя службы.** Имя контейнера или службы кластера
(`vault`, `<релиз>-vault`, `vault.<ns>.svc`), `localhost` или `127.0.0.1`
снаружи не разрешаются, и тогда:

- macOS ждёт таймаута разрешения имени — около **5 секунд на каждое новое
  mTLS-соединение** с клиентским сертификатом; снаружи это выглядит как
  «долго не спрашивает Touch ID или PIN»;
- Windows отказывает в проверке отзыва
  (`CERT_TRUST_REVOCATION_STATUS_UNKNOWN`).

**Где задаётся:**

| Установка | Откуда берётся адрес |
|---|---|
| Набор развёртывания, свой Vault (`bundled-vault`) | `ALATYR_PKI_PUBLIC_ADDR` в `.env` — адрес машины с портом `ALATYR_PKI_PORT` (`8200`), по нему списки отзыва и сертификаты УЦ отдаёт служба `pki-public`. `first-up.sh` вписывает его сам или спрашивает, если у машины несколько адресов |
| Набор развёртывания, ваш Vault, способ 1 (токен администратора) | `vault-init` пишет в `<mount>/config/urls` `ALATYR_PKI_PUBLIC_ADDR`, а если он пуст — `ALATYR_OWN_VAULT_ADDR`. Адреса корня `pki`, заведённого не набором, не трогаются |
| Ваш Vault, способ 2 и Helm-чарт | администратор Vault, `<mount>/config/urls` каждой точки PKI (переменная `PKI_ADDR` в разделе 1 `OWN-VAULT.md`). В Helm-чарте адрес Vault для клиентов — значение `pki.publicAddr` |

**Пустой адрес — адреса не пишутся вовсе.** Если `ALATYR_PKI_PUBLIC_ADDR`
пуст или задан внутренним именем, набор не подставляет имя службы, а
очищает `config/urls` и предупреждает в журнале `vault-init`. Сертификат без
AIA/CRL проверяется сразу, но отзыв по CRL клиентам тогда недоступен. Если
достижимого адреса для вашего Vault нет, сделайте так же:

```bash
vault write <mount>/config/urls issuing_certificates="" crl_distribution_points=""
```

**Смена адреса не чинит уже выданное.** Адрес зашит внутрь сертификата, поэтому
после смены `ALATYR_PKI_PUBLIC_ADDR` (и `docker compose up -d`, чтобы
`vault-init` переписал `config/urls`) или `config/urls` в вашем Vault уже
выданные сертификаты нужно **перевыпустить**: отозвать и одобрить новую
заявку в админке или дождаться продления агентом.

Проверить, куда смотрит сертификат:

```bash
openssl x509 -in <сертификат>.pem -noout -text | grep -A1 'Authority Information\|CRL Distribution'
#   CA Issuers - URI:http://alatyr.corp.example:8200/v1/pki_user_mtls/ca
#   URI:http://alatyr.corp.example:8200/v1/pki_user_mtls/crl
```

Внутреннее имя (`vault:8200`, `localhost`) в выводе — причина задержки на
macOS и отказа проверки отзыва на Windows.

## Вход через Keycloak

Вход в админку через ваш Keycloak включается накладкой
`docker-compose.keycloak.yml` и переменными `ALATYR_KEYCLOAK_*` в `.env`;
файлы набора не правятся. Встроенный Keycloak
(`docker-compose.keycloak-builtin.yml`) — только для ознакомления: он
требует встроенного Vault и HTTPS набора. Что завести в Keycloak и как
проверить вход — `KEYCLOAK.md` в архиве набора и
[Установка → Вариант 1](installation.md#вариант-1--docker-compose).

## Сменить выбор на работающей установке

Строка `COMPOSE_PROFILES` выбирает, какие службы поднимать, и **данных не
переносит**:

- переход со своей базы на вашу — `pg_dump` из службы `postgres` и
  восстановление в вашу базу **до** смены строки;
- переход со своего Vault на ваш означает новый корень PKI: выданные
  сертификаты остаются проверяемыми, только пока жив прежний корень, и
  устройствам нужен перевыпуск;
- тома своих служб (`postgres_data`, `vault_data`) после смены строки не
  удаляются — только явно, `docker volume rm`.

С вашими базой и Vault `docker compose down -v` удаляет только тома набора
(учётки служб, сертификат админки); данные в вашем PostgreSQL и вашем Vault
он не трогает.

## Обновление с выпуска до 1.6.0

С 1.6.0 службы `postgres`, `vault` и `pki-public` поднимаются только с
профилями из `COMPOSE_PROFILES`. В `.env` прежних выпусков этой строки нет, и
без неё стек не поднимется: `deps-check` откажет и назовёт её (данные в
томах при этом не затрагиваются). Поэтому **первым шагом обновления**, до
смены версии и `docker compose pull`, выполняется:

```bash
./migrate-env.sh
# migrate-env: дописано COMPOSE_PROFILES=bundled-postgres,bundled-vault
#   база и Vault — свои, как прежде.
```

Сценарий дописывает строку с тем составом служб, что поднимался у вас: база
— своя; Vault — свой, а если установка уже ходит в ваш
(`ALATYR_OWN_VAULT_ADDR` или накладка `docker-compose.own-vault.yml`) — без
`bundled-vault`. Что дописал, он печатает; повторный запуск ничего не
меняет; прежний `.env` остаётся рядом как `.env.before-migrate`.
`./first-up.sh` вызывает его сам. Порядок обновления целиком —
[Эксплуатация → Обновление](operations.md#обновление-сервера-на-новую-версию)
и `UPGRADE.md` в архиве нового выпуска.

## Kubernetes (Helm)

В Helm-чарте выбор тот же по смыслу: база — значение `postgres.mode`
(`external` — ваша, строка подключения в Secret; `embedded` — под в
релизе), Vault и провайдер входа — всегда ваши (`vault.addr`,
`keycloak.url`). Корни ваших УЦ (TLS базы, TLS Vault) кладутся в ConfigMap,
имя которого задаётся в `trust.existingConfigMap`: он монтируется в под
сервера только на чтение в `/etc/alatyr/trust` — тот же путь, что в наборе:

```yaml
trust:
  existingConfigMap: alatyr-trust
vault:
  caCertPath: /etc/alatyr/trust/vault-ca.pem
# database-url в Secret:
#   postgres://...?sslmode=verify-full&sslrootcert=/etc/alatyr/trust/db-ca.pem
```

`vault.caCertPath` внутри `/etc/alatyr/trust` без
`trust.existingConfigMap` — чарт роняет установку: файла в поде не будет.
Установка чарта — [Установка → Вариант 2](installation.md#вариант-2--kubernetes-helm).
