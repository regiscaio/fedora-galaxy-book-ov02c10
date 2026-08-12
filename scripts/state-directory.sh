#!/usr/bin/env bash

state_directory_stat_command="/usr/bin/stat"
state_directory_id_command="/usr/bin/id"
state_directory_ancestry=(/var /var/lib)

state_directory_owner_is_expected() {
	local owner="$1"

	if [[ "$EUID" -eq 0 ]]; then
		[[ "$owner" == "0:0" ]]
	else
		[[ "$owner" == \
			"${EUID}:$("$state_directory_id_command" -g)" ]]
	fi
}

validate_state_directory() {
	local directory="$1"
	local owner mode links

	[[ -d "$directory" && ! -L "$directory" ]] || return 1
	owner="$("$state_directory_stat_command" -c '%u:%g' -- "$directory")" || return 1
	mode="$("$state_directory_stat_command" -c '%a' -- "$directory")" || return 1
	links="$("$state_directory_stat_command" -c '%h' -- "$directory")" || return 1
	state_directory_owner_is_expected "$owner" || return 1
	[[ "$mode" == "755" ]] || return 1
	[[ "$links" =~ ^[1-9][0-9]*$ ]] || return 1
}

validate_state_hierarchy() {
	local state_root="$1"
	local include_pending="${2:-1}"
	local pending_dir="${state_root}/pending"

	validate_state_ancestry || return 1
	validate_state_directory "$state_root" || return 1
	if [[ "$include_pending" -eq 1 ]]; then
		validate_state_directory "$pending_dir" || return 1
	fi
}

validate_state_ancestry() {
	local ancestry owner mode

	if [[ "$EUID" -eq 0 ]]; then
		for ancestry in "${state_directory_ancestry[@]}"; do
			[[ -d "$ancestry" && ! -L "$ancestry" ]] || return 1
			owner="$("$state_directory_stat_command" -c '%u:%g' -- "$ancestry")" || return 1
			mode="$("$state_directory_stat_command" -c '%a' -- "$ancestry")" || return 1
			[[ "$owner" == "0:0" ]] || return 1
			[[ "$mode" == "755" ]] || return 1
		done
	fi
}
