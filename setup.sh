#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE_FILE="${ROOT_DIR}/.env.example"
INIT_DATA_TEMPLATE_FILE="${ROOT_DIR}/casdoor/init_data.json.exmaple"
INIT_DATA_FILE="${ROOT_DIR}/casdoor/init_data.json"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

DEFAULT_JWKS_KEY='{"keys":[{"d":"PVoFyqyrGstB8wU52S7gqqQQdZLtin_thcEM0nrNtqp9U-NlKLlhgEcWp5t89ycgvhsAzmrRbezGj4JBTr3jn7eWdwQpPJNYiipnsgeJn0pwsB0H2dMqtavxinoPVXkMTOuGHMTFhhyguFBw2JbIL0PTQUcUlXjv40OoJpYHZeggSxgfV-TuxjwW8Ll4-n84M5IOi6A53RvioE-Hm1iyIc2XLBCfyOu-SbAQYi8HzrA64kCxobAB0peLQMiAzfZmwPKiGOhnhKrAlYmG02qFnbUYiJu_-AXwsAyGv9S9i6dwK7QXaGGWYyis8LlPpd_JmPrBnrWomwDlI045NUMWZQ","dp":"OSXI2NBBZl2r0Dpf4-1z44A_jC5lOyXtJhXQYnSXy5eIuxTJcEtkUYagGEwnREO4Q3t-4J-lT_6Y71M1ZlgKG1upwfw1O4aE3vGpHOik9iZYYCjA8fe5uBfOpX1ELmOtHNoHRhMtyjuPxSFXLlSp3bgcF1f3F40ClukdvXCx0Mc","dq":"m6hNdfj-F8E_7nUlX2nG95OffkFrhHTo67ML9aPgpvFwBlzg-hk5LwtxMfUzngqWF78TMl0JDm7vS1bz0xlWqXqu8pFPoTUnUoWgYfvuyHLBwR5TgccQkfoKbkSMzYNy8VJPXZeyIjVXsW98tZvj-NZF-M9Pke_EWJm-jjXCu_8","e":"AQAB","kty":"RSA","n":"piffosMS0HOSgsSr_zQkXYaQt1kOCD73VR0b2XJD6UdQCKPbnBOzTIuA_xowX61QVsl5pCZLTw8ERC3r2Nlxj5Rp_H6RuOT7ioUqlbnxSGnfuAn8dFupY3A-sf9HVDOvtJdlS-nO9yA4wWU-A50zZ1Mf0pPZlUZE6dUQfsJFi5yXaNAybyk3U4VpMO_SXAilWEHVhiO0F0ccpJMCkT47AeXmYH9MlWwIGcay0UiAsdrs8J-q1arZ7Mbq0oxHmUXJG0vwRvAL8KnCEi8cJ3e2kKCRcr-BQCujsHUyUl6f_ATwSVuTHdAR1IzIcW37v27h3WQK_v0ffQM1NstamDX5vQ","p":"4myVm2M5cZGvVXsOmWUTUG87VC1GlQcL5tmMNSGSpQCL8yWZ1vANkmCxSMptrKB4dU9DAB3On6_oMhW1pJ3uYNGSW49BcmJoLkiWKeg5zWFnKPQNuThQmY1sCCubtKhBQgaYUr7TVzN9smrDV3zCu9MlRl-XPwnEmWaDII3g-f8","q":"u9v4IOEsb4l2Y3eWKE2bwJh5fJRR4vivaYA7U-1-OpvDwB3A48Rey9IL1ucXqE5G1Du8BtijPm5oSAar5uzrjtg1bZ9gevif6DnBGaIRE7LnSrUsTPfZwzntJ1rTaGiVe_pAdnTKXXaH6DxygXxH4wvGgA44V3TTfBXQUcjzdEM","qi":"lDBnSPKkRnYqQvbqVD1LxzqBPEeqEA3GyCqMj6fIZNgoEaBSLi0TSsUyGZ5mahX3KO35vKAZa5jvGjhvUGUiXycq8KvRZdeGK45vJdwZT2TiXiDwo9IQgJcbFMpxaB9DhjX2x0yqxgUY5ca75jLqbMuKBKBN0PVqIr9jlHkR8_s","use":"sig","kid":"6823046760c5d460","alg":"RS256"}]}'

ENV_CREATED=0
PYTHON_BIN=""
HOST=""
MODE=""
PROTOCOL=""
APP_DOMAIN=""
CASDOOR_DOMAIN=""
RUSTFS_DOMAIN=""
VALIDATE_COMPOSE="ask"
REGENERATE_SECRETS="ask"

CASDOOR_CLIENT_ID_DEFAULT=""
CASDOOR_CLIENT_SECRET_DEFAULT=""
CASDOOR_WEBHOOK_SECRET_DEFAULT="casdoor-secret"

LOBE_PORT="3210"
RUSTFS_PORT="9000"
RUSTFS_ADMIN_PORT="9001"
CASDOOR_PORT="8000"
GRAFANA_PORT="3000"

APP_URL=""
S3_ENDPOINT_URL=""
CASDOOR_ISSUER_URL=""
CASDOOR_ORIGIN_URL=""
RUSTFS_CONSOLE_URL=""
GRAFANA_URL=""

usage() {
  cat <<'EOF'
Usage: bash ./setup.sh [options]

Options:
  --host <host>                 Port mode で使うホスト名または IP
  --mode <local|port|domain>   デプロイモードを指定
  --protocol <http|https>      Domain mode のプロトコルを指定
  --app-domain <domain>        Domain mode の LobeHub ドメインを指定
  --casdoor-domain <domain>    Domain mode の Casdoor ドメインを指定
  --rustfs-domain <domain>     Domain mode の RustFS API ドメインを指定
  --yes                        既定値で確認を進める
  --no-validate                docker compose config の確認をスキップ
  --regenerate-secrets         シークレットを再生成する
  --no-regenerate-secrets      シークレットを再生成しない
  -h, --help                   このヘルプを表示
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --protocol)
      PROTOCOL="${2:-}"
      shift 2
      ;;
    --app-domain)
      APP_DOMAIN="${2:-}"
      shift 2
      ;;
    --casdoor-domain)
      CASDOOR_DOMAIN="${2:-}"
      shift 2
      ;;
    --rustfs-domain)
      RUSTFS_DOMAIN="${2:-}"
      shift 2
      ;;
    --yes)
      VALIDATE_COMPOSE="yes"
      REGENERATE_SECRETS="yes"
      shift
      ;;
    --no-validate)
      VALIDATE_COMPOSE="no"
      shift
      ;;
    --regenerate-secrets)
      REGENERATE_SECRETS="yes"
      shift
      ;;
    --no-regenerate-secrets)
      REGENERATE_SECRETS="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

info() {
  printf '[INFO] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Required file not found: $path" >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Command not found: $command_name" >&2
    exit 1
  fi
}

detect_python() {
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then
    PYTHON_BIN="python"
  else
    echo "python3 or python is required" >&2
    exit 1
  fi
}

backup_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cp "$path" "${path}.bk"
  fi
}

ask_input() {
  local prompt="$1"
  local default_value="${2:-}"
  local result=""

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " result
    result="${result:-$default_value}"
  else
    read -r -p "$prompt: " result
  fi

  ASK_RESULT="$(printf '%s' "$result" | awk '{$1=$1;print}')"
}

ask_yes_no() {
  local prompt="$1"
  local default_value="${2:-y}"

  while true; do
    ask_input "$prompt (y/n)" "$default_value"
    case "${ASK_RESULT,,}" in
      y|yes)
        ASK_RESULT="y"
        return 0
        ;;
      n|no)
        ASK_RESULT="n"
        return 0
        ;;
      *)
        echo "y か n を入力してください"
        ;;
    esac
  done
}

read_env_value() {
  local key="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 0
  fi

  printf '%s' "${line#*=}"
}

set_env_value() {
  local key="$1"
  local value="$2"

  "$PYTHON_BIN" - "$ENV_FILE" "$key" "$value" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = path.read_text(encoding='utf-8').splitlines()
prefix = f"{key}="
for index, line in enumerate(lines):
    if line.startswith(prefix):
        lines[index] = prefix + value
        break
else:
    if lines and lines[-1] != "":
        lines.append("")
    lines.append(prefix + value)
path.write_text("\n".join(lines) + "\n", encoding='utf-8')
PY
}

load_init_data_defaults() {
  mapfile -t INIT_DEFAULTS < <("$PYTHON_BIN" - "$INIT_DATA_TEMPLATE_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as file:
    data = json.load(file)

app = next((item for item in data.get('applications', []) if item.get('name') == 'lobechat'), {})
webhook = next((item for item in data.get('webhooks', []) if item.get('name') == 'webhook_default'), {})
header_value = 'casdoor-secret'
for header in webhook.get('headers', []):
    if header.get('name') == 'casdoor-secret':
        header_value = header.get('value', 'casdoor-secret')
        break

print(app.get('clientId', ''))
print(app.get('clientSecret', ''))
print(header_value)
PY
)

  CASDOOR_CLIENT_ID_DEFAULT="${INIT_DEFAULTS[0]:-}"
  CASDOOR_CLIENT_SECRET_DEFAULT="${INIT_DEFAULTS[1]:-}"
  CASDOOR_WEBHOOK_SECRET_DEFAULT="${INIT_DEFAULTS[2]:-casdoor-secret}"
}

reset_init_data_file_from_template() {
  if [[ -f "$INIT_DATA_FILE" ]]; then
    backup_file "$INIT_DATA_FILE"
  fi

  cp "$INIT_DATA_TEMPLATE_FILE" "$INIT_DATA_FILE"
  info "casdoor/init_data.json をテンプレートから生成しました"
}

ensure_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    backup_file "$ENV_FILE"
    return 0
  fi

  cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
  backup_file "$ENV_FILE"
  ENV_CREATED=1
  info ".env を .env.example から作成しました"
}

is_placeholder_value() {
  local value="${1:-}"

  case "$value" in
    ""|replace_with_*|change_this_*|YOUR_*|sk-your-openai-api-key|*replace_me*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

csv_has_value() {
  local csv="${1:-}"
  local needle="$2"
  local normalized

  normalized=",${csv// /},"
  [[ "$normalized" == *",${needle},"* ]]
}

generate_base64_secret() {
  openssl rand -base64 32 | tr -d '\n'
}

generate_hex_secret() {
  local byte_length="$1"
  openssl rand -hex "$byte_length"
}

ensure_static_env_defaults() {
  local auth_casdoor_id
  local auth_casdoor_secret
  local casdoor_webhook_secret
  local jwks_key

  auth_casdoor_id="$(read_env_value 'AUTH_CASDOOR_ID' "$ENV_FILE")"
  auth_casdoor_secret="$(read_env_value 'AUTH_CASDOOR_SECRET' "$ENV_FILE")"
  casdoor_webhook_secret="$(read_env_value 'CASDOOR_WEBHOOK_SECRET' "$ENV_FILE")"
  jwks_key="$(read_env_value 'JWKS_KEY' "$ENV_FILE")"

  if is_placeholder_value "$auth_casdoor_id"; then
    set_env_value 'AUTH_CASDOOR_ID' "$CASDOOR_CLIENT_ID_DEFAULT"
  fi

  if is_placeholder_value "$auth_casdoor_secret"; then
    set_env_value 'AUTH_CASDOOR_SECRET' "$CASDOOR_CLIENT_SECRET_DEFAULT"
  fi

  if is_placeholder_value "$casdoor_webhook_secret"; then
    set_env_value 'CASDOOR_WEBHOOK_SECRET' "$CASDOOR_WEBHOOK_SECRET_DEFAULT"
  fi

  if is_placeholder_value "$jwks_key"; then
    set_env_value 'JWKS_KEY' "$DEFAULT_JWKS_KEY"
  fi
}

ensure_search_env_defaults() {
  local compose_profiles
  local search_providers
  local searxng_url
  local searxng_secret
  local searxng_base_url
  local searxng_force_ownership

  compose_profiles="$(read_env_value 'COMPOSE_PROFILES' "$ENV_FILE")"
  search_providers="$(read_env_value 'SEARCH_PROVIDERS' "$ENV_FILE")"
  searxng_url="$(read_env_value 'SEARXNG_URL' "$ENV_FILE")"
  searxng_secret="$(read_env_value 'SEARXNG_SECRET' "$ENV_FILE")"
  searxng_base_url="$(read_env_value 'SEARXNG_BASE_URL' "$ENV_FILE")"
  searxng_force_ownership="$(read_env_value 'SEARXNG_FORCE_OWNERSHIP' "$ENV_FILE")"

  if [[ -z "$compose_profiles" ]]; then
    set_env_value 'COMPOSE_PROFILES' 'with-searxng'
  fi

  if [[ -z "$search_providers" ]]; then
    set_env_value 'SEARCH_PROVIDERS' 'searxng'
  fi

  if [[ -z "$searxng_url" ]]; then
    set_env_value 'SEARXNG_URL' 'http://searxng:8080'
  fi

  if [[ -z "$searxng_secret" ]]; then
    set_env_value 'SEARXNG_SECRET' 'change_this_searxng_secret'
  fi

  if [[ -z "$searxng_base_url" ]]; then
    set_env_value 'SEARXNG_BASE_URL' 'http://searxng:8080/'
  fi

  if [[ -z "$searxng_force_ownership" ]]; then
    set_env_value 'SEARXNG_FORCE_OWNERSHIP' 'true'
  fi
}

ensure_browserless_env_defaults() {
  # COMPOSE_PROFILES への with-browserless 追加は既存プロファイルを壊さないよう、未設定時だけ補完する。
  # 既に何らかの profile を設定している場合は setup.sh 側で上書きしない（ユーザー運用方針を尊重）。
  local compose_profiles
  compose_profiles="$(read_env_value 'COMPOSE_PROFILES' "$ENV_FILE")"

  if [[ -z "$compose_profiles" ]] || is_placeholder_value "$compose_profiles"; then
    set_env_value 'COMPOSE_PROFILES' 'with-searxng,with-browserless'
  else
    if ! csv_has_value "$compose_profiles" 'with-browserless'; then
      warn "COMPOSE_PROFILES=${compose_profiles} のまま with-browserless を追加せず進めます。内蔵 Browserless を使う場合は手動で追記してください。"
    fi
  fi

  set_default_if_empty() {
    local key="$1"
    local value="$2"
    local current
    current="$(read_env_value "$key" "$ENV_FILE")"
    if [[ -z "$current" ]] || is_placeholder_value "$current"; then
      set_env_value "$key" "$value"
    fi
  }

  set_default_if_empty 'CRAWLER_IMPLS' 'naive,browserless'
  set_default_if_empty 'BROWSERLESS_URL' 'http://browserless:3000'
  set_default_if_empty 'BROWSERLESS_TOKEN' "$(generate_hex_secret 16)"
  set_default_if_empty 'BROWSERLESS_BLOCK_ADS' '1'
  set_default_if_empty 'BROWSERLESS_STEALTH_MODE' '0'
}

should_regenerate_secrets() {
  local current_value=""
  for key in KEY_VAULTS_SECRET AUTH_SECRET POSTGRES_PASSWORD RUSTFS_SECRET_KEY GF_SECURITY_ADMIN_PASSWORD SEARXNG_SECRET; do
    current_value="$(read_env_value "$key" "$ENV_FILE")"
    if is_placeholder_value "$current_value"; then
      return 0
    fi
  done

  if [[ "$ENV_CREATED" == "1" ]]; then
    return 0
  fi

  return 1
}

maybe_regenerate_secrets() {
  local regenerate="n"

  case "$REGENERATE_SECRETS" in
    yes)
      regenerate="y"
      ;;
    no)
      regenerate="n"
      ;;
    *)
      if should_regenerate_secrets; then
        ask_yes_no "ランタイム用のシークレットを再生成しますか" "y"
      else
        ask_yes_no "ランタイム用のシークレットを再生成しますか" "n"
      fi
      regenerate="$ASK_RESULT"
      ;;
  esac

  if [[ "$regenerate" != "y" ]]; then
    info "既存のシークレット値を保持します"
    return 0
  fi

  require_command openssl

  set_env_value 'KEY_VAULTS_SECRET' "$(generate_base64_secret)"
  set_env_value 'AUTH_SECRET' "$(generate_base64_secret)"
  set_env_value 'POSTGRES_PASSWORD' "$(generate_hex_secret 12)"
  set_env_value 'RUSTFS_SECRET_KEY' "$(generate_hex_secret 8)"
  set_env_value 'GF_SECURITY_ADMIN_PASSWORD' "$(generate_hex_secret 10)"
  set_env_value 'SEARXNG_SECRET' "$(generate_hex_secret 16)"

  info "ランタイム用シークレットを更新しました"
}

load_ports_from_env() {
  LOBE_PORT="$(read_env_value 'LOBE_PORT' "$ENV_FILE")"
  RUSTFS_PORT="$(read_env_value 'RUSTFS_PORT' "$ENV_FILE")"
  RUSTFS_ADMIN_PORT="$(read_env_value 'RUSTFS_ADMIN_PORT' "$ENV_FILE")"
  CASDOOR_PORT="$(read_env_value 'CASDOOR_PORT' "$ENV_FILE")"
  GRAFANA_PORT="$(read_env_value 'GRAFANA_PORT' "$ENV_FILE")"

  LOBE_PORT="${LOBE_PORT:-3210}"
  RUSTFS_PORT="${RUSTFS_PORT:-9000}"
  RUSTFS_ADMIN_PORT="${RUSTFS_ADMIN_PORT:-9001}"
  CASDOOR_PORT="${CASDOOR_PORT:-8000}"
  GRAFANA_PORT="${GRAFANA_PORT:-3000}"
}

auto_detect_host() {
  if command -v hostname >/dev/null 2>&1; then
    local detected
    detected="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "$detected" ]]; then
      printf '%s' "$detected"
      return 0
    fi
  fi

  printf 'localhost'
}

is_private_ip() {
  local candidate="$1"
  [[ "$candidate" == 10.* || "$candidate" == 192.168.* || "$candidate" == 172.1[6-9].* || "$candidate" == 172.2[0-9].* || "$candidate" == 172.3[0-1].* ]]
}

normalize_mode() {
  case "${1,,}" in
    0|domain)
      printf 'domain'
      ;;
    1|port)
      printf 'port'
      ;;
    2|local|localhost)
      printf 'local'
      ;;
    *)
      printf ''
      ;;
  esac
}

collect_mode_and_urls() {
  local detected_host=""
  local host_prompt_default=""
  local normalized_mode=""

  normalized_mode="$(normalize_mode "$MODE")"
  if [[ -z "$normalized_mode" ]]; then
    echo "デプロイモードを選択してください"
    echo "  0) domain  外部のリバースプロキシやトンネル前提でドメインを使う"
    echo "  1) port    ホスト名または IP とポートで公開する"
    echo "  2) local   localhost だけで利用する"
    ask_input 'モード' 'local'
    normalized_mode="$(normalize_mode "$ASK_RESULT")"
  fi

  if [[ -z "$normalized_mode" ]]; then
    echo "Invalid mode: ${MODE:-$ASK_RESULT}" >&2
    exit 1
  fi

  MODE="$normalized_mode"

  case "$MODE" in
    local)
      PROTOCOL="http"
      HOST="localhost"
      APP_URL="http://localhost:${LOBE_PORT}"
      S3_ENDPOINT_URL="http://localhost:${RUSTFS_PORT}"
      CASDOOR_ISSUER_URL="http://localhost:${CASDOOR_PORT}"
      CASDOOR_ORIGIN_URL="$CASDOOR_ISSUER_URL"
      RUSTFS_CONSOLE_URL="http://localhost:${RUSTFS_ADMIN_PORT}"
      GRAFANA_URL="http://localhost:${GRAFANA_PORT}"
      ;;
    port)
      PROTOCOL="http"
      detected_host="$(auto_detect_host)"
      if [[ -z "$HOST" ]]; then
        host_prompt_default="$detected_host"
        ask_input 'LobeHub を公開するホスト名または IP' "$host_prompt_default"
        HOST="$ASK_RESULT"
      fi
      if is_private_ip "$HOST"; then
        warn "プライベート IP が選ばれました  外部公開する場合はグローバル IP か DNS 名を指定してください"
      fi
      APP_URL="http://${HOST}:${LOBE_PORT}"
      S3_ENDPOINT_URL="http://${HOST}:${RUSTFS_PORT}"
      CASDOOR_ISSUER_URL="http://${HOST}:${CASDOOR_PORT}"
      CASDOOR_ORIGIN_URL="$CASDOOR_ISSUER_URL"
      RUSTFS_CONSOLE_URL="http://${HOST}:${RUSTFS_ADMIN_PORT}"
      GRAFANA_URL="http://${HOST}:${GRAFANA_PORT}"
      ;;
    domain)
      if [[ -z "$PROTOCOL" ]]; then
        ask_input 'プロトコル' 'https'
        PROTOCOL="$ASK_RESULT"
      fi

      case "${PROTOCOL,,}" in
        http|https)
          PROTOCOL="${PROTOCOL,,}"
          ;;
        *)
          echo "Invalid protocol: $PROTOCOL" >&2
          exit 1
          ;;
      esac

      if [[ -z "$APP_DOMAIN" ]]; then
        ask_input 'LobeHub のドメイン' 'chat.example.com'
        APP_DOMAIN="$ASK_RESULT"
      fi
      if [[ -z "$CASDOOR_DOMAIN" ]]; then
        ask_input 'Casdoor のドメイン' 'auth.example.com'
        CASDOOR_DOMAIN="$ASK_RESULT"
      fi
      if [[ -z "$RUSTFS_DOMAIN" ]]; then
        ask_input 'RustFS API のドメイン' 's3.example.com'
        RUSTFS_DOMAIN="$ASK_RESULT"
      fi

      APP_URL="${PROTOCOL}://${APP_DOMAIN}"
      S3_ENDPOINT_URL="${PROTOCOL}://${RUSTFS_DOMAIN}"
      CASDOOR_ISSUER_URL="${PROTOCOL}://${CASDOOR_DOMAIN}"
      CASDOOR_ORIGIN_URL="$CASDOOR_ISSUER_URL"
      RUSTFS_CONSOLE_URL="${PROTOCOL}://${RUSTFS_DOMAIN}"
      GRAFANA_URL="${PROTOCOL}://grafana.example.com"
      ;;
  esac
}

apply_env_urls() {
  set_env_value 'APP_URL' "$APP_URL"
  set_env_value 'INTERNAL_APP_URL' "http://localhost:${LOBE_PORT}"
  set_env_value 'S3_ENDPOINT' "$S3_ENDPOINT_URL"
  set_env_value 'AUTH_CASDOOR_ISSUER' "$CASDOOR_ISSUER_URL"
  set_env_value 'origin' "$CASDOOR_ORIGIN_URL"
}

update_init_data() {
  local webhook_secret
  webhook_secret="$(read_env_value 'CASDOOR_WEBHOOK_SECRET' "$ENV_FILE")"

  "$PYTHON_BIN" - "$INIT_DATA_FILE" "$APP_URL" "$webhook_secret" "$LOBE_PORT" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
app_url = sys.argv[2].rstrip('/')
webhook_secret = sys.argv[3]
lobe_port = sys.argv[4]
callback_url = f"{app_url}/api/auth/callback/casdoor"
webhook_url = f"{app_url}/api/webhooks/casdoor"

redirect_uris = []
for candidate in [
    callback_url,
    f"http://localhost:{lobe_port}/api/auth/callback/casdoor",
    f"https://localhost:{lobe_port}/api/auth/callback/casdoor",
]:
    if candidate not in redirect_uris:
        redirect_uris.append(candidate)

with path.open(encoding='utf-8') as file:
    data = json.load(file)

for application in data.get('applications', []):
    if application.get('name') == 'lobechat':
        application['redirectUris'] = redirect_uris
        break

for webhook in data.get('webhooks', []):
    if webhook.get('name') == 'webhook_default':
        webhook['url'] = webhook_url
        headers = webhook.setdefault('headers', [])
        for header in headers:
            if header.get('name') == 'casdoor-secret':
                header['value'] = webhook_secret
                break
        else:
            headers.append({'name': 'casdoor-secret', 'value': webhook_secret})
        break

with path.open('w', encoding='utf-8') as file:
    json.dump(data, file, ensure_ascii=False, indent=2)
    file.write('\n')
PY

  info "casdoor/init_data.json の redirect URI と webhook URL を更新しました"
}

ensure_directories() {
  mkdir -p \
    "${ROOT_DIR}/postgresql/data" \
    "${ROOT_DIR}/redis/data" \
    "${ROOT_DIR}/rustfs/data" \
    "${ROOT_DIR}/rustfs/logs" \
    "${ROOT_DIR}/grafana/data" \
    "${ROOT_DIR}/grafana/dashboards" \
    "${ROOT_DIR}/prometheus/data" \
    "${ROOT_DIR}/tempo/data"

  if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ "$(id -u)" == "0" ]] && command -v chown >/dev/null 2>&1; then
      chown -R 10001:10001 "${ROOT_DIR}/rustfs/data" "${ROOT_DIR}/rustfs/logs"
      chmod -R 755 "${ROOT_DIR}/rustfs/data" "${ROOT_DIR}/rustfs/logs"
      info "RustFS 用ディレクトリの所有者を 10001:10001 に調整しました"
    else
      warn "Linux で RustFS が Permission denied になる場合は rustfs/data と rustfs/logs を 10001:10001 に調整してください"
    fi
  fi
}

postgres_data_already_exists() {
  [[ -d "${ROOT_DIR}/postgresql/data" ]] && find "${ROOT_DIR}/postgresql/data" -mindepth 1 -print -quit | grep -q .
}

maybe_validate_compose() {
  local do_validate="n"

  case "$VALIDATE_COMPOSE" in
    yes)
      do_validate="y"
      ;;
    no)
      do_validate="n"
      ;;
    *)
      ask_yes_no 'docker compose config で設定を検証しますか' 'y'
      do_validate="$ASK_RESULT"
      ;;
  esac

  if [[ "$do_validate" != "y" ]]; then
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    warn 'docker が見つからないため設定検証をスキップしました'
    return 0
  fi

  if ! docker compose version >/dev/null 2>&1; then
    warn 'docker compose が使えないため設定検証をスキップしました'
    return 0
  fi

  if ! docker stats --no-stream >/dev/null 2>&1; then
    warn '現在のユーザーでは Docker へアクセスできないため設定検証をスキップしました'
    return 0
  fi

  docker compose -f "$COMPOSE_FILE" config >/dev/null
  info 'docker compose config を通過しました'
}

print_report() {
  local compose_profiles
  local search_providers
  local searxng_url
  local rustfs_secret
  local grafana_password

  compose_profiles="$(read_env_value 'COMPOSE_PROFILES' "$ENV_FILE")"
  search_providers="$(read_env_value 'SEARCH_PROVIDERS' "$ENV_FILE")"
  searxng_url="$(read_env_value 'SEARXNG_URL' "$ENV_FILE")"
  rustfs_secret="$(read_env_value 'RUSTFS_SECRET_KEY' "$ENV_FILE")"
  grafana_password="$(read_env_value 'GF_SECURITY_ADMIN_PASSWORD' "$ENV_FILE")"

  echo
  echo '=== Setup Summary ==='
  echo "APP_URL: ${APP_URL}"
  echo "Casdoor: ${CASDOOR_ISSUER_URL}"
  echo "RustFS API: ${S3_ENDPOINT_URL}"
  echo "Search providers: ${search_providers:-searxng}"
  echo "SearXNG URL: ${searxng_url:-http://searxng:8080}"

  local browserless_url
  local crawler_impls
  browserless_url="$(read_env_value 'BROWSERLESS_URL' "$ENV_FILE")"
  crawler_impls="$(read_env_value 'CRAWLER_IMPLS' "$ENV_FILE")"
  if csv_has_value "$compose_profiles" 'with-browserless'; then
    echo "Browserless mode: local compose service (${browserless_url:-http://browserless:3000})"
  else
    echo "Browserless mode: external endpoint (${browserless_url:-https://chrome.browserless.io})"
  fi
  echo "Crawler impls: ${crawler_impls:-naive,browserless}"
  echo
  echo 'Credentials to review:'
  echo "  RustFS access key: admin"
  echo "  RustFS secret key: ${rustfs_secret}"
  echo "  Grafana admin password: ${grafana_password}"

  echo
  echo 'Next commands:'
  echo '  docker compose config'
  echo '  docker compose pull'
  echo '  docker compose up -d network-service postgresql redis rustfs rustfs-init tempo prometheus otel-collector casdoor'

  if csv_has_value "$compose_profiles" 'with-searxng'; then
    echo '  docker compose up -d searxng'
  else
    echo '  # 外部 SearXNG を使う場合は compose 内 searxng を起動しません'
  fi

  if csv_has_value "$compose_profiles" 'with-browserless'; then
    echo '  docker compose up -d browserless'
  else
    echo '  # 外部 Browserless を使う場合は compose 内 browserless を起動しません'
  fi

  echo '  docker compose up -d lobe grafana'

  if [[ -z "$(read_env_value 'CLOUDFLARE_TUNNEL_TOKEN' "$ENV_FILE")" ]]; then
    echo
    echo 'Cloudflared は CLOUDFLARE_TUNNEL_TOKEN を設定したあとに個別で起動してください'
  fi

  if postgres_data_already_exists; then
    echo
    warn 'postgresql/data に既存データがあります  casdoor/init_data.json の変更は既存の Casdoor DB へ自動反映されません'
    warn '既存環境では Casdoor 管理画面で redirect URI と webhook を更新するか PostgreSQL を初期化してください'
  fi
}

main() {
  require_file "$ENV_EXAMPLE_FILE"
  require_file "$INIT_DATA_TEMPLATE_FILE"
  require_file "$COMPOSE_FILE"

  detect_python
  load_init_data_defaults
  ensure_env_file
  ensure_static_env_defaults
  ensure_search_env_defaults
  ensure_browserless_env_defaults
  maybe_regenerate_secrets
  load_ports_from_env
  collect_mode_and_urls
  apply_env_urls
  reset_init_data_file_from_template
  update_init_data
  ensure_directories
  maybe_validate_compose
  print_report
}

main "$@"


