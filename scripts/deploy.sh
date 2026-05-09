#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
ENV_FILE="$ROOT_DIR/.env"
LOG_FILE="${LOG_FILE:-$ROOT_DIR/deploy.log}"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

set_env_value() {
  local key="$1"
  local value="$2"
  local tmp_file
  tmp_file="$(mktemp)"

  if [ -f "$ENV_FILE" ] && grep -q "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { updated = 0 }
      $0 ~ "^" key "=" {
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
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi

  mv "$tmp_file" "$ENV_FILE"
}

compose() {
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" --profile prod "$@"
}

run_compose() {
  local description="$1"
  shift

  local output
  if ! output="$(compose "$@" 2>&1)"; then
    log "ERROR: ${description} failed"
    if [ -n "$output" ]; then
      printf '%s\n' "$output" | tee -a "$LOG_FILE" >&2
    fi
    compose ps 2>&1 | tee -a "$LOG_FILE" >&2 || true
    return 1
  fi
}

candidate_container_name() {
  printf 'statuspulse-app-%s' "$CANDIDATE_SLOT"
}

remove_stale_candidate() {
  local container_name
  container_name="$(candidate_container_name)"

  compose stop "$CANDIDATE_SERVICE" >/dev/null 2>&1 || true
  compose rm -f "$CANDIDATE_SERVICE" >/dev/null 2>&1 || true
  docker rm -f "$container_name" >/dev/null 2>&1 || true
}

ensure_service_up() {
  local service="$1"
  run_compose "docker compose up for ${service}" up -d "$service"
}

container_healthcheck() {
  local container="$1"
  local attempts=0
  local max_attempts=30

  while [ "$attempts" -lt "$max_attempts" ]; do
    if docker exec "$container" python -c "import json,sys,urllib.request; data=json.load(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)); sys.exit(0 if data.get('status') == 'healthy' and all(data.get('checks', {}).get(k) == 'healthy' for k in ('api','database','redis')) else 1)" >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 2
  done

  return 1
}

rollback_to_active() {
  log "Rolling back traffic to ${ACTIVE_SERVICE}"
  set_env_value ACTIVE_SLOT "$ACTIVE_SLOT"
  set_env_value APP_UPSTREAM_HOST "$ACTIVE_SERVICE"
  compose up -d caddy >/dev/null || true
  compose stop "$CANDIDATE_SERVICE" >/dev/null 2>&1 || true
}

require_command docker
require_command awk
require_command grep
require_command python3

[ -f "$ENV_FILE" ] || die "Missing environment file: $ENV_FILE"

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${IMAGE_NAME:?IMAGE_NAME must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"

ACTIVE_SLOT="${ACTIVE_SLOT:-blue}"
case "$ACTIVE_SLOT" in
  blue) ACTIVE_SERVICE="app_blue"; CANDIDATE_SERVICE="app_green"; CANDIDATE_SLOT="green" ;;
  green) ACTIVE_SERVICE="app_green"; CANDIDATE_SERVICE="app_blue"; CANDIDATE_SLOT="blue" ;;
  *) die "ACTIVE_SLOT must be blue or green" ;;
esac

NEW_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

log "Starting deploy: active slot=${ACTIVE_SLOT}, candidate slot=${CANDIDATE_SLOT}"
log "Target image: ${NEW_IMAGE}"

set_env_value "APP_${CANDIDATE_SLOT^^}_IMAGE" "$NEW_IMAGE"
set_env_value APP_UPSTREAM_HOST "$ACTIVE_SERVICE"

log "Ensuring active service is running"
ensure_service_up "$ACTIVE_SERVICE"

log "Removing stale candidate container ${CANDIDATE_SERVICE}"
remove_stale_candidate

log "Pulling updated image"
run_compose "docker compose pull for ${CANDIDATE_SERVICE}" pull "$CANDIDATE_SERVICE"

log "Starting candidate container ${CANDIDATE_SERVICE}"
ensure_service_up "$CANDIDATE_SERVICE"

candidate_container_id="$(compose ps -q "$CANDIDATE_SERVICE")"
[ -n "$candidate_container_id" ] || die "Unable to find candidate container id"

log "Waiting for candidate health"
if ! container_healthcheck "$candidate_container_id"; then
  docker logs --tail=100 "$candidate_container_id" 2>&1 | tee -a "$LOG_FILE" >&2 || true
  compose stop "$CANDIDATE_SERVICE" >/dev/null 2>&1 || true
  die "Candidate container failed health check"
fi

set_env_value ACTIVE_SLOT "$CANDIDATE_SLOT"
set_env_value APP_UPSTREAM_HOST "$CANDIDATE_SERVICE"

log "Refreshing Caddy"
if ! run_compose "docker compose up for caddy" up -d caddy; then
  rollback_to_active
  die "Failed to refresh Caddy"
fi

public_url="${PUBLIC_BASE_URL:-https://${DOMAIN:-localhost}}"
health_url="${public_url%/}/health"

log "Checking public health at ${health_url}"
if ! curl -fsS --max-time 20 "$health_url" | python3 -c 'import json,sys; data=json.load(sys.stdin); checks=data.get("checks", {}); raise SystemExit(0 if data.get("status") == "healthy" and all(checks.get(k) == "healthy" for k in ("api","database","redis")) else 1)'; then
  log "Public health check failed after cutover"
  rollback_to_active
  die "Deployment rolled back"
fi

log "Stopping previous active service ${ACTIVE_SERVICE}"
compose stop "$ACTIVE_SERVICE" >/dev/null 2>&1 || true

log "Deployment completed successfully"
