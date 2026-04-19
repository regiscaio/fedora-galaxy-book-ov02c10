#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
printf 'refresh-upstream.sh is deprecated; refreshing from the Intel IPU6 base used on Fedora instead.\n' >&2
exec "${ROOT_DIR}/scripts/refresh-intel-ipu6-base.sh" "$@"
