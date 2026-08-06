# Установка

Alatyr состоит из двух независимо устанавливаемых частей:

- **Сервер** — Go API + PostgreSQL + PKI-бэкенд (Vault и/или внешний SCEP CA)
  + React Admin UI. Разворачивается один раз на инфраструктуре организации.
- **Агент** — бинарь под macOS/Windows/Linux, ставится на каждое устройство
  сотрудника отдельно и сам обращается к серверу за сертификатом.

Эта страница покрывает установку обеих частей. Полный список переменных
окружения сервера — на странице [Конфигурация](configuration.md). Прежде чем
разворачивать сервер в продакшене, прочитайте
[Отказоустойчивость (HA)](ha.md) и [Resource Sizing](sizing.md) — ни один из
манифестов ниже не разворачивает БД или Vault в отказоустойчивой конфигурации
из коробки.

## Сервер

Есть два независимых пути установки сервера: Docker Compose (самостоятельный
хостинг, три готовых файла под разные сценарии) и Helm-чарт alatyr-demo для
Kubernetes. Оба варианта описаны ниже.

### Вариант 1 — Docker Compose

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | «Production-shaped» стек: PostgreSQL + сервер + UI. Ожидает уже настроенный внешний Vault (и, опционально, Keycloak) — сам их не поднимает. |
| `docker-compose.demo.yml` | Turnkey-демо: одна команда, ничего настраивать не нужно. Поднимает PostgreSQL, Vault (dev-режим), сервер, UI и наполняет БД тестовыми данными. |
| `docker-compose.dev.yml` | Только dev-инфраструктура (PostgreSQL + Vault dev + Keycloak) — сервер и фронтенд предполагается гонять локально, либо в Docker через `--profile app`. |

#### `docker-compose.yml` — самостоятельный хостинг

Поднимает `postgres`, `alatyr-server` (порт `8090`) и `alatyr-ui` (порт
`3000`, проксирует на внутренний `8080`). Требует до запуска:

- `DB_PASSWORD` — пароль PostgreSQL (host-only переменная, подставляется в
  `ALATYR_DB_URL`, самим сервером напрямую не читается);
- доступ к Vault: либо `VAULT_ADDR` + `VAULT_ROLE_ID`/`VAULT_SECRET_ID`
  (AppRole, рекомендуется для продакшена), либо `VAULT_ADDR` + `VAULT_TOKEN`
  (статический токен, приоритет ниже AppRole);
- если используете Keycloak SSO — `KEYCLOAK_URL`, `KEYCLOAK_REALM`,
  `KEYCLOAK_CLIENT_ID`, `KEYCLOAK_CLIENT_SECRET`. Альтернатива без
  Keycloak — встроенная локальная email+password аутентификация
  (`ALATYR_LOCAL_AUTH_ENABLED` и связанные переменные, см.
  [Конфигурация](configuration.md)).

```bash
export DB_PASSWORD="<сильный пароль>"
export VAULT_ADDR="https://vault.internal.example.com:8200"
export VAULT_ROLE_ID="..." VAULT_SECRET_ID="..."
export KEYCLOAK_URL="https://keycloak.internal.example.com" \
       KEYCLOAK_REALM="alatyr" KEYCLOAK_CLIENT_ID="alatyr-portal" \
       KEYCLOAK_CLIENT_SECRET="..."
docker compose -f docker-compose.yml up --build -d
```

!!! warning "Базовые образы для сборки"

    Dockerfile сервера и Dockerfile фронтенда (используются этим файлом по
    умолчанию) параметризованы через build-args (`GOLANG_BASE`,
    `ALPINE_BASE` и т.п.) под внутренний registry-mirror конкретного
    окружения сборки. Если у вас нет аналогичного mirror'а, соберите с
    override на публичные образы (`--build-arg GOLANG_BASE=golang:1.25.8-alpine
    --build-arg ALPINE_BASE=alpine:3.21.6` для сервера) — либо, для
    быстрого локального теста без правки build-args, ориентируйтесь на
    `Dockerfile.demo`/`docker-compose.demo.yml` ниже: он использует ровно те
    же публичные `docker.io`-образы и специально существует для сборки без
    внутренней инфраструктуры.

#### `docker-compose.demo.yml` — turnkey-демо (быстрее всего попробовать)

Одна команда — и ничего настраивать не нужно. Собирается на публичных
`docker.io`-образах (`Dockerfile.demo`), поднимает Vault в dev-режиме и
конфигурирует его PKI-движок автоматически (`vault-init`), включает
локальную аутентификацию и вебхуки, засеивает тестовые данные:

```bash
docker compose -f docker-compose.demo.yml up --build
```

Затем откройте `http://localhost:13000` и войдите как `admin@wifi.local` /
`Admin1234!`. API — `http://localhost:18090`.

!!! danger "Только для демо/локального теста"

    Секреты (`ALATYR_LOCAL_JWT_SECRET`, `ALATYR_WEBHOOK_ENC_KEY`,
    Vault dev-root-token, пароль администратора) захардкожены в самом файле
    ради воспроизводимости с нуля. Никогда не переиспользуйте их в
    продакшен-развёртывании.

#### `docker-compose.dev.yml` — только dev-инфраструктура

Поднимает PostgreSQL (host-порт `5433`), Vault dev-режим (`8200`) и Keycloak
(`8080`) — без самого сервера/UI, которые предполагается запускать локально
для разработки. Чтобы поднять сервер и UI тоже в Docker:
`docker compose -f docker-compose.dev.yml --profile app up`.

### Вариант 2 — Helm chart (Kubernetes)

Доступен Helm-чарт `alatyr-demo`.

!!! warning "Это демонстрационный/референсный чарт, не подготовленный к продакшену"

    Как и `docker-compose.demo.yml`, этот чарт по умолчанию гоняет Vault в
    dev-режиме (`hashicorp/vault:1.17`, `vault server -dev` — in-memory,
    без persistent storage backend, без auto/manual unseal), одну реплику
    PostgreSQL без backup-джобы и без реплики, и держит демо-секреты прямо
    в `values.yaml` открытым текстом. Он также по умолчанию включает
    `demoReseed` — CronJob, который **каждые 4 часа полностью truncate'ит
    все таблицы приложения и засеивает их заново тестовыми данными**
    (`reseed/truncate.sql` + `reseed/seed-dev-data.sql`, по расписанию
    `demoReseed.schedule`). Используйте этот чарт как отправную точку/шаблон
    для собственного production-чарта, а не как есть — как минимум,
    переопределите все значения под `secrets:` и поставьте
    `demoReseed.enabled: false`, иначе периодическая джоба уничтожит любые
    реальные данные. См. также [Отказоустойчивость](ha.md) и
    [Resource Sizing](sizing.md) — там подробно, что именно в текущей
    топологии не готово к продакшен-нагрузке нескольких реплик.

Что разворачивает чарт:

| Компонент | Файл | Примечание |
|---|---|---|
| PostgreSQL | `postgres-deployment.yaml`, `postgres-service.yaml`, `pvc.yaml` | Один под, PVC по умолчанию `5Gi` (`values.yaml: postgres.storage.size`) |
| Vault | `vault-deployment.yaml`, `vault-service.yaml`, `vault-init-job.yaml` | Dev-режим; `vault-init-job` идемпотентно конфигурирует PKI engine + роль `alatyr` (post-install/post-upgrade Helm hook) |
| Сервер | `server-deployment.yaml`, `server-service.yaml` | 1 реплика, читает секреты из `Secret` (см. ниже), `readinessProbe`/`livenessProbe` на `/api/v1/version` |
| Frontend | `frontend-deployment.yaml`, `frontend-service.yaml`, `frontend-nginx-configmap.yaml` | nginx + статика Vite |
| Ingress | `ingress.yaml` | опционально (`ingress.enabled`), маршрутизирует `/api` и `/swagger` на сервер, остальное — на frontend; ожидает `cert-manager` (`ingress.clusterIssuer`) |
| Секреты | `secrets.yaml` | `Secret` из `values.yaml: secrets.*` (`postgres-password`, `local-jwt-secret`, `webhook-enc-key`, `vault-token`, `local-admin-email`, `local-admin-password`) — **обязательно переопределить** для не-демо использования |
| Демо-reseed | `reseed-configmap.yaml`, `reseed-cronjob.yaml`, `reseed-rbac.yaml` | `CronJob`, включён по умолчанию (`demoReseed.enabled: true`) — см. предупреждение выше |

Ключевые значения `values.yaml`: `namespace`, `image.server`/`image.frontend`
(образы `<ваш-registry>/alatyr-server`/`<ваш-registry>/alatyr-frontend` —
соберите и запушьте их в свой registry перед деплоем)
+ `image.tag`, `postgres.*`, `vault.pkiMount`/`vault.pkiRole`/`vault.certTTLHours`,
`server.env.logLevel`/`server.env.corsOrigins`, `ingress.*`, `demoReseed.*`,
`secrets.*`.

```bash
helm install alatyr ./alatyr-demo \
  --namespace alatyr --create-namespace \
  --set demoReseed.enabled=false \
  --set server.env.corsOrigins="https://alatyr.your-domain.example" \
  --set ingress.host="alatyr.your-domain.example" \
  --set secrets.postgresPassword="<сильный пароль>" \
  --set secrets.localJWTSecret="$(openssl rand -hex 32)" \
  --set secrets.webhookEncKey="$(openssl rand -hex 32)" \
  --set secrets.vaultToken="<production Vault token/AppRole>" \
  --set secrets.localAdminEmail="admin@your-domain.example" \
  --set secrets.localAdminPassword="<сильный пароль>"
```

## Агент

Агент — кросс-платформенный CLI-бинарь (Go), который выполняется на
устройстве сотрудника: генерирует ключевой материал в доступном
аппаратном хранилище (TPM 2.0 на Windows/Linux, Secure Enclave на macOS,
либо программный fallback-ключ на Linux при отсутствии TPM), отправляет
CSR на сервер (`/enroll`), ждёт одобрения администратором в Admin UI и
устанавливает выданный сертификат + Wi-Fi/802.1X-профиль локально.
Собственной привязки к учётной записи сервера агент не требует — он
аутентифицируется `enrollment_token` устройства, полученным при первом
enroll.

### Linux

Статически слинкованный бинарь (кроме опционального модуля `tpm2-pkcs11`),
поддерживает `amd64`/`arm64`. Два способа установки:

**deb/rpm** (тянут TPM/PKCS#11-зависимости автоматически через
`recommends`):

```bash
sudo apt install ./alatyr-agent_<version>_amd64.deb   # Debian/Ubuntu
sudo dnf install ./alatyr-agent-<version>-1.x86_64.rpm # Fedora/RHEL
```

deb/rpm не принимают install-time флаги — параметры задаются после установки
через `/etc/alatyr-agent/config.env` (0600, `KEY=VALUE`), до первого тика
таймера (запускается сразу после установки, далее каждые 10 минут):

```bash
sudo tee /etc/alatyr-agent/config.env >/dev/null <<'EOF'
WIFI_CERT_SERVER="https://alatyr.your-domain.example"
CORP_DOMAIN="your-domain.example"
CORP_EMAIL="user@your-domain.example"
EOF
sudo chmod 0600 /etc/alatyr-agent/config.env
sudo systemctl restart alatyr-agent.timer
```

**tgz** (`install.sh` сам определяет и ставит TPM/pkcs11-пакеты через
apt/dnf/yum, `--skip-tpm-deps` — пропустить):

```bash
tar xzf alatyr-agent-linux-<version>.tar.gz -C alatyr-agent
cd alatyr-agent
sha256sum -c SHA256SUMS.txt
sudo ./install.sh \
    --server "https://alatyr.your-domain.example" \
    --corp-domain "your-domain.example" \
    --corp-email "user@your-domain.example"
```

`install.sh` ставит бинарь в `/usr/local/bin/alatyr-agent`, регистрирует
systemd `alatyr-agent.timer` (загрузка + каждые 10 мин) и
`alatyr-agent-secretd.service` (постоянный D-Bus secret-agent, отдаёт PIN
для TPM PKCS#11-ключа NetworkManager'у при подключении).

Дополнительно `install.sh` устанавливает и включает per-user systemd
`--user`-юнит `alatyr-agent-user.service` (для корпоративного пользователя,
через `loginctl enable-linger` + `systemctl --user enable --now`). Это
постоянный процесс, работающий от имени интерактивного пользователя (не
`root`/`SYSTEM`), который провижинит `user_mtls` и поднимает аппаратный
ssh-agent — подробнее в [«Агенты»](agents.md).

Параметры `alatyr-agent run` (CLI-флаг > env var > `config.env`):

| Флаг | Env var | По умолчанию | Описание |
|---|---|---|---|
| `--server`/`-s` | `WIFI_CERT_SERVER` | — | URL сервера Alatyr (обязателен) |
| `--corp-email`/`-u` | `CORP_EMAIL` | — | Email/UPN пользователя, на который выпускается сертификат (обязателен) |
| `--state-file` | `WIFI_CERT_STATE_FILE` | `/var/lib/alatyr-agent/state.json` | Путь к state.json |
| `--config` | `WIFI_CERT_CONFIG` | `/etc/alatyr-agent/config.env` | Путь к config-файлу |
| `--ca-cert` | `WIFI_CERT_CA_CERT` | системный CA pool | Custom CA bundle для TLS-проверки сервера |
| `--poll-interval` | — | `30s` | Частота опроса статуса approval |

TPM 2.0 — soft dependency: без пакета `tpm2-pkcs11`/`libtpm2-pkcs11-1` агент
использует программный fallback-ключ в `/var/lib/alatyr-agent/wifi-cert.<serial>.pem`
(0600). При production-раскатке с реальным TPM обязательны все 5 пакетов
(`tpm2-tools`, `libtpm2-pkcs11-1`, `libtpm2-pkcs11-tools`, `p11-kit`,
`libengine-pkcs11-openssl` — Debian/Ubuntu, аналоги для Fedora/RHEL) —
без последнего (`libengine-pkcs11-openssl`) enroll и выпуск сертификата
пройдут нормально, но реальное Wi-Fi-подключение завершится ошибкой на этапе EAP-TLS.

Диагностика:

```bash
systemctl status alatyr-agent.timer alatyr-agent.service alatyr-agent-secretd.service
journalctl -u alatyr-agent.service -f
sudo /usr/local/bin/alatyr-agent status --state-file /var/lib/alatyr-agent/state.json
```

Деинсталляция: `sudo ./uninstall.sh` (оставляет state/сертификаты для
аудита) или `sudo ./uninstall.sh --purge` (полная очистка).

### macOS

Агент на macOS работает **per-user** как `LaunchAgent`, не per-machine
`LaunchDaemon` — ключ подписи создаётся в Secure Enclave и держится `secd`
залогиненного пользователя, которого под root-демоном не существует. Каждый
пользователь на одной машине проходит enroll отдельно и получает свой
сертификат.

В отличие от Linux/Windows, готового бинарного пакета «как есть» не
поставляется — организация обязана собрать и подписать `.pkg`
самостоятельно под свой Apple Developer аккаунт, потому что идентичность
привязывается к CryptoTokenKit Secure Enclave token extension внутри `.app`,
который должен быть подписан вашим собственным Developer ID и
нотаризован Apple. Кратко процесс:

1. Разово создать в Apple Developer аккаунте организации сертификаты
   **Developer ID Application** (подпись `.app`) и **Developer ID
   Installer** (подпись `.pkg`), сгенерировать app-specific password для
   `notarytool` (нотаризация — обязательная проверка Apple перед
   распространением вне App Store).
2. Собрать релиз: скрипт `sign-agent-release.sh` с `WIFI_CERT_SERVER`
   (URL сервера) и `CORP_DOMAIN` (домен для email-fallback) — компилирует
   `.app`, подписывает, нотаризует, упаковывает в `.pkg`
   (`dist/alatyr-agent-<version>.pkg`). `SKIP_NOTARIZE=1` — для
   локального теста на собственной машине без отправки на серверы Apple.
3. Раскатить `.pkg` через MDM (например, FleetDM — Software → Add Software
   → выбрать устройства → Install) либо установить вручную.

Ручная установка с параметрами конкретного устройства — через
`install-pkg.sh` (preseed-файл, читаемый postinstall-скриптом):

```bash
sudo bash install-pkg.sh \
    --pkg dist/alatyr-agent-<version>.pkg \
    --server https://alatyr.your-domain.example \
    --corp-domain your-domain.example \
    --corp-email user@your-domain.example
```

!!! warning "Email нельзя передать через переменные окружения installer'а"

    macOS `installer` не пробрасывает env vars в postinstall-скрипт —
    `sudo CORP_EMAIL=x installer -pkg ...` **не работает** и молча
    откатится на auto-detect (`<shortname>@<CORP_DOMAIN>` или
    LDAP/AD-атрибут, если мак привязан к домену). Задавайте email только
    через `install-pkg.sh --corp-email` или ручной preseed-файл.

!!! note "Headless-машины без активной GUI-сессии не получат сертификат"

    `.pkg` ставится нормально и без активного логина, но сертификат **не
    выпустится**, пока кто-то не залогинится в графическую сессию —
    SE-ключ живёт в per-user data-protection keychain, который держит
    `secd`, а `secd` есть только в GUI-сессии. Это осознанное ограничение
    архитектуры, не баг.

### Windows

Ключ подписи создаётся в TPM 2.0 (per-machine, не per-user, в отличие от
macOS). Готового MSI-инсталлятора нет — пакет для распространения
собирается скриптом `build-windows-pkg.sh` и представляет собой
**подписанный Authenticode zip-архив** с PowerShell-скриптами установки
(не MSI/WiX):

```
alatyr-agent-windows-<version>.zip
├── alatyr-agent-windows-amd64.exe / -arm64.exe
├── install.ps1 / launcher.ps1 / uninstall.ps1
├── alatyr-agent-codesign-cert.crt   (публичный сертификат для Trusted Publishers)
└── SHA256SUMS.txt
```

Сборка требует собственного code-signing сертификата организации
(`osslsigncode` + RFC 3161 timestamp-сервер) — без него `install.ps1`
всё равно отработает, но Windows может блокировать неподписанный `.exe`
политиками AppLocker/WDAC. Ручная установка на целевой машине (от имени
Administrator):

```powershell
Expand-Archive .\alatyr-agent-windows-<version>.zip -DestinationPath .\wca -Force
Import-Certificate -FilePath .\wca\alatyr-agent-codesign-cert.crt `
    -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
.\wca\install.ps1 -Server "https://alatyr.your-domain.example" `
    -CorpDomain "your-domain.example" -CorpEmail "user@your-domain.example"
```

`install.ps1`:

1. Копирует бинарь в `C:\Program Files\AlatyrAgent\alatyr-agent.exe` с
   restrictive NTFS ACL (запись — только `SYSTEM`/`Administrators`, обычным
   пользователям — только чтение/исполнение; без этого подмена бинаря
   пользователем без прав дала бы RCE от `SYSTEM` на следующем тике задачи).
2. Пишет конфиг в `C:\ProgramData\AlatyrAgent\config.env` (ACL: только
   `SYSTEM` + `Administrators`).
3. Регистрирует Scheduled Task `AlatyrAgent` — запуск от `SYSTEM` с
   `HighestAvailable` (обязательно для доступа к TPM), триггеры: при
   загрузке + каждые 10 минут, лимит выполнения 10 минут на итерацию.
   Задача запускается сразу после установки.
4. Дополнительно регистрирует второй Scheduled Task, `AlatyrAgentUser` —
   logon-triggered, запускается от имени интерактивного пользователя (не
   `SYSTEM`), по одному экземпляру на каждого вошедшего пользователя.
   Выполняет DPAPI token handoff от SYSTEM-процесса и провижининг
   per-user CNG-ключа (`user_mtls`) — подробнее в [«Агенты»](agents.md).

Раскат через FleetDM (или аналогичный MDM с поддержкой скриптов) —
загрузить zip как software package и настроить install-команду,
разворачивающую архив и запускающую `install.ps1` с нужными параметрами;
подробности и пример команды — в `README.md` внутри пакета.

Логи и статус: `C:\ProgramData\AlatyrAgent\agent.log`,
`C:\ProgramData\AlatyrAgent\state.json`, история задачи — Task Scheduler →
Library → `AlatyrAgent`. Деинсталляция — `.\uninstall.ps1` (останавливает
и удаляет Scheduled Task и `C:\Program Files\AlatyrAgent\`; логи/state в
`ProgramData` остаются для аудита).
