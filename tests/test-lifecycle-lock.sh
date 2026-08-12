#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lifecycle-lock.sh
source "${repo_root}/scripts/lifecycle-lock.sh"

test_root="$(mktemp -d /tmp/ov02c10-lifecycle-lock-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

lifecycle_lock_parent="$test_root"
lifecycle_lock_root="${test_root}/private"
lifecycle_lock_path="${lifecycle_lock_root}/lifecycle.lock"

acquire_lifecycle_lock
[[ "${GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD:-}" =~ ^[0-9]+$ ]]
[[ "$(stat -c '%a:%h' "$lifecycle_lock_path")" == "600:1" ]]
bash -c '
	source "$1"
	lifecycle_lock_parent="$2"
	lifecycle_lock_root="$3"
	lifecycle_lock_path="$4"
	validate_lifecycle_lock
' bash "${repo_root}/scripts/lifecycle-lock.sh" \
	"$lifecycle_lock_parent" "$lifecycle_lock_root" "$lifecycle_lock_path"
if flock --exclusive --nonblock "$lifecycle_lock_path" true; then
	printf 'lifecycle lock did not serialize another reconciler\n' >&2
	exit 1
fi

lock_fd="$GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD"
exec {lock_fd}<&-
unset GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD
flock --exclusive --nonblock "$lifecycle_lock_path" true

run_worker_public_race() {
	local mode="$1"
	local ready="${test_root}/${mode}.worker-ready"
	local release="${test_root}/${mode}.worker-release"
	local public_acquired="${test_root}/${mode}.public-acquired"
	local worker_pid public_pid worker_status=0

	(
		source "${repo_root}/scripts/lifecycle-lock.sh"
		lifecycle_lock_parent="$test_root"
		lifecycle_lock_root="${test_root}/private"
		lifecycle_lock_path="${lifecycle_lock_root}/lifecycle.lock"
		lifecycle_lock_timeout_seconds=2
		acquire_lifecycle_lock
		: > "$ready"
		while [[ ! -e "$release" ]]; do /usr/bin/sleep 0.01; done
		if [[ "$mode" == failure ]]; then
			exit 73
		fi
		exit 0
	) &
	worker_pid=$!
	for ((attempt = 1; attempt <= 200; attempt++)); do
		[[ -e "$ready" ]] && break
		/usr/bin/sleep 0.01
	done
	[[ -e "$ready" ]]

	(
		source "${repo_root}/scripts/lifecycle-lock.sh"
		lifecycle_lock_parent="$test_root"
		lifecycle_lock_root="${test_root}/private"
		lifecycle_lock_path="${lifecycle_lock_root}/lifecycle.lock"
		lifecycle_lock_timeout_seconds=2
		acquire_lifecycle_lock
		: > "$public_acquired"
	) &
	public_pid=$!
	/usr/bin/sleep 0.2
	[[ ! -e "$public_acquired" ]]

	if [[ "$mode" == signal ]]; then
		kill -TERM "$worker_pid"
	else
		: > "$release"
	fi
	wait "$worker_pid" || worker_status=$?
	case "$mode" in
		success) [[ "$worker_status" -eq 0 ]] ;;
		failure) [[ "$worker_status" -eq 73 ]] ;;
		signal) (( worker_status > 128 )) ;;
	esac
	wait "$public_pid"
	[[ -e "$public_acquired" ]]
}

# Model the queued worker as the first holder and the public --kernel API as
# the second. The real lock serializes them and is released on every exit path.
run_worker_public_race success
run_worker_public_race failure
run_worker_public_race signal

mv "$lifecycle_lock_path" "${lifecycle_lock_path}.regular"
ln -s "${lifecycle_lock_path}.regular" "$lifecycle_lock_path"
if acquire_lifecycle_lock >/dev/null 2>&1; then
	printf 'lifecycle lock accepted a symlink\n' >&2
	exit 1
fi

printf 'test-lifecycle-lock: ok\n'
