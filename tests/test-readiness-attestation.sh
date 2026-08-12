#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/finalize-kernel.sh
source "${repo_root}/scripts/finalize-kernel.sh"

test_root="$(mktemp -d /tmp/ov02c10-attestation-test.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

kernel="7.1.8-test.x86_64"
state_root="${test_root}/state"
ready_root="${state_root}/ready"
module="${test_root}/ov02c10.ko.zst"
initramfs="${test_root}/initramfs-${kernel}.img"
mkdir -p "$state_root" "$ready_root"
chmod 0755 "$state_root" "$ready_root"
printf 'module\n' > "$module"
printf 'initramfs\n' > "$initramfs"

find_command=/usr/bin/find
stat_command=/usr/bin/stat
install_command=/usr/bin/install
mktemp_command=/usr/bin/mktemp
mv_command=/usr/bin/mv
rm_command=/usr/bin/rm
chmod_command=/usr/bin/chmod
chown_command=/usr/bin/chown
if [[ "$EUID" -ne 0 ]]; then
	chown_command=/usr/bin/true
	ensure_ready_directory() {
		return 0
	}
	readiness_target_is_safe() {
		local marker="$1"
		[[ -e "$marker" || -L "$marker" ]] || return 0
		[[ -f "$marker" && ! -L "$marker" ]] || return 1
		[[ "$(stat -Lc '%a:%h' -- "$marker")" == "644:1" ]]
	}
fi

if [[ "$EUID" -eq 0 ]]; then
	trusted_root_directory /var
	trusted_root_directory /var/lib
	unsafe_trusted_root="${test_root}/unsafe-trusted-root"
	mkdir "$unsafe_trusted_root"
	chmod 0775 "$unsafe_trusted_root"
	if trusted_root_directory "$unsafe_trusted_root"; then
		printf 'trusted root validation accepted a group-writable directory\n' >&2
		exit 1
	fi
fi

# Test scope substitutes the fixed /boot path while leaving production code on
# the literal same-kernel initramfs path.
publish_test_attestation() {
	local source_function
	source_function="$(declare -f publish_readiness_attestation)"
	source_function="${source_function//\/boot\/initramfs-\$\{kernel\}.img/${initramfs}}"
	eval "${source_function/publish_readiness_attestation/publish_readiness_attestation_under_test}"
	publish_readiness_attestation_under_test "$kernel" "$module"
}

publish_test_attestation
marker="${ready_root}/${kernel}.state"
[[ -f "$marker" && ! -L "$marker" ]]
[[ "$(stat -c '%a:%h' "$marker")" == "644:1" ]]
if [[ "$EUID" -eq 0 ]]; then
	[[ "$(stat -c '%u:%g' "$marker")" == "0:0" ]]
	[[ "$(stat -c '%u:%g:%a' "$state_root")" == "0:0:755" ]]
	[[ "$(stat -c '%u:%g:%a' "$ready_root")" == "0:0:755" ]]
fi
mapfile -t lines < "$marker"
[[ "${#lines[@]}" -eq 3 ]]
[[ "${lines[0]}" == "version=1" ]]
[[ "${lines[1]}" =~ ^initramfs=[0-9]+\|[0-9]+\|[0-9]+\|-?[0-9]+\.[0-9]+\|-?[0-9]+\.[0-9]+$ ]]
[[ "${lines[2]}" =~ ^module=[0-9]+\|[0-9]+\|[0-9]+\|-?[0-9]+\.[0-9]+\|-?[0-9]+\.[0-9]+$ ]]

stale_content="$(<"$marker")"
printf 'module changed\n' >> "$module"
publish_test_attestation
[[ "$(<"$marker")" != "$stale_content" ]]

mv "$marker" "${marker}.regular"
ln -s "${marker}.regular" "$marker"
if publish_test_attestation >/dev/null 2>&1; then
	printf 'attestation writer accepted a symlink destination\n' >&2
	exit 1
fi
[[ -L "$marker" ]]

unlink "$marker"
mv "${marker}.regular" "$marker"
mkdir "${marker}.directory"
mv "$marker" "${marker}.last-good"
ln -s "${marker}.directory" "$marker"
if publish_test_attestation >/dev/null 2>&1; then
	printf 'attestation writer accepted a destination symlink to a directory\n' >&2
	exit 1
fi
[[ -L "$marker" ]]
unlink "$marker"
mv "${marker}.last-good" "$marker"
[[ -z "$(find "$ready_root" -maxdepth 1 -name ".${kernel}.*" -print -quit)" ]]

# If an attested input disappears after the temporary marker was written, the
# destination remains the last known-good marker and no dotfile leaks.
real_file_fingerprint="$(declare -f file_fingerprint)"
eval "${real_file_fingerprint/file_fingerprint/file_fingerprint_real}"
counter_file="${test_root}/fingerprint.calls"
: > "$counter_file"
file_fingerprint() {
	local calls
	calls="$(wc -l < "$counter_file")"
	printf 'call\n' >> "$counter_file"
	if [[ "$calls" -eq 2 ]]; then
		return 1
	fi
	file_fingerprint_real "$1"
}
known_good="$(<"$marker")"
if publish_readiness_attestation_under_test "$kernel" "$module" >/dev/null 2>&1; then
	printf 'attestation writer accepted an input failure during publication\n' >&2
	exit 1
fi
[[ "$(<"$marker")" == "$known_good" ]]
[[ -z "$(find "$ready_root" -maxdepth 1 -name ".${kernel}.*" -print -quit)" ]]

# A failure after atomic publication removes the now-untrustworthy marker.
: > "$counter_file"
file_fingerprint() {
	local calls
	calls="$(wc -l < "$counter_file")"
	printf 'call\n' >> "$counter_file"
	if [[ "$calls" -eq 4 ]]; then
		return 1
	fi
	file_fingerprint_real "$1"
}
if publish_readiness_attestation_under_test "$kernel" "$module" >/dev/null 2>&1; then
	printf 'attestation writer accepted a post-publication input failure\n' >&2
	exit 1
fi
[[ ! -e "$marker" ]]

# The real writer is reachable only after the same validated module resolves,
# dracut succeeds and lsinitrd attests the external per-kernel path.
file_fingerprint() {
	file_fingerprint_real "$1"
}
publish_readiness_attestation() {
	publish_readiness_attestation_under_test "$@"
}
fake_gate_depmod() {
	return 0
}
fake_gate_modinfo() {
	printf '%s\n' "$module"
}
fake_gate_dracut() {
	return "$gate_dracut_status"
}
fake_gate_lsinitrd() {
	[[ "$gate_lsinitrd_status" -eq 0 ]] || return "$gate_lsinitrd_status"
	printf '%s\n' \
		"-rw-r--r-- 1 root root 1 Jan 1 00:00 usr/lib/modules/${kernel}/extra/galaxybook-ov02c10/drivers/media/i2c/ov02c10.ko.zst"
}
depmod_command=fake_gate_depmod
modinfo_command=fake_gate_modinfo
dracut_command=fake_gate_dracut
lsinitrd_command=fake_gate_lsinitrd
module_root="${test_root}/modules"
mkdir -p "${module_root}/${kernel}"
validated_replacement="$module"

gate_dracut_status=1
gate_lsinitrd_status=0
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalizer accepted a dracut failure before attestation\n' >&2
	exit 1
fi
[[ ! -e "$marker" ]]

gate_dracut_status=0
gate_lsinitrd_status=1
if finalize_kernel "$kernel" >/dev/null 2>&1; then
	printf 'finalizer accepted an lsinitrd failure before attestation\n' >&2
	exit 1
fi
[[ ! -e "$marker" ]]

gate_lsinitrd_status=0
finalize_kernel "$kernel" >/dev/null
[[ -f "$marker" && ! -L "$marker" ]]

printf 'test-readiness-attestation: ok\n'
