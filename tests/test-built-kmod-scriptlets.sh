#!/usr/bin/env bash
set -euo pipefail

fail() {
	printf 'test-built-kmod-scriptlets: %s\n' "$*" >&2
	exit 1
}

[[ "$#" -gt 0 ]] || {
	printf 'usage: %s <exact-kmod.rpm> [...]\n' "${0##*/}" >&2
	exit 64
}

for rpm_path in "$@"; do
	[[ -f "$rpm_path" ]] || fail "RPM does not exist: ${rpm_path}"
	package_name="$(rpm -qp --qf '%{NAME}\n' -- "$rpm_path")"
	[[ "$package_name" =~ ^kmod-galaxybook-ov02c10-[0-9] ]] || \
		fail "not an exact OV02C10 kmod RPM: ${package_name}"

	scriptlets="$(rpm -qp --scripts -- "$rpm_path")"
	requires="$(rpm -qp --requires -- "$rpm_path")"
	if [[ "$scriptlets" =~ [Dd][Ee][Pp][Mm][Oo][Dd] ]]; then
		fail "${package_name} still runs depmod in an RPM scriptlet"
	fi
	for forbidden_requirement in /usr/sbin/depmod /usr/sbin/weak-modules; do
		if [[ "$requires" =~ (^|$'\n')${forbidden_requirement}($|$'\n') ]]; then
			fail "${package_name} still has a mutating scriptlet requirement"
		fi
	done
	if [[ "$scriptlets" != $'postinstall scriptlet (using /bin/sh):\n:\npostuninstall scriptlet (using /bin/sh):\n:' ]]; then
		fail "${package_name} lifecycle scriptlets are not exact no-ops"
	fi
done

printf 'test-built-kmod-scriptlets: ok (%s RPMs)\n' "$#"
