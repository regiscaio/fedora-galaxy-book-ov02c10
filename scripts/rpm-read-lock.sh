#!/usr/bin/env bash

rpm_lock_path="/usr/lib/sysimage/rpm/.rpm.lock"
rpm_lock_timeout_seconds="600"
rpm_lock_flock_command="/usr/bin/flock"
rpm_lock_stat_command="/usr/bin/stat"

validate_rpm_read_lock() {
	local lock_fd="${GALAXYBOOK_OV02C10_RPM_LOCK_FD:-}"
	local fd_path fd_identity lock_identity

	if [[ ! "$lock_fd" =~ ^[0-9]+$ ]]
	then
		return 1
	fi

	fd_path="/proc/self/fd/${lock_fd}"
	if [[ ! -r "$fd_path" || ! -f "$fd_path" || ! -f "$rpm_lock_path" || \
		-L "$rpm_lock_path" ]]
	then
		return 1
	fi
	fd_identity="$("$rpm_lock_stat_command" -Lc '%d:%i' -- "$fd_path")" || return 1
	lock_identity="$("$rpm_lock_stat_command" -Lc '%d:%i' -- "$rpm_lock_path")" || return 1
	[[ "$fd_identity" == "$lock_identity" ]] || return 1

	# Reapplying a shared OFD lock to the inherited open-file description is
	# idempotent and proves that this exact descriptor is locked. Linux OFD
	# locks conflict with RPM's process-associated POSIX write lock while
	# remaining compatible with the read lock taken by an rpm -q child.
	"$rpm_lock_flock_command" --fcntl --shared \
		--timeout "$rpm_lock_timeout_seconds" "$lock_fd"
}

acquire_rpm_read_lock() {
	local lock_parent parent_owner parent_mode lock_owner lock_mode lock_links
	local lock_fd fd_identity path_identity

	if validate_rpm_read_lock; then
		return 0
	fi

	lock_parent="$(dirname -- "$rpm_lock_path")"
	if [[ -L "$lock_parent" || ! -d "$lock_parent" || \
		-L "$rpm_lock_path" || ! -f "$rpm_lock_path" ]]
	then
		printf 'galaxybook-ov02c10: RPM lock path is missing or unsafe: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
	parent_owner="$("$rpm_lock_stat_command" -c '%u:%g' -- "$lock_parent")" || return 1
	parent_mode="$("$rpm_lock_stat_command" -c '%a' -- "$lock_parent")" || return 1
	if [[ "$parent_owner" != "0:0" && "${parent_owner%%:*}" != "$EUID" ]]; then
		printf 'galaxybook-ov02c10: RPM lock parent has an unexpected owner: %s\n' \
			"$lock_parent" >&2
		return 1
	fi
	if (( (8#${parent_mode}) & 8#022 )); then
		printf 'galaxybook-ov02c10: RPM lock parent is group- or world-writable: %s\n' \
			"$lock_parent" >&2
		return 1
	fi
	lock_owner="$("$rpm_lock_stat_command" -c '%u:%g' -- "$rpm_lock_path")" || return 1
	lock_mode="$("$rpm_lock_stat_command" -c '%a' -- "$rpm_lock_path")" || return 1
	lock_links="$("$rpm_lock_stat_command" -c '%h' -- "$rpm_lock_path")" || return 1
	if [[ "$lock_owner" != "0:0" && "${lock_owner%%:*}" != "$EUID" ]]; then
		printf 'galaxybook-ov02c10: RPM lock has an unexpected owner: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
	if (( (8#${lock_mode}) & 8#022 )); then
		printf 'galaxybook-ov02c10: RPM lock is group- or world-writable: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
	if [[ "$lock_links" != "1" ]]; then
		printf 'galaxybook-ov02c10: RPM lock must have exactly one hard link: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi

	if ! exec {lock_fd}<"$rpm_lock_path"; then
		printf 'galaxybook-ov02c10: could not open RPM transaction lock: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
	export GALAXYBOOK_OV02C10_RPM_LOCK_FD="$lock_fd"
	fd_identity="$("$rpm_lock_stat_command" -Lc '%d:%i' -- "/proc/self/fd/${lock_fd}")" || {
		exec {lock_fd}<&-
		unset GALAXYBOOK_OV02C10_RPM_LOCK_FD
		return 1
	}
	path_identity="$("$rpm_lock_stat_command" -Lc '%d:%i' -- "$rpm_lock_path")" || {
		exec {lock_fd}<&-
		unset GALAXYBOOK_OV02C10_RPM_LOCK_FD
		return 1
	}
	if [[ "$fd_identity" != "$path_identity" ]]; then
		exec {lock_fd}<&-
		unset GALAXYBOOK_OV02C10_RPM_LOCK_FD
		printf 'galaxybook-ov02c10: RPM lock changed while it was being opened: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
	if ! validate_rpm_read_lock; then
		exec {lock_fd}<&-
		unset GALAXYBOOK_OV02C10_RPM_LOCK_FD
		printf 'galaxybook-ov02c10: timed out waiting for RPM transaction lock: %s\n' \
			"$rpm_lock_path" >&2
		return 1
	fi
}
