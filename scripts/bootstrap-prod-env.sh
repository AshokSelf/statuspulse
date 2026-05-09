#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

existing_value() {
  local key="$1"
  local value

  [ -f "$ENV_FILE" ] || return 1

  value="$(awk -v key="$key" '
    index($0, key "=") == 1 {
      sub(/^[^=]*=/, "")
      print
      found = 1
      exit
    }
    END { if (found != 1) exit 1 }
  ' "$ENV_FILE")" || return 1

  case "$value" in
    \"*\")
      value="${value#\"}"
      value="${value%\"}"
      ;;
    \'*\')
      value="${value#\'}"
      value="${value%\'}"
      ;;
  esac

  printf '%s' "$value"
}

value_or_default() {
  local key="$1"
  local default="$2"
  local value="${!key:-}"

  if [ -z "$value" ]; then
    value="$(existing_value "$key" || true)"
  fi

  if [ -z "$value" ]; then
    value="$default"
  fi

  printf '%s' "$value"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi

  python3 - <<'PY'
import secrets

print(secrets.token_hex(24))
PY
}

env_quote() {
  local value="$1"

  if [ -z "$value" ] || [[ "$value" =~ ^[A-Za-z0-9_./:@%+=,-]+$ ]]; then
    printf '%s' "$value"
    return
  fi

  value="${value//\'/\'\"\'\"\'}"
  printf "'%s'" "$value"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local rendered
  local tmp_file

  rendered="$(env_quote "$value")"
  tmp_file="$(mktemp)"

  if [ -f "$ENV_FILE" ] && grep -q "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$rendered" '
      BEGIN { updated = 0 }
      index($0, key "=") == 1 {
        print key "=" value
        updated = 1
        next
      }
      { print }
      END {
        if (updated == 0) {
          print key "=" value
        }
      }
    ' "$ENV_FILE" >"$tmp_file"
  else
    cat "$ENV_FILE" >"$tmp_file" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$rendered" >>"$tmp_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
}

domain="$(value_or_default DOMAIN "")"
public_base_url="$(value_or_default PUBLIC_BASE_URL "")"

if [ -z "$domain" ] && [ -n "$public_base_url" ]; then
  domain="${public_base_url#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
fi

domain="${domain:-ak-info.online}"
public_base_url="${public_base_url:-https://$domain}"
image_repository="$(value_or_default IMAGE_NAME "$(value_or_default GHCR_IMAGE "ghcr.io/ashokself/statuspulse")")"
db_password="$(value_or_default DB_PASSWORD "$(generate_secret)")"
redis_password="$(value_or_default REDIS_PASSWORD "$(generate_secret)")"
log_file="$(value_or_default LOG_FILE "/opt/statuspulse/logs/statuspulse-monitor.log")"
backup_dir="$(value_or_default BACKUP_DIR "/opt/statuspulse/backups")"

mkdir -p "$(dirname "$ENV_FILE")" "$backup_dir" "$(dirname "$log_file")" "$ROOT_DIR/logs" 2>/dev/null || true
touch "$ENV_FILE"

set_env_value APP_PORT "$(value_or_default APP_PORT "8000")"
set_env_value APP_IMAGE "$(value_or_default APP_IMAGE "$image_repository:latest")"
set_env_value DB_HOST "$(value_or_default DB_HOST "db")"
set_env_value DB_PORT "$(value_or_default DB_PORT "5432")"
set_env_value DB_NAME "$(value_or_default DB_NAME "statuspulse")"
set_env_value DB_USER "$(value_or_default DB_USER "statuspulse")"
set_env_value DB_PASSWORD "$db_password"
set_env_value REDIS_HOST "$(value_or_default REDIS_HOST "redis")"
set_env_value REDIS_PORT "$(value_or_default REDIS_PORT "6379")"
set_env_value REDIS_PASSWORD "$redis_password"
set_env_value RATE_LIMIT_REQUESTS "$(value_or_default RATE_LIMIT_REQUESTS "60")"
set_env_value RATE_LIMIT_WINDOW_SECONDS "$(value_or_default RATE_LIMIT_WINDOW_SECONDS "60")"
set_env_value APP_BLUE_IMAGE "$(value_or_default APP_BLUE_IMAGE "$image_repository:latest")"
set_env_value APP_GREEN_IMAGE "$(value_or_default APP_GREEN_IMAGE "$image_repository:latest")"
set_env_value ACTIVE_SLOT "$(value_or_default ACTIVE_SLOT "blue")"
set_env_value APP_UPSTREAM_HOST "$(value_or_default APP_UPSTREAM_HOST "app_blue")"
set_env_value DOMAIN "$domain"
set_env_value PUBLIC_BASE_URL "$public_base_url"
set_env_value PUBLIC_HEALTH_URL "$(value_or_default PUBLIC_HEALTH_URL "${public_base_url%/}/health")"
set_env_value CADDY_EMAIL "$(value_or_default CADDY_EMAIL "admin@$domain")"
set_env_value CADDY_HEALTH_PORT "$(value_or_default CADDY_HEALTH_PORT "8080")"
set_env_value UPTIME_KUMA_PORT "$(value_or_default UPTIME_KUMA_PORT "3001")"
set_env_value ALERT_WEBHOOK_URL "$(value_or_default ALERT_WEBHOOK_URL "")"
set_env_value EXPECTED_CONTAINERS "$(value_or_default EXPECTED_CONTAINERS "statuspulse-caddy statuspulse-db statuspulse-redis")"
set_env_value DB_CONTAINER "$(value_or_default DB_CONTAINER "statuspulse-db")"
set_env_value REDIS_CONTAINER "$(value_or_default REDIS_CONTAINER "statuspulse-redis")"
set_env_value TLS_HOST "$(value_or_default TLS_HOST "$domain")"
set_env_value TLS_PORT "$(value_or_default TLS_PORT "443")"
set_env_value TLS_WARN_DAYS "$(value_or_default TLS_WARN_DAYS "14")"
set_env_value DISK_WARN_PCT "$(value_or_default DISK_WARN_PCT "80")"
set_env_value MEMORY_WARN_PCT "$(value_or_default MEMORY_WARN_PCT "90")"
set_env_value MONITOR_PATH "$(value_or_default MONITOR_PATH "/")"
set_env_value HTTP_TIMEOUT_SECONDS "$(value_or_default HTTP_TIMEOUT_SECONDS "10")"
set_env_value WEBHOOK_TIMEOUT_SECONDS "$(value_or_default WEBHOOK_TIMEOUT_SECONDS "10")"
set_env_value TCP_TIMEOUT_SECONDS "$(value_or_default TCP_TIMEOUT_SECONDS "3")"
set_env_value LOG_FILE "$log_file"
set_env_value BACKUP_DIR "$backup_dir"
set_env_value BACKUP_RETENTION_COUNT "$(value_or_default BACKUP_RETENTION_COUNT "7")"
set_env_value S3_BACKUP_BUCKET "$(value_or_default S3_BACKUP_BUCKET "")"
set_env_value S3_BACKUP_PREFIX "$(value_or_default S3_BACKUP_PREFIX "statuspulse")"
set_env_value AWS_REGION "$(value_or_default AWS_REGION "us-east-1")"
set_env_value AWS_ACCOUNT_ID "$(value_or_default AWS_ACCOUNT_ID "")"
set_env_value AWS_INSTANCE_NAME "$(value_or_default AWS_INSTANCE_NAME "statuspulse")"

chmod 0600 "$ENV_FILE" 2>/dev/null || true
touch "$log_file" 2>/dev/null || true
