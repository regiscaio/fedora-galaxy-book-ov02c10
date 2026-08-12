#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/rpm-read-lock.sh
source "${repo_root}/scripts/rpm-read-lock.sh"

test_root="$(mktemp -d /tmp/ov02c10-rpm-lock-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

rpm_lock_path="${test_root}/.rpm.lock"
rpm_lock_timeout_seconds="0.2"
touch "$rpm_lock_path"
chmod 0644 "$rpm_lock_path"

acquire_rpm_read_lock
[[ "${GALAXYBOOK_OV02C10_RPM_LOCK_FD:-}" =~ ^[0-9]+$ ]]
validate_rpm_read_lock
bash -c '
	source "$1"
	rpm_lock_path="$2"
	rpm_lock_timeout_seconds="0.2"
	validate_rpm_read_lock
' bash "${repo_root}/scripts/rpm-read-lock.sh" "$rpm_lock_path"

# A writer conflicts with the shared OFD lock until the inherited descriptor
# is explicitly closed. This is the same lock conflict used by RPM 6 writes.
if "$rpm_lock_flock_command" --fcntl --exclusive --nonblock "$rpm_lock_path" true; then
	printf 'RPM read lock did not exclude a writer\n' >&2
	exit 1
fi

lock_fd="$GALAXYBOOK_OV02C10_RPM_LOCK_FD"
exec {lock_fd}<&-
unset GALAXYBOOK_OV02C10_RPM_LOCK_FD
"$rpm_lock_flock_command" --fcntl --exclusive --nonblock "$rpm_lock_path" true

hardlink="${test_root}/hardlink.lock"
ln "$rpm_lock_path" "$hardlink"
if acquire_rpm_read_lock >/dev/null 2>&1; then
	printf 'RPM read lock accepted a multiply linked lock file\n' >&2
	exit 1
fi
unlink "$hardlink"

ln -s "$rpm_lock_path" "${test_root}/unsafe.lock"
rpm_lock_path="${test_root}/unsafe.lock"
if acquire_rpm_read_lock >/dev/null 2>&1; then
	printf 'RPM read lock accepted a symlink\n' >&2
	exit 1
fi

unsafe_parent="${test_root}/unsafe-parent"
mkdir -m 0777 "$unsafe_parent"
touch "${unsafe_parent}/.rpm.lock"
chmod 0644 "${unsafe_parent}/.rpm.lock"
rpm_lock_path="${unsafe_parent}/.rpm.lock"
if acquire_rpm_read_lock >/dev/null 2>&1; then
	printf 'RPM read lock accepted a writable parent directory\n' >&2
	exit 1
fi

printf 'test-rpm-read-lock: ok\n'
