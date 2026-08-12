#!/usr/bin/env bash

# Shared by root-only helpers after acquire_rpm_read_lock has serialized them
# with package transactions. Callers set rpm_command when a test double is
# needed.

rpm_file_owner_result=""

rpm_file_owner() {
	local path="$1"
	local output_file error_file output error_output
	local query_status=0
	local expected_unowned="file ${path} is not owned by any package"

	rpm_file_owner_result=""
	output_file="$(mktemp)" || return 2
	error_file="$(mktemp)" || {
		rm -f -- "$output_file"
		return 2
	}
	if LC_ALL=C "$rpm_command" -qf --qf '%{NAME}\n' -- "$path" \
		>"$output_file" 2>"$error_file"
	then
		query_status=0
	else
		query_status=$?
	fi
	output="$(<"$output_file")"
	error_output="$(<"$error_file")"
	rm -f -- "$output_file" "$error_file"

	if [[ "$query_status" -eq 0 ]]; then
		if [[ -n "$error_output" ]]; then
			printf '%s\n' "$error_output" >&2
			printf 'galaxybook-ov02c10: RPM ownership query produced unexpected diagnostics for %s\n' \
				"$path" >&2
			return 2
		fi
		if [[ -z "$output" || "$output" == *$'\n'* ]]; then
			printf 'galaxybook-ov02c10: RPM returned an ambiguous owner for %s\n' \
				"$path" >&2
			return 2
		fi
		rpm_file_owner_result="$output"
		return 0
	fi

	# RPM 5 writes the exact unowned diagnostic to stdout; RPM 6 moved the
	# same diagnostic to stderr. Accept only that one canonical line on exactly
	# one stream, with status 1 and no additional output.
	if [[ "$query_status" -eq 1 && \
		( ( "$output" == "$expected_unowned" && -z "$error_output" ) || \
		  ( "$error_output" == "$expected_unowned" && -z "$output" ) ) ]]
	then
		return 1
	fi
	[[ -z "$output" ]] || printf '%s\n' "$output" >&2
	[[ -z "$error_output" ]] || printf '%s\n' "$error_output" >&2

	printf 'galaxybook-ov02c10: RPM ownership query failed for %s (status %s)\n' \
		"$path" "$query_status" >&2
	return 2
}
