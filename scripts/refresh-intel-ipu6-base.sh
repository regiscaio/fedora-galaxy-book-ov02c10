#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_RPM="${1:-${INTEL_IPU6_SRPM:-/usr/src/akmods/intel-ipu6-kmod.latest}}"
UPSTREAM_FILE="${ROOT_DIR}/sources/intel-ipu6/ov02c10.c"
WORK_DIR="$(mktemp -d)"

cleanup() {
	rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

if [[ ! -f "${SOURCE_RPM}" ]]; then
	printf 'Intel IPU6 source RPM not found: %s\n' "${SOURCE_RPM}" >&2
	exit 1
fi

mkdir -p "$(dirname "${UPSTREAM_FILE}")"

(
	cd "${WORK_DIR}"
	rpm2cpio "${SOURCE_RPM}" | cpio -idmu --quiet
	find . -maxdepth 1 -type f -name 'ipu6-drivers-*.tar.gz' -print0 \
		| xargs -0r -n1 tar -xzf
)

BASE_FILE="$(find "${WORK_DIR}" -path '*/drivers/media/i2c/ov02c10.c' | head -n1)"
if [[ -z "${BASE_FILE}" ]]; then
	printf 'Could not locate drivers/media/i2c/ov02c10.c inside %s\n' "${SOURCE_RPM}" >&2
	exit 1
fi

cp "${BASE_FILE}" "${UPSTREAM_FILE}"
"${ROOT_DIR}/scripts/export-patch.sh"

printf 'Refreshed %s from %s\n' "${UPSTREAM_FILE}" "${SOURCE_RPM}"
