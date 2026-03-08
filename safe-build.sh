#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUILD_SCRIPT="$ROOT_DIR/local-build.sh"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[safe-build] missing command: $1" >&2
    exit 1
  fi
}

need_cmd bash
need_cmd cargo
need_cmd node

if [ ! -f "$LOCAL_BUILD_SCRIPT" ]; then
  echo "[safe-build] local build script not found: $LOCAL_BUILD_SCRIPT" >&2
  exit 1
fi

cores="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
mem_kb="$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)"

# Conservative job tuning for mobile memory pressure.
if [ "${mem_kb:-0}" -lt 3000000 ]; then
  auto_jobs=1
  auto_node_mb=768
elif [ "${mem_kb:-0}" -lt 5000000 ]; then
  auto_jobs=2
  auto_node_mb=1024
else
  auto_jobs=$((cores / 2))
  [ "$auto_jobs" -lt 2 ] && auto_jobs=2
  [ "$auto_jobs" -gt 4 ] && auto_jobs=4
  auto_node_mb=1536
fi

data_use_pct="$(df -P /data 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }' || true)"
if [ -n "${data_use_pct:-}" ] && [ "${data_use_pct:-0}" -ge 92 ]; then
  echo "[safe-build] warning: /data usage is ${data_use_pct}% (low free space may cause instability)." >&2
fi

if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock || true
  trap 'termux-wake-unlock >/dev/null 2>&1 || true' EXIT
  echo "[safe-build] termux wake lock enabled"
fi

if command -v termux-toast >/dev/null 2>&1; then
  termux-toast "VibeKanban safe build started" >/dev/null 2>&1 || true
fi

if [ -n "${CARGO_BUILD_JOBS:-}" ]; then
  export CARGO_BUILD_JOBS
else
  export CARGO_BUILD_JOBS="$auto_jobs"
fi

export CARGO_PROFILE_RELEASE_LTO="${CARGO_PROFILE_RELEASE_LTO:-off}"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-16}"
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-0}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"

if [ -n "${NODE_OPTIONS:-}" ]; then
  case " $NODE_OPTIONS " in
    *" --max-old-space-size="*) ;;
    *) export NODE_OPTIONS="$NODE_OPTIONS --max-old-space-size=$auto_node_mb" ;;
  esac
else
  export NODE_OPTIONS="--max-old-space-size=$auto_node_mb"
fi

safe_nice="${SAFE_BUILD_NICE:-10}"

echo "[safe-build] root: $ROOT_DIR"
echo "[safe-build] cores: $cores"
echo "[safe-build] MemAvailable: ${mem_kb} kB"
echo "[safe-build] CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS"
echo "[safe-build] CARGO_PROFILE_RELEASE_LTO=$CARGO_PROFILE_RELEASE_LTO"
echo "[safe-build] CARGO_PROFILE_RELEASE_CODEGEN_UNITS=$CARGO_PROFILE_RELEASE_CODEGEN_UNITS"
echo "[safe-build] CARGO_PROFILE_RELEASE_DEBUG=$CARGO_PROFILE_RELEASE_DEBUG"
echo "[safe-build] NODE_OPTIONS=$NODE_OPTIONS"
echo "[safe-build] local-build script: $LOCAL_BUILD_SCRIPT"

if [ "${SAFE_BUILD_DRY_RUN:-0}" = "1" ]; then
  echo "[safe-build] dry-run enabled, not invoking local-build.sh"
  exit 0
fi

if command -v nice >/dev/null 2>&1; then
  exec nice -n "$safe_nice" bash "$LOCAL_BUILD_SCRIPT"
else
  exec bash "$LOCAL_BUILD_SCRIPT"
fi
