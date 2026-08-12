#!/usr/bin/env bash

lifecycle_lock_parent="/run/lock"
lifecycle_lock_root="${lifecycle_lock_parent}/galaxybook-ov02c10"
lifecycle_lock_path="${lifecycle_lock_root}/lifecycle.lock"
lifecycle_lock_timeout_seconds="600"
lifecycle_lock_flock_command="/usr/bin/flock"
lifecycle_lock_install_command="/usr/bin/install"
lifecycle_lock_stat_command="/usr/bin/stat"

validate_lifecycle_lock() {
	local lock_fd="${GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD:-}"
	local fd_identity path_identity

	[[ "$lock_fd" =~ ^[0-9]+$ ]] || return 1
	[[ -r "/proc/self/fd/${lock_fd}" && -f "$lifecycle_lock_path" && \
		! -L "$lifecycle_lock_path" ]] || return 1
	fd_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${lock_fd}")" || return 1
	path_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "$lifecycle_lock_path")" || return 1
	[[ "$fd_identity" == "$path_identity" ]] || return 1
	"$lifecycle_lock_flock_command" --exclusive \
		--timeout "$lifecycle_lock_timeout_seconds" "$lock_fd"
}

acquire_lifecycle_lock() {
	local owner mode links lock_fd fd_identity path_identity

	if validate_lifecycle_lock; then
		return 0
	fi
	if [[ -L "$lifecycle_lock_parent" || ! -d "$lifecycle_lock_parent" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock parent is missing or unsafe: %s\n' \
			"$lifecycle_lock_parent" >&2
		return 1
	fi
	if [[ -L "$lifecycle_lock_root" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock directory is a symlink: %s\n' \
			"$lifecycle_lock_root" >&2
		return 1
	fi
	"$lifecycle_lock_install_command" -d -m 0700 -- "$lifecycle_lock_root" || return 1
	owner="$("$lifecycle_lock_stat_command" -c '%u:%g' -- "$lifecycle_lock_root")" || return 1
	mode="$("$lifecycle_lock_stat_command" -c '%a' -- "$lifecycle_lock_root")" || return 1
	if [[ "$EUID" -eq 0 && "$owner" != "0:0" ]] || [[ "$mode" != "700" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock directory has unsafe metadata: %s\n' \
			"$lifecycle_lock_root" >&2
		return 1
	fi
	if [[ -L "$lifecycle_lock_path" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock is a symlink: %s\n' \
			"$lifecycle_lock_path" >&2
		return 1
	fi
	if [[ ! -e "$lifecycle_lock_path" ]]; then
		(umask 077 && : > "$lifecycle_lock_path") || return 1
	fi
	[[ -f "$lifecycle_lock_path" && ! -L "$lifecycle_lock_path" ]] || return 1
	owner="$("$lifecycle_lock_stat_command" -c '%u:%g' -- "$lifecycle_lock_path")" || return 1
	mode="$("$lifecycle_lock_stat_command" -c '%a' -- "$lifecycle_lock_path")" || return 1
	links="$("$lifecycle_lock_stat_command" -c '%h' -- "$lifecycle_lock_path")" || return 1
	if [[ "$EUID" -eq 0 && "$owner" != "0:0" ]] || \
		[[ "$mode" != "600" || "$links" != "1" ]]
	then
		printf 'galaxybook-ov02c10: lifecycle lock has unsafe metadata: %s\n' \
			"$lifecycle_lock_path" >&2
		return 1
	fi
	if ! exec {lock_fd}<>"$lifecycle_lock_path"; then
		return 1
	fi
	fd_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${lock_fd}")" || {
		exec {lock_fd}>&-
		return 1
	}
	path_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "$lifecycle_lock_path")" || {
		exec {lock_fd}>&-
		return 1
	}
	if [[ "$fd_identity" != "$path_identity" ]]; then
		exec {lock_fd}>&-
		printf 'galaxybook-ov02c10: lifecycle lock changed while it was being opened: %s\n' \
			"$lifecycle_lock_path" >&2
		return 1
	fi
	export GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD="$lock_fd"
	if ! validate_lifecycle_lock; then
		exec {lock_fd}>&-
		unset GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD
		printf 'galaxybook-ov02c10: could not acquire lifecycle lock: %s\n' \
			"$lifecycle_lock_path" >&2
		return 1
	fi
}
