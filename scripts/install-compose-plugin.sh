#!/usr/bin/env bash
set -Eeuo pipefail

PLUGIN_PATH="${DOCKER_COMPOSE_PLUGIN_PATH:-/usr/local/lib/docker/cli-plugins/docker-compose}"
COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-}"
FALLBACK_COMPOSE_VERSION="v2.33.1"

have_compose() {
  docker compose version >/dev/null 2>&1
}

install_from_package_manager() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y docker-compose-plugin >/dev/null 2>&1 || return 1
    return 0
  fi

  return 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64' ;;
    aarch64 | arm64) printf 'aarch64' ;;
    *)
      printf 'Unsupported architecture for Docker Compose: %s\n' "$(uname -m)" >&2
      return 1
      ;;
  esac
}

latest_compose_version() {
  command -v curl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1

  curl -fsSL https://api.github.com/repos/docker/compose/releases/latest | python3 -c '
import json
import sys

print(json.load(sys.stdin)["tag_name"])
'
}

install_from_github_release() {
  local arch
  local tmp_file
  local url

  command -v curl >/dev/null 2>&1 || {
    printf 'curl is required to download Docker Compose\n' >&2
    return 1
  }

  arch="$(detect_arch)"
  if [ -z "$COMPOSE_VERSION" ]; then
    COMPOSE_VERSION="$(latest_compose_version || true)"
  fi
  COMPOSE_VERSION="${COMPOSE_VERSION:-$FALLBACK_COMPOSE_VERSION}"

  url="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${arch}"
  tmp_file="$(mktemp)"

  curl -fsSL -o "$tmp_file" "$url"
  mkdir -p "$(dirname "$PLUGIN_PATH")"
  cp "$tmp_file" "$PLUGIN_PATH"
  chmod 0755 "$PLUGIN_PATH"
  rm -f "$tmp_file"
}

command -v docker >/dev/null 2>&1 || {
  printf 'docker is required before installing Docker Compose\n' >&2
  exit 1
}

if have_compose; then
  docker compose version
  exit 0
fi

install_from_package_manager || true

if ! have_compose; then
  install_from_github_release
fi

docker compose version
