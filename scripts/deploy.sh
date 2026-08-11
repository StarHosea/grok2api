#!/usr/bin/env bash
# Production deploy for grok2api + quality-guard sidecar.
# Idempotent: pull GHCR images, recreate containers, wait for healthz.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi

if [ -z "${GROK2API_IMAGE:-}" ] || [[ "${GROK2API_IMAGE}" == grok2api-local:* ]]; then
  GROK2API_IMAGE="ghcr.io/starhosea/grok2api:latest"
fi
if [ -z "${GROK2API_QUALITY_GUARD_IMAGE:-}" ]; then
  GROK2API_QUALITY_GUARD_IMAGE="ghcr.io/starhosea/grok2api-quality-guard:latest"
fi

# Always enable the quality-guard Compose profile in production.
case ",${COMPOSE_PROFILES:-}," in
  *,quality-guard,*) ;;
  *)
    if [ -n "${COMPOSE_PROFILES:-}" ]; then
      COMPOSE_PROFILES="${COMPOSE_PROFILES},quality-guard"
    else
      COMPOSE_PROFILES="quality-guard"
    fi
    ;;
esac

umask 077
{
  printf 'GROK2API_IMAGE=%s\n' "${GROK2API_IMAGE}"
  printf 'GROK2API_QUALITY_GUARD_IMAGE=%s\n' "${GROK2API_QUALITY_GUARD_IMAGE}"
  printf 'COMPOSE_PROFILES=%s\n' "${COMPOSE_PROFILES}"
} > .env
chmod 600 .env

export GROK2API_IMAGE GROK2API_QUALITY_GUARD_IMAGE COMPOSE_PROFILES

echo "[deploy] image=${GROK2API_IMAGE}"
echo "[deploy] quality-guard=${GROK2API_QUALITY_GUARD_IMAGE}"
echo "[deploy] profiles=${COMPOSE_PROFILES}"

echo "[deploy] pulling latest images..."
docker compose pull

echo "[deploy] recreating containers..."
docker compose up -d --pull always --force-recreate --remove-orphans

echo "[deploy] pruning dangling images..."
docker image prune -f >/dev/null

echo "[deploy] waiting for healthz..."
ready=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
    ready=1
    echo "[deploy] healthz OK (${i}s)"
    break
  fi
  sleep 1
done
if [ "$ready" != "1" ]; then
  echo "[deploy] healthz failed; recent logs:" >&2
  docker logs --tail 80 grok2api >&2 || true
  exit 1
fi

echo "[deploy] waiting for quality-guard..."
guard_ready=0
for i in $(seq 1 45); do
  if docker compose ps --status running --services 2>/dev/null | grep -qx 'egress-quality-guard'; then
    if docker logs --tail 80 grok2api-egress-quality-guard 2>/dev/null | grep -Fq '"event":"guard_started"'; then
      guard_ready=1
      echo "[deploy] quality-guard OK (${i}s)"
      break
    fi
    # Container is up; bootstrap may still be settling after grok2api restart.
    if [ "$i" -ge 20 ]; then
      guard_ready=1
      echo "[deploy] quality-guard container running (${i}s)"
      break
    fi
  fi
  sleep 1
done
if [ "$guard_ready" != "1" ]; then
  echo "[deploy] quality-guard not ready; recent logs:" >&2
  docker logs --tail 80 grok2api-egress-quality-guard >&2 || true
  docker compose ps >&2 || true
  exit 1
fi

echo "[deploy] status:"
docker compose ps
