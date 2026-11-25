#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filter="${repo_root}/scripts/kmodtool-queue-only-filter.sh"
test_root="$(mktemp -d /tmp/ov02c10-kmodtool-filter.XXXXXX)"
trap 'rm -rf -- "$test_root"' EXIT

fail() {
	printf 'test-kmodtool-queue-only-filter: %s\n' "$*" >&2
	exit 1
}

run_filter() {
	local expected_kernels="$1"
	shift
	"$filter" --expected-kernels "$expected_kernels" -- "$@"
}

mapfile -t test_kernels < <(
	find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | \
		sort -V | while IFS= read -r kernel; do
			[[ -f "/lib/modules/${kernel}/source/Makefile" ]] && printf '%s\n' "$kernel"
		done
)
[[ "${#test_kernels[@]}" -ge 2 ]] || \
	fail "fewer than two installed kernel-devel trees are usable by kmodtool"
test_kernel_one="${test_kernels[${#test_kernels[@]} - 1]}"
test_kernel_two="${test_kernels[${#test_kernels[@]} - 2]}"
kernels="${test_kernel_one} ${test_kernel_two}"

raw_zero="${test_root}/raw-zero.spec"
filtered_zero="${test_root}/filtered-zero.spec"
/usr/bin/kmodtool \
	--target x86_64 \
	--repo fedora \
	--kmodname galaxybook-ov02c10 \
	--akmod > "$raw_zero"
run_filter "" /usr/bin/kmodtool \
	--target x86_64 \
	--repo fedora \
	--kmodname galaxybook-ov02c10 \
	--akmod > "$filtered_zero"
rg -q '^%global kmodtool_queue_only_filter_ok 1$' "$filtered_zero" || \
	fail "zero-exact-package output lost its success marker"
if rg -qi 'depmod|_kmodtool_depmod_post' "$filtered_zero"; then
	fail "zero-exact-package output contains depmod"
fi
if rg -q '^%package[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}' \
	"$filtered_zero"
then
	fail "akmod source expansion unexpectedly contains an exact kmod package"
fi
awk '
	/^%posttrans[[:space:]]+-n[[:space:]]+akmod-galaxybook-ov02c10$/ {
		if (getline <= 0 || $0 != "nohup /usr/sbin/akmods --from-akmod-posttrans --akmod galaxybook-ov02c10 &> /dev/null &") exit 1
		if (getline <= 0 || $0 != "") exit 1
		if (getline <= 0 || $0 !~ /^%post[[:space:]]+-n[[:space:]]+akmod-galaxybook-ov02c10$/) exit 1
		if (getline <= 0 || $0 != "[ -x /usr/sbin/akmods-ostree-post ] && /usr/sbin/akmods-ostree-post galaxybook-ov02c10 %{_usrsrc}/akmods/%{pkg_kmod_name}-%{version}-%{release}.src.rpm") exit 1
		if (getline <= 0 || $0 != "") exit 1
		count++
	}
	END { exit count == 1 ? 0 : 1 }
' "$filtered_zero" || fail "akmod lifecycle bodies do not match the authenticated template"
[[ "$(rg -c '^%(pre|post)(un|trans|untrans)?([[:space:]]|$)|^%(trigger|filetrigger|transfiletrigger)(prein|in|un|postun)?([[:space:]]|$)|^%verifyscript([[:space:]]|$)' \
	"$filtered_zero")" -eq 2 ]] || fail "akmod-only output contains an extra scriptlet"

raw_exact="${test_root}/raw-exact.spec"
filtered_exact="${test_root}/filtered-exact.spec"
/usr/bin/kmodtool \
	--target x86_64 \
	--repo fedora \
	--kmodname galaxybook-ov02c10 \
	--akmod \
	--for-kernels "$kernels" > "$raw_exact"
run_filter "$kernels" /usr/bin/kmodtool \
	--target x86_64 \
	--repo fedora \
	--kmodname galaxybook-ov02c10 \
	--akmod \
	--for-kernels "$kernels" > "$filtered_exact"

[[ "$(rg -c '^%package[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$' \
	"$filtered_exact")" -eq 2 ]] || fail "filtered output lost an exact package"
[[ "$(rg -c '^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$' \
	"$filtered_exact")" -eq 2 ]] || fail "filtered output lost an exact post scriptlet"
[[ "$(rg -c '^%postun[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$' \
	"$filtered_exact")" -eq 2 ]] || fail "filtered output lost an exact postun scriptlet"
[[ "$(rg -c '^%global kmodtool_queue_only_filter_ok 1$' "$filtered_exact")" -eq 1 ]] || \
	fail "filtered exact output has an invalid success marker"
if rg -qi 'depmod|_kmodtool_depmod_post' "$filtered_exact"; then
	fail "filtered exact output retained depmod"
fi
if rg -q '^Requires\(post(un)?\):[[:space:]]+.*sbin/depmod' "$filtered_exact"; then
	fail "filtered exact output retained a depmod scriptlet dependency"
fi
awk '
	/^%post(un)?[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
		if (getline <= 0 || $0 != ":") exit 1
		count++
	}
	END { exit count == 4 ? 0 : 1 }
' "$filtered_exact" || fail "exact lifecycle scriptlets are not explicit no-ops"
[[ "$(rg -c '^%(pre|post)(un|trans|untrans)?([[:space:]]|$)|^%(trigger|filetrigger|transfiletrigger)(prein|in|un|postun)?([[:space:]]|$)|^%verifyscript([[:space:]]|$)' \
	"$filtered_exact")" -eq 4 ]] || fail "filtered exact output contains an extra scriptlet"
if rg -q 'weak-modules|^%preun[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$' \
	"$filtered_exact"
then
	fail "filtered exact output retained an in-transaction weak-module lifecycle"
fi

write_fake_kmodtool() {
	local output_file="$1"
	local fake_command="$2"
	cat > "$fake_command" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
/usr/bin/cat -- "$KMODTOOL_TEST_OUTPUT"
EOF
	chmod 0755 "$fake_command"
	KMODTOOL_TEST_OUTPUT="$output_file" \
		run_filter "$kernels" "$fake_command" \
		--target x86_64 \
		--repo fedora \
		--kmodname galaxybook-ov02c10 \
		--akmod \
		--for-kernels "$kernels"
}

write_fake_kmodtool_zero() {
	local output_file="$1"
	local fake_command="$2"
	cat > "$fake_command" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
/usr/bin/cat -- "$KMODTOOL_TEST_OUTPUT"
EOF
	chmod 0755 "$fake_command"
	KMODTOOL_TEST_OUTPUT="$output_file" \
		run_filter "" "$fake_command" \
		--target x86_64 \
		--repo fedora \
		--kmodname galaxybook-ov02c10 \
		--akmod
}

# The filter implementation must buffer every line and emit no partial result
# when the system kmodtool contract drifts.
malformed="${test_root}/malformed.spec"
/usr/bin/awk '
	!removed && /^Requires\(post\):[[:space:]]+.*\/sbin\/depmod$/ {
		removed=1
		next
	}
	{ print }
' "$raw_exact" > "$malformed"
set +e
write_fake_kmodtool "$malformed" "${test_root}/fake-malformed" \
	> "${test_root}/malformed.out" 2> "${test_root}/malformed.err"
malformed_status=$?
set -e
[[ "$malformed_status" -eq 65 ]] || fail "contract drift did not fail with data error"
[[ ! -s "${test_root}/malformed.out" ]] || fail "contract drift leaked partial output"
rg -q 'full template changed|exact-package contract changed' \
	"${test_root}/malformed.err" || fail "contract drift diagnostic was lost"

# A system-generator failure must retain its status and diagnostics, discard
# the generator's partial stdout, and withhold the RPM success marker.
set +e
/usr/bin/kmodtool \
	--target x86_64 \
	--kmodname galaxybook-ov02c10 \
	--definitely-not-a-kmodtool-option \
	> "${test_root}/system-failure.out" 2> "${test_root}/system-failure.err"
system_status=$?
run_filter "" /usr/bin/kmodtool \
	--target x86_64 \
	--kmodname galaxybook-ov02c10 \
	--definitely-not-a-kmodtool-option \
	> "${test_root}/filter-failure.out" 2> "${test_root}/filter-failure.err"
filter_status=$?
set -e
[[ "$filter_status" -eq "$system_status" && "$filter_status" -ne 0 ]] || \
	fail "system kmodtool failure status was not preserved"
while IFS= read -r diagnostic; do
	[[ -z "$diagnostic" ]] || rg -Fq -- "$diagnostic" \
		"${test_root}/filter-failure.err" || \
		fail "system kmodtool diagnostics were not preserved"
done < "${test_root}/system-failure.err"
[[ ! -s "${test_root}/filter-failure.out" ]] || \
	fail "system kmodtool failure leaked partial output"

# A non-depmod command injected into a generated lifecycle body used to pass a
# token-only filter. Exact-body validation must reject it before any stdout.
/usr/bin/awk '
	!injected && /^%\{_kmodtool_depmod_post\}$/ {
		print
		print "/usr/bin/touch /tmp/should-never-run"
		injected=1
		next
	}
	{ print }
' "$raw_exact" > "${test_root}/injected.spec"
set +e
write_fake_kmodtool "${test_root}/injected.spec" "${test_root}/fake-injected" \
	> "${test_root}/injected.out" 2> "${test_root}/injected.err"
injected_status=$?
set -e
[[ "$injected_status" -eq 65 ]] || fail "injected exact-body command was accepted"
[[ ! -s "${test_root}/injected.out" ]] || fail "injected exact body leaked partial output"
rg -q 'full template changed|exact scriptlet body changed' \
	"${test_root}/injected.err" || \
	fail "injected exact-body failure lost its diagnostic"

# New exact-package lifecycle entry points outside the known block must also
# fail closed, even when their bodies contain no recognized forbidden token.
for injected_header in pre posttrans; do
	/usr/bin/awk -v header="%${injected_header} -n %{package_kmod_name}" '
		!injected && /^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
			print header
			print "/usr/bin/true"
			print ""
			injected=1
		}
		{ print }
	' "$raw_exact" > "${test_root}/${injected_header}.spec"
	set +e
	write_fake_kmodtool "${test_root}/${injected_header}.spec" \
		"${test_root}/fake-${injected_header}" \
		> "${test_root}/${injected_header}.out" \
		2> "${test_root}/${injected_header}.err"
	injected_header_status=$?
	set -e
	[[ "$injected_header_status" -eq 65 ]] || \
		fail "injected %${injected_header} scriptlet was accepted"
	[[ ! -s "${test_root}/${injected_header}.out" ]] || \
		fail "injected %${injected_header} leaked partial output"
	rg -q 'full template changed|unexpected.*scriptlet' \
		"${test_root}/${injected_header}.err" || \
		fail "injected %${injected_header} failure lost its diagnostic"
done

for target_case in concrete macro_composed; do
	case "$target_case" in
		concrete)
			injected_target="kmod-galaxybook-ov02c10-${test_kernel_one}"
			;;
		macro_composed)
			injected_target='%{kmod_pkg_name}-%{kmod_for_kernel}'
			;;
	esac
	/usr/bin/awk -v header="%posttrans -n ${injected_target}" '
		!injected && /^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
			print header
			print "/usr/bin/true"
			print ""
			injected=1
		}
		{ print }
	' "$raw_exact" > "${test_root}/${target_case}.spec"
	set +e
	write_fake_kmodtool "${test_root}/${target_case}.spec" \
		"${test_root}/fake-${target_case}" \
		> "${test_root}/${target_case}.out" \
		2> "${test_root}/${target_case}.err"
	target_case_status=$?
	set -e
	[[ "$target_case_status" -eq 65 ]] || \
		fail "injected ${target_case} scriptlet target was accepted"
	[[ ! -s "${test_root}/${target_case}.out" ]] || \
		fail "injected ${target_case} scriptlet leaked partial output"
done

# RPM accepts leading spaces and tabs before a section header. The raw
# template comparison and the target-agnostic fallback detector must reject
# both spellings before the generated spec can acquire a new entry point.
for whitespace_case in space tab; do
	case "$whitespace_case" in
		space)
			injected_prefix=' '
			;;
		tab)
			injected_prefix=$'\t'
			;;
	esac
	/usr/bin/awk -v prefix="$injected_prefix" -v kernel="$test_kernel_one" '
		!injected && /^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
			print prefix "%posttrans -n kmod-galaxybook-ov02c10-" kernel
			print "/usr/bin/true"
			print ""
			injected=1
		}
		{ print }
	' "$raw_exact" > "${test_root}/${whitespace_case}-header.spec"
	set +e
	write_fake_kmodtool "${test_root}/${whitespace_case}-header.spec" \
		"${test_root}/fake-${whitespace_case}-header" \
		> "${test_root}/${whitespace_case}-header.out" \
		2> "${test_root}/${whitespace_case}-header.err"
	whitespace_status=$?
	set -e
	[[ "$whitespace_status" -eq 65 ]] || \
		fail "${whitespace_case}-prefixed scriptlet header was accepted"
	[[ ! -s "${test_root}/${whitespace_case}-header.out" ]] || \
		fail "${whitespace_case}-prefixed scriptlet leaked partial output"
done

# An RPM macro can expand into a section header even when no literal input
# line resembles one. Authenticate every byte of the known kmodtool template
# so a definition/use pair cannot synthesize a hidden scriptlet.
/usr/bin/awk -v kernel="$test_kernel_one" '
	!injected && /^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}$/ {
		print "%global injected %%posttrans"
		print "%{injected} -n kmod-galaxybook-ov02c10-" kernel
		print "/usr/bin/true"
		print ""
		injected=1
	}
	{ print }
' "$raw_exact" > "${test_root}/macro-indirection.spec"
set +e
write_fake_kmodtool "${test_root}/macro-indirection.spec" \
	"${test_root}/fake-macro-indirection" \
	> "${test_root}/macro-indirection.out" \
	2> "${test_root}/macro-indirection.err"
macro_indirection_status=$?
set -e
[[ "$macro_indirection_status" -eq 65 ]] || \
	fail "macro-synthesized scriptlet was accepted"
[[ ! -s "${test_root}/macro-indirection.out" ]] || \
	fail "macro-synthesized scriptlet leaked partial output"
rg -q 'full template changed' "${test_root}/macro-indirection.err" || \
	fail "macro-indirection failure lost its diagnostic"

# Both akmod scriptlets are permitted only with their exact upstream bodies.
for akmod_header in posttrans post; do
	/usr/bin/awk -v expected_header="%${akmod_header}" '
		!injected && index($0, expected_header) == 1 && /-n[[:space:]]+akmod-galaxybook-ov02c10$/ {
			print
			if (getline <= 0) exit 2
			print
			print "/usr/bin/true"
			injected=1
			next
		}
		{ print }
	' "$raw_zero" > "${test_root}/akmod-${akmod_header}.spec"
	set +e
	write_fake_kmodtool_zero "${test_root}/akmod-${akmod_header}.spec" \
		"${test_root}/fake-akmod-${akmod_header}" \
		> "${test_root}/akmod-${akmod_header}.out" \
		2> "${test_root}/akmod-${akmod_header}.err"
	akmod_body_status=$?
	set -e
	[[ "$akmod_body_status" -eq 65 ]] || \
		fail "mutated akmod %${akmod_header} body was accepted"
	[[ ! -s "${test_root}/akmod-${akmod_header}.out" ]] || \
		fail "mutated akmod %${akmod_header} leaked partial output"
done

/usr/bin/awk '
	!injected && /^%files[[:space:]]+-n[[:space:]]+akmod-galaxybook-ov02c10$/ {
		print "%verifyscript -n akmod-galaxybook-ov02c10"
		print "/usr/bin/true"
		print ""
		injected=1
	}
	{ print }
' "$raw_zero" > "${test_root}/literal-scriptlet.spec"
set +e
write_fake_kmodtool_zero "${test_root}/literal-scriptlet.spec" \
	"${test_root}/fake-literal-scriptlet" \
	> "${test_root}/literal-scriptlet.out" \
	2> "${test_root}/literal-scriptlet.err"
literal_scriptlet_status=$?
set -e
[[ "$literal_scriptlet_status" -eq 65 ]] || fail "literal new scriptlet was accepted"
[[ ! -s "${test_root}/literal-scriptlet.out" ]] || \
	fail "literal new scriptlet leaked partial output"

# NUL bytes cannot be represented in a Bash variable. The wrapper must inspect
# the file-backed byte stream before line parsing and reject it without output.
/usr/bin/cp -- "$raw_exact" "${test_root}/nul.spec"
printf '\0' >> "${test_root}/nul.spec"
set +e
write_fake_kmodtool "${test_root}/nul.spec" "${test_root}/fake-nul" \
	> "${test_root}/nul.out" 2> "${test_root}/nul.err"
nul_status=$?
set -e
[[ "$nul_status" -eq 65 ]] || fail "NUL-bearing generator output was accepted"
[[ ! -s "${test_root}/nul.out" ]] || fail "NUL-bearing output leaked partial output"
rg -q 'not canonical ASCII text' "${test_root}/nul.err" || \
	fail "NUL-bearing failure lost its byte-stream diagnostic"

# A forged success marker in otherwise valid system output must not suppress
# the spec's fail-closed check.
{
	/usr/bin/cat -- "$raw_exact"
	printf '%%global kmodtool_queue_only_filter_ok 1\n'
} > "${test_root}/forged-marker.spec"
set +e
write_fake_kmodtool "${test_root}/forged-marker.spec" "${test_root}/fake-marker" \
	> "${test_root}/marker.out" 2> "${test_root}/marker.err"
marker_status=$?
set -e
[[ "$marker_status" -eq 65 ]] || fail "forged success marker was accepted"
[[ ! -s "${test_root}/marker.out" ]] || fail "forged marker leaked partial output"
rg -q 'full template changed|forged the success marker' \
	"${test_root}/marker.err" || \
	fail "forged-marker failure lost its diagnostic"

# Even successful kmodtool output is unauthenticated when the generator writes
# diagnostics. Preserve stderr, withhold the success marker, and fail closed.
cat > "${test_root}/fake-stderr" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
/usr/bin/cat -- "$KMODTOOL_TEST_OUTPUT"
printf 'synthetic kmodtool warning\n' >&2
EOF
chmod 0755 "${test_root}/fake-stderr"
set +e
KMODTOOL_TEST_OUTPUT="$raw_exact" \
	run_filter "$kernels" "${test_root}/fake-stderr" \
	--target x86_64 \
	--repo fedora \
	--kmodname galaxybook-ov02c10 \
	--akmod \
	--for-kernels "$kernels" \
	> "${test_root}/stderr.out" 2> "${test_root}/stderr.err"
stderr_status=$?
set -e
[[ "$stderr_status" -eq 65 ]] || fail "status-zero stderr was authenticated"
[[ ! -s "${test_root}/stderr.out" ]] || fail "status-zero stderr leaked output"
rg -Fq 'synthetic kmodtool warning' "${test_root}/stderr.err" || \
	fail "status-zero generator diagnostic was not preserved"

printf 'test-kmodtool-queue-only-filter: ok\n'
