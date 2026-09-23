#!/bin/sh
# Инициализация встроенного УЦ для самостоятельной поставки.
#
# Запускается на КАЖДЫЙ `docker compose up` и обязан быть идемпотентным:
# первый запуск инициализирует Vault, последующие только распечатывают его,
# если он оказался запечатан после перезапуска.
#
# Шаги: ждём Vault → инициализируем → распечатываем → поднимаем PKI (корень +
# промежуточный на каждую цель) → движок SSH → AppRole для сервера.
#
# Отличие от scripts/vault-dev-setup.sh — не в структуре, она та же, а в
# РОЛЯХ. Там они намеренно широкие (`allow_any_name=true`), и README прямо
# запрещает копировать их в прод: роль — второй рубеж после csridentity.Verify,
# и с `allow_any_name` второго рубежа нет вовсе. Здесь роли сужены по
# таблице из README, раздел «Продовая роль Vault PKI».
set -eu

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_ADDR
KEYS_DIR="${KEYS_DIR:-/vault/keys}"
CREDS_DIR="${CREDS_DIR:-/run/alatyr}"
INIT_JSON="$KEYS_DIR/init.json"
ROOT_TTL="${ROOT_CA_TTL:-87600h}"
INT_TTL="${INTERMEDIATE_CA_TTL:-43800h}"
WIFI_TTL="${VAULT_CERT_TTL_HOURS:-26280}h"

say() { echo "[bootstrap] $*"; }

# Домены организации — то единственное, что роль вообще проверяет. Без них
# сузить её нечем, поэтому запуск прекращается с внятным сообщением, а не
# заводит роль «на любое имя» молча.
if [ -z "${ALATYR_PKI_ALLOWED_DOMAINS:-}" ]; then
    say "не задан ALATYR_PKI_ALLOWED_DOMAINS (домены организации, через запятую)."
    say "Роль Vault — второй рубеж проверки имени после сервера; без списка"
    say "доменов сузить её нечем, а роль «на любое имя» в проде недопустима"
    say "(README, раздел «Продовая роль Vault PKI»)."
    say "Пример: ALATYR_PKI_ALLOWED_DOMAINS=corp.example,example.com"
    exit 1
fi

# ── 1. ждём Vault ───────────────────────────────────────────────────────────
# `vault status` возвращает 0 распечатанным, 2 запечатанным и ненулевое
# прочее, когда до сервера не достучались. Ждём именно достижимости.
i=0
while :; do
    rc=0
    vault status >/dev/null 2>&1 || rc=$?
    # 0 — распечатан, 2 — запечатан: и то и другое значит «сервер отвечает».
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
        break
    fi
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        say "Vault не отвечает 60 секунд — прекращаю"
        exit 1
    fi
    sleep 1
done

field() { vault status -format=json 2>/dev/null | sed -n "s/.*\"$1\": *\([a-z]*\).*/\1/p" | head -1; }

# ── 2. инициализация ────────────────────────────────────────────────────────
if [ "$(field initialized)" != "true" ]; then
    say "Vault не инициализирован — инициализирую"
    mkdir -p "$KEYS_DIR"
    vault operator init -key-shares=1 -key-threshold=1 -format=json > "$INIT_JSON"
    chmod 600 "$INIT_JSON"
    cat <<'WARN'
[bootstrap] ================== ПРОЧИТАЙТЕ ОДИН РАЗ ==================
[bootstrap] Vault инициализирован. Ключ распечатывания и корневой токен
[bootstrap] лежат в томе alatyr_vault_keys (файл init.json, режим 600).
[bootstrap]
[bootstrap] Это осознанный компромисс пилота: стек поднимается без участия
[bootstrap] человека, но ключ от сейфа лежит рядом с сейфом. Кто получил
[bootstrap] доступ к тому — получил корневой УЦ целиком.
[bootstrap]
[bootstrap] Что сделать СЕЙЧАС, а не потом:
[bootstrap]   1. docker compose cp vault-bootstrap:/vault/keys/init.json ./
[bootstrap]      и убрать копию в хранилище секретов организации;
[bootstrap]   2. решить, оставлять ли файл в томе. Без него стек не поднимется
[bootstrap]      сам после перезапуска — Vault останется запечатанным, и
[bootstrap]      распечатывать его придётся руками:
[bootstrap]        docker compose exec vault vault operator unseal <ключ>
[bootstrap]   3. в продакшене заменить это на auto-unseal через KMS/HSM
[bootstrap]      (seal "awskms"/"transit"/…), тогда файла не будет вовсе.
[bootstrap] ==========================================================
WARN
else
    say "Vault уже инициализирован"
fi

# ── 3. распечатывание ───────────────────────────────────────────────────────
if [ "$(field sealed)" = "true" ]; then
    if [ ! -f "$INIT_JSON" ]; then
        say "Vault запечатан, а ключа нет — распечатайте вручную:"
        say "  docker compose exec vault vault operator unseal <ключ>"
        exit 1
    fi
    say "Vault запечатан — распечатываю"
    # `vault operator init -format=json` печатает JSON в НЕСКОЛЬКО строк, и
    # построчный разбор не находит в нём ничего (поймано первым же прогоном).
    # Схлопываем пробелы и переводы строк, потом разбираем.
    UNSEAL_KEY=$(tr -d ' \n' < "$INIT_JSON" | sed -n 's/.*"unseal_keys_b64":\["\([^"]*\)".*/\1/p')
    [ -n "$UNSEAL_KEY" ] || { say "не разобрал ключ распечатывания из init.json"; exit 1; }
    vault operator unseal "$UNSEAL_KEY" >/dev/null
fi

VAULT_TOKEN=$(tr -d ' \n' < "$INIT_JSON" | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')
[ -n "$VAULT_TOKEN" ] || { say "не разобрал корневой токен из init.json"; exit 1; }
export VAULT_TOKEN

# ── 4. PKI ──────────────────────────────────────────────────────────────────
# Структура повторяет scripts/vault-dev-setup.sh: корень НИЧЕГО не выписывает,
# у каждой цели свой промежуточный. Это не стилистика: цели wifi и user_mtls
# несут одинаковый CN, и приёмник различает их ТОЛЬКО по издателю. Пока обе
# выписывались одним корнем, машинный сертификат, подписываемый молча, был
# годной заменой пользовательскому, который выдаётся под PIN или биометрию
# (замеры — docs/MTLS-RELYING-PARTY.md).
enable_mount() { # enable_mount <path> <max-ttl>
    vault secrets list -format=json | grep -q "\"$1/\"" || vault secrets enable -path="$1" pki >/dev/null
    vault secrets tune -max-lease-ttl="$2" "$1" >/dev/null
}

enable_mount pki "$ROOT_TTL"
if vault read pki/cert/ca >/dev/null 2>&1; then
    say "корневой УЦ уже выпущен — ключ не трогаю"
else
    say "выпускаю корневой УЦ"
    vault write -field=certificate pki/root/generate/internal \
        common_name="${ROOT_CA_CN:-Alatyr Root CA}" ttl="$ROOT_TTL" >/dev/null
fi
vault write pki/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki/crl" >/dev/null

# Промежуточный уже настроенного mount НЕ перевыпускаем: перевыпуск заводит
# НОВЫЙ ключ, и выданные раньше сертификаты проверяются только там, где
# сохранили старую цепочку — установка тихо расслаивается.
intermediate() { # intermediate <mount> <CN>
    enable_mount "$1" "$INT_TTL"
    if vault read "$1/cert/ca" >/dev/null 2>&1; then
        say "промежуточный $1 уже настроен — ключ не трогаю"
    else
        say "выпускаю промежуточный $1"
        csr=$(vault write -field=csr "$1/intermediate/generate/internal" \
                common_name="$2" key_bits=2048)
        signed=$(printf '%s' "$csr" | vault write -field=certificate pki/root/sign-intermediate \
                csr=- format=pem_bundle ttl="$INT_TTL")
        printf '%s' "$signed" | vault write "$1/intermediate/set-signed" certificate=- >/dev/null
    fi
    vault write "$1/config/urls" \
        issuing_certificates="$VAULT_ADDR/v1/$1/ca" \
        crl_distribution_points="$VAULT_ADDR/v1/$1/crl" >/dev/null
}

intermediate pki_wifi      "${WIFI_CA_CN:-Alatyr WiFi Issuing CA}"
intermediate pki_user_mtls "${USER_MTLS_CA_CN:-Alatyr User mTLS Issuing CA}"
intermediate pki_k8s       "${K8S_CA_CN:-Alatyr Kubernetes Issuing CA}"
intermediate pki_vpn       "${VPN_CA_CN:-Alatyr VPN Issuing CA}"

# Роли СУЖЕНЫ (README, «Продовая роль Vault PKI»): allow_any_name=false,
# enforce_hostnames=true, домены организации обязательны.
say "роль pki_wifi/alatyr"
vault write pki_wifi/roles/alatyr \
    allowed_domains="$ALATYR_PKI_ALLOWED_DOMAINS" \
    allow_subdomains="${ALATYR_PKI_ALLOW_SUBDOMAINS:-true}" \
    allow_any_name=false \
    enforce_hostnames=true \
    allowed_uri_sans="urn:device-serial:*" \
    allowed_serial_numbers="*" \
    key_type=any \
    max_ttl="$WIFI_TTL" \
    client_flag=true \
    server_flag=false >/dev/null

# user_mtls: личность ЧЕЛОВЕКА, а не машины. Нет device-serial URI SAN (сервер
# такой CSR и не примет), срок — год.
say "роль pki_user_mtls/user-mtls"
vault write pki_user_mtls/roles/user-mtls \
    allowed_domains="$ALATYR_PKI_ALLOWED_DOMAINS" \
    allow_subdomains="${ALATYR_PKI_ALLOW_SUBDOMAINS:-true}" \
    allow_any_name=false \
    enforce_hostnames=true \
    key_type=any \
    max_ttl=8760h \
    client_flag=true \
    server_flag=false \
    email_protection_flag=false \
    require_cn=true \
    use_csr_common_name=true \
    use_csr_sans=true \
    key_usage="DigitalSignature,KeyEncipherment" >/dev/null

# k8s: 12 часов — не тюнинг, а вся модель безопасности цели. API-сервер
# Kubernetes НЕ проверяет отзыв клиентских сертификатов вовсе, поэтому доступ
# забирает только срок.
say "роль pki_k8s/k8s"
vault write pki_k8s/roles/k8s \
    allowed_domains="$ALATYR_PKI_ALLOWED_DOMAINS" \
    allow_subdomains="${ALATYR_PKI_ALLOW_SUBDOMAINS:-true}" \
    allow_any_name=false \
    enforce_hostnames=true \
    key_type=any \
    max_ttl=12h \
    client_flag=true \
    server_flag=false \
    require_cn=true \
    use_csr_common_name=true \
    use_csr_sans=true \
    key_usage="DigitalSignature,KeyEncipherment" >/dev/null

# ad_logon роли здесь НЕТ и быть не может: доменный вход по карте требует
# расширения SID (KB5014754), которого Vault PKI не выпускает в принципе. Эта
# цель работает только через SCEP/ADCS.

# ── Движок SSH ──────────────────────────────────────────────────────────────
# Отдельный движок, а не роль в pki: SSH подписывает ПУБЛИЧНЫЙ КЛЮЧ, а не
# заявку, и формат сертификата у него свой.
vault secrets list -format=json | grep -q '"ssh-client-signer/"' || \
    vault secrets enable -path=ssh-client-signer ssh >/dev/null
vault read ssh-client-signer/config/ca >/dev/null 2>&1 || \
    vault write ssh-client-signer/config/ca generate_signing_key=true >/dev/null
# allowed_users="*" здесь безопасно ровно потому, что настоящий контроль —
# список разрешённых принципалов в профиле издателя, а не роль: роль не знает,
# кому мы решили выдавать.
# Роль пишется JSON-ом со stdin, а не парами ключ=значение: у
# `default_extensions` тип «карта», и в форме `key=value` CLI отвергает её —
# «expected a map, got 'string'» (поймано прогоном).
vault write ssh-client-signer/roles/ssh-user - >/dev/null <<'JSON'
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "*",
  "key_type": "ca",
  "default_user": "alatyr",
  "ttl": "24h",
  "default_extensions": {"permit-pty": ""}
}
JSON
say "движок ssh-client-signer настроен"

# vpn: свой издатель обязателен, а не общий с user_mtls.
# Сервер доступа VPN отличает клиентов ровно якорем доверия: пока обе цели
# выписывал бы один УЦ, сертификат для внутреннего сайта открывал бы и вход в
# сеть. Срок — год: OpenVPN проверяет CRL, поэтому отзыв здесь работает и
# короткий срок не обязан быть единственным способом забрать доступ.
say "роль pki_vpn/vpn"
vault write pki_vpn/roles/vpn \
    allowed_domains="$ALATYR_PKI_ALLOWED_DOMAINS" \
    allow_subdomains="${ALATYR_PKI_ALLOW_SUBDOMAINS:-true}" \
    allow_any_name=false \
    enforce_hostnames=true \
    key_type=any \
    max_ttl=8760h \
    client_flag=true \
    server_flag=false \
    email_protection_flag=false \
    require_cn=true \
    use_csr_common_name=true \
    use_csr_sans=true \
    key_usage="DigitalSignature,KeyEncipherment" >/dev/null

# ── 5. AppRole для сервера ─────────────────────────────────────────────────
# Сервер ходит в Vault НЕ корневым токеном: у корневого нет срока и нет
# ограничений, и он же лежит в init.json. Политика перечисляет пути поимённо —
# шаблон `pki*` дал бы серверу и право подписывать промежуточные.
vault policy write alatyr-server - <<'POLICY' >/dev/null
path "pki_wifi/sign/alatyr"          { capabilities = ["create", "update"] }
path "pki_user_mtls/sign/user-mtls"  { capabilities = ["create", "update"] }
path "pki_k8s/sign/k8s"              { capabilities = ["create", "update"] }
path "pki_vpn/sign/vpn"              { capabilities = ["create", "update"] }

path "pki_wifi/revoke"               { capabilities = ["create", "update"] }
path "pki_user_mtls/revoke"          { capabilities = ["create", "update"] }
path "pki_k8s/revoke"                { capabilities = ["create", "update"] }
path "pki_vpn/revoke"                { capabilities = ["create", "update"] }

path "pki_wifi/crl/rotate"           { capabilities = ["read"] }
path "pki_user_mtls/crl/rotate"      { capabilities = ["read"] }
path "pki_k8s/crl/rotate"            { capabilities = ["read"] }
path "pki_vpn/crl/rotate"            { capabilities = ["read"] }

path "pki/ca/pem"                    { capabilities = ["read"] }
path "pki_wifi/ca/pem"               { capabilities = ["read"] }
path "pki_user_mtls/ca/pem"          { capabilities = ["read"] }
path "pki_k8s/ca/pem"                { capabilities = ["read"] }
path "pki_vpn/ca/pem"                { capabilities = ["read"] }

path "ssh-client-signer/sign/ssh-user" { capabilities = ["create", "update"] }
path "ssh-client-signer/config/ca"     { capabilities = ["read"] }
POLICY

vault auth list -format=json | grep -q '"approle/"' || vault auth enable approle >/dev/null
vault write auth/approle/role/alatyr-server \
    token_policies=alatyr-server \
    token_ttl=1h token_max_ttl=24h \
    secret_id_num_uses=0 secret_id_ttl=0 >/dev/null

# Служебный контейнер работает от root, сервер — от непривилегированного
# пользователя образа (uid 100 / gid 101 в alpine-сборке, замерено). Файл с
# режимом 600 от root сервер прочитать не может, и первый прогон показал это
# буквально: «open /run/alatyr/vault_secret_id: permission denied» в цикле.
#
# Поэтому владелец назначается явно. Значения вынесены в переменные: если
# базовый образ сменится и uid уедет, чинится настройкой, а не правкой
# скрипта.
CREDS_UID="${ALATYR_CREDS_UID:-100}"
CREDS_GID="${ALATYR_CREDS_GID:-101}"

mkdir -p "$CREDS_DIR"
vault read -field=role_id auth/approle/role/alatyr-server/role-id \
    | tr -d '\n' > "$CREDS_DIR/vault_role_id"

# secret_id выписывается заново на каждый запуск: он показывается однократно и
# нигде больше не хранится. Прежние остаются действительными — отозвать их
# можно через auth/approle/role/alatyr-server/secret-id-accessor/destroy.
vault write -f -field=secret_id auth/approle/role/alatyr-server/secret-id \
    | tr -d '\n' > "$CREDS_DIR/vault_secret_id"

if chown "$CREDS_UID:$CREDS_GID" "$CREDS_DIR/vault_role_id" "$CREDS_DIR/vault_secret_id" 2>/dev/null; then
    chmod 400 "$CREDS_DIR/vault_secret_id"
    chmod 444 "$CREDS_DIR/vault_role_id"
else
    # Не молча: сервер иначе не стартует вовсе, и причина будет выглядеть
    # как «сломался Vault», а не «не тот владелец файла».
    say "ВНИМАНИЕ: не удалось сменить владельца на $CREDS_UID:$CREDS_GID."
    say "Ставлю режим 644, чтобы сервер смог прочитать. Если uid образа"
    say "отличается, задайте ALATYR_CREDS_UID/ALATYR_CREDS_GID."
    chmod 644 "$CREDS_DIR/vault_secret_id" "$CREDS_DIR/vault_role_id"
fi

say "готово: role_id и secret_id в $CREDS_DIR, сервер читает их через VAULT_*_FILE"
