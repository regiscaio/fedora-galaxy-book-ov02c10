#!/usr/bin/env bash

lifecycle_lock_parent="/run/lock"
lifecycle_lock_root="${lifecycle_lock_parent}/galaxybook-ov02c10"
lifecycle_lock_path="${lifecycle_lock_root}/lifecycle.lock"
lifecycle_lock_timeout_seconds="600"
lifecycle_lock_flock_command="/usr/bin/flock"
lifecycle_lock_install_command="/usr/bin/install"
lifecycle_lock_stat_command="/usr/bin/stat"
lifecycle_lock_id_command="/usr/bin/id"
lifecycle_lock_chown_command="/usr/bin/chown"
lifecycle_lock_chmod_command="/usr/bin/chmod"

validate_lifecycle_lock() {
	local lock_fd="${GALAXYBOOK_OV02C10_LIFECYCLE_LOCK_FD:-}"
	local fd_identity path_identity fd_metadata path_metadata

	[[ "$lock_fd" =~ ^[0-9]+$ ]] || return 1
	[[ -r "/proc/self/fd/${lock_fd}" && \
		-f "/proc/self/fd/${lock_fd}" && \
		-f "$lifecycle_lock_path" && \
		! -L "$lifecycle_lock_path" ]] || return 1
	fd_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${lock_fd}")" || return 1
	path_identity="$("$lifecycle_lock_stat_command" -Lc '%d:%i' -- "$lifecycle_lock_path")" || return 1
	[[ "$fd_identity" == "$path_identity" ]] || return 1
	fd_metadata="$("$lifecycle_lock_stat_command" -Lc '%u:%g:%a:%h' -- "/proc/self/fd/${lock_fd}")" || return 1
	path_metadata="$("$lifecycle_lock_stat_command" -Lc '%u:%g:%a:%h' -- "$lifecycle_lock_path")" || return 1
	[[ "$fd_metadata" == "$path_metadata" ]] || return 1
	if [[ "$EUID" -eq 0 ]]; then
		[[ "$path_metadata" == "0:0:600:1" ]] || return 1
	else
		[[ "$path_metadata" == \
			"${EUID}:$("$lifecycle_lock_id_command" -g):600:1" ]] || return 1
	fi
	"$lifecycle_lock_flock_command" --exclusive \
		--timeout "$lifecycle_lock_timeout_seconds" "$lock_fd"
}

acquire_lifecycle_lock() {
	local owner mode links lock_fd fd_identity path_identity parent_owner parent_mode
	local created_lock=0

	if validate_lifecycle_lock; then
		return 0
	fi
	if [[ -L "$lifecycle_lock_parent" || ! -d "$lifecycle_lock_parent" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock parent is missing or unsafe: %s\n' \
			"$lifecycle_lock_parent" >&2
		return 1
	fi
	parent_owner="$("$lifecycle_lock_stat_command" -c '%u:%g' -- "$lifecycle_lock_parent")" || return 1
	parent_mode="$("$lifecycle_lock_stat_command" -c '%a' -- "$lifecycle_lock_parent")" || return 1
	if [[ "$EUID" -eq 0 ]]; then
		[[ "$parent_owner" == "0:0" ]] || {
			printf 'galaxybook-ov02c10: lifecycle lock parent has an unexpected owner: %s\n' \
				"$lifecycle_lock_parent" >&2
			return 1
		}
	else
		[[ "$parent_owner" == \
			"${EUID}:$("$lifecycle_lock_id_command" -g)" ]] || return 1
	fi
	if (( (8#${parent_mode}) & 8#022 )); then
		printf 'galaxybook-ov02c10: lifecycle lock parent is group- or world-writable: %s\n' \
			"$lifecycle_lock_parent" >&2
		return 1
	fi
	if [[ -L "$lifecycle_lock_root" ]]; then
		printf 'galaxybook-ov02c10: lifecycle lock directory is a symlink: %s\n' \
			"$lifecycle_lock_root" >&2
		return 1
	fi
	if [[ ! -e "$lifecycle_lock_root" ]]; then
		if [[ "$EUID" -eq 0 ]]; then
			"$lifecycle_lock_install_command" -d -o root -g root -m 0700 -- \
				"$lifecycle_lock_root" || return 1
			"$lifecycle_lock_chmod_command" 00700 -- \
				"$lifecycle_lock_root" || return 1
		else
			"$lifecycle_lock_install_command" -d -m 0700 -- \
				"$lifecycle_lock_root" || return 1
		fi
	fi
	[[ -d "$lifecycle_lock_root" && ! -L "$lifecycle_lock_root" ]] || return 1
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
		created_lock=1
	fi
	if [[ "$created_lock" -eq 1 && "$EUID" -eq 0 ]]; then
		"$lifecycle_lock_chown_command" root:root -- "$lifecycle_lock_path" || return 1
		"$lifecycle_lock_chmod_command" 00600 -- "$lifecycle_lock_path" || return 1
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
