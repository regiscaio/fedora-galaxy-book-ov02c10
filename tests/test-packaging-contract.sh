#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
	printf 'test-packaging-contract: %s\n' "$*" >&2
	exit 1
}

[[ ! -e data/modules-load.d/galaxybook-ov02c10.conf ]] || \
	fail "modules-load configuration must not be shipped"
[[ "$(<data/modprobe.d/galaxybook-ov02c10.conf)" == \
	"softdep intel_ipu6_isys pre: ov02c10" ]] || fail "unexpected softdep"
[[ "$(<data/depmod.d/galaxybook-ov02c10.conf)" == \
	"override ov02c10 * extra/galaxybook-ov02c10/drivers/media/i2c" ]] || \
	fail "unexpected depmod override"
if rg -q '_modulesloaddir|data/modules-load' packaging/fedora/galaxybook-ov02c10-kmod.spec; then
	fail "spec still references modules-load"
fi
rg -q '^%transfiletriggerin .* -- /lib/modules /usr/lib/modules$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || fail "missing module file trigger"
rg -q '^Source1:[[:space:]]+kmodtool-queue-only-filter\.sh$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || fail "missing kmodtool filter source"
for filter_build_requirement in bash coreutils diffutils kmodtool; do
	rg -q "^BuildRequires:[[:space:]]+${filter_build_requirement}$" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec || \
		fail "missing filter BuildRequires: ${filter_build_requirement}"
done
rg -Fq '%{error:kmodtool queue-only filtering failed}' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "spec does not fail closed when kmodtool filtering fails"
rg -Fq '%{?kernels:%{error:kmodtool is required to generate a source RPM with explicit kernels}}' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "source-only fallback accepts an unverifiable explicit kernel list"
[[ "$(rg -cF "kmodtool queue-only filtering was deferred; refusing an unverified binary build" \
	packaging/fedora/galaxybook-ov02c10-kmod.spec)" -eq 2 ]] || \
	fail "unverified build guard must protect both prep and build stages"
rg -Fq 'cp "$(KMODTOOL_FILTER)" "$(RPMBUILD_DIR)/SOURCES/"' Makefile || \
	fail "RPM build does not stage the kmodtool filter"
rg -q '^Source2:[[:space:]]+finalizer-transaction\.sh$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "missing embedded finalizer transaction source"
rg -Fq 'cp "$(FINALIZER_TRANSACTION)" "$(RPMBUILD_DIR)/SOURCES/"' Makefile || \
	fail "RPM build does not stage the pre-transaction helper"
rg -q '^Source3:[[:space:]]+finalizer-transaction-pretrans\.sh$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail 'missing macro-escaped pretrans source'
rg -Fq "sed 's/%/%%/g' \"\$<\" > \"\$@\"" Makefile || \
	fail 'RPM build does not mechanically escape the complete pretrans source'
rg -Fq 'install -Dm0755 %{SOURCE2} \' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail 'installed transaction helper is not sourced from authenticated Source2'
if rg -Fq 'install -Dm0755 scripts/finalizer-transaction.sh' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec
then
	fail 'installed transaction helper can diverge from authenticated Source2'
fi
if rg -Fq '%{' scripts/finalizer-transaction.sh; then
	fail 'Source2 contains an RPM macro token that can corrupt the embedded pretrans body'
fi
expected_finalizer_interpreter='/usr/bin/env -i PATH=/usr/bin:/usr/sbin GALAXYBOOK_FINALIZER_FAMILY=ov02c10 GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-ov02c10-kmod-common GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.25-0 GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-max98390-kmod-common GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.12-0 GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0 GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=galaxybook-ov02c10-finalize.path:galaxybook-ov02c10-finalize.timer GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=- GALAXYBOOK_FINALIZER_SERVICE_UNIT=galaxybook-ov02c10-finalize.service GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-ov02c10/pending GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-ov02c10-finalizer-transaction-recovery.service GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-ov02c10-finalizer-transaction GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/galaxybook-ov02c10-finalize.service/cgroup.procs /usr/bin/bash --noprofile --norc'
rg -Fq "%global finalizer_interpreter ${expected_finalizer_interpreter}" \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "spec lost the exact env-i finalizer ABI"

expanded_spec="$(mktemp /tmp/ov02c10-spec-test.XXXXXX)"
expanded_kernel_spec_one="$(mktemp /tmp/ov02c10-spec-kernel-one-test.XXXXXX)"
expanded_kernel_spec_two="$(mktemp /tmp/ov02c10-spec-kernel-two-test.XXXXXX)"
expanded_kernel_spec_rhel="$(mktemp /tmp/ov02c10-spec-kernel-rhel-test.XXXXXX)"
generated_patch="$(mktemp /tmp/ov02c10-patch-test.XXXXXX)"
failed_filter_sourcedir="$(mktemp -d /tmp/ov02c10-failed-filter.XXXXXX)"
spec_sourcedir="$(mktemp -d /tmp/ov02c10-spec-sources.XXXXXX)"
failed_filter_output="$(mktemp /tmp/ov02c10-failed-filter-out.XXXXXX)"
failed_filter_error="$(mktemp /tmp/ov02c10-failed-filter-err.XXXXXX)"
trap 'rm -f -- "$expanded_spec" "$expanded_kernel_spec_one" "$expanded_kernel_spec_two" "$expanded_kernel_spec_rhel" "$generated_patch" "$failed_filter_output" "$failed_filter_error"; rm -rf -- "$failed_filter_sourcedir" "$spec_sourcedir"' EXIT

install -m 0755 scripts/kmodtool-queue-only-filter.sh \
	"${spec_sourcedir}/kmodtool-queue-only-filter.sh"
install -m 0644 scripts/finalizer-transaction.sh \
	"${spec_sourcedir}/finalizer-transaction.sh"
sed 's/%/%%/g' scripts/finalizer-transaction.sh \
	> "${spec_sourcedir}/finalizer-transaction-pretrans.sh"

rpmspec -P --define "_sourcedir ${spec_sourcedir}" \
	packaging/fedora/galaxybook-ov02c10-kmod.spec > "$expanded_spec"
buildable_names() {
	rpmspec -q --builtrpms --qf '%{NAME}\n' --define "_sourcedir ${spec_sourcedir}" \
		"$@" packaging/fedora/galaxybook-ov02c10-kmod.spec | LC_ALL=C sort
}
[[ "$(buildable_names)" == $'akmod-galaxybook-ov02c10\ngalaxybook-ov02c10-kmod-common\nkmod-galaxybook-ov02c10' ]] || \
	fail "the distribution build must produce exactly the akmod, common and metapackage"
rg -Fq "%pretrans -n galaxybook-ov02c10-kmod-common -p \"${expected_finalizer_interpreter}\" -f ${spec_sourcedir}/finalizer-transaction-pretrans.sh" \
	"$expanded_spec" || fail "expanded pretrans lost its exact env-i ABI"
rg -Fq "%posttrans -n galaxybook-ov02c10-kmod-common -p \"${expected_finalizer_interpreter}\"" \
	"$expanded_spec" || fail "expanded posttrans lost its exact env-i ABI"
rg -q '^%transfiletriggerin -n galaxybook-ov02c10-kmod-common .* -- /lib/modules /usr/lib/modules$' \
	"$expanded_spec" || fail "expanded spec lost the file trigger"
rg -q '/usr/libexec/galaxybook-ov02c10/queue-finalization --from-rpm-trigger' \
	"$expanded_spec" || fail "expanded spec does not queue the finalizer"
rg -q '/usr/libexec/galaxybook-ov02c10/queue-finalization --migration' \
	"$expanded_spec" || fail "expanded spec does not queue legacy migration"
if sed -n '/^%posttrans -n galaxybook-ov02c10-kmod-common$/,/^%transfiletriggerin/p' \
	"$expanded_spec" | \
	rg -q 'rpm -q|/usr/bin/rpm|migrate-legacy-config|finalize-kernel'
then
	fail "expanded scriptlets still run an RPM database consumer in-transaction"
fi
if rg -q '/modules-load.d/galaxybook-ov02c10.conf' "$expanded_spec"; then
	fail "expanded package still ships modules-load"
fi

mapfile -t test_kernels < <(
	find /usr/src/kernels -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | \
		sort -V | while IFS= read -r kernel; do
			[[ -f "/lib/modules/${kernel}/source/Makefile" ]] && printf '%s\n' "$kernel"
		done
)
[[ "${#test_kernels[@]}" -gt 0 ]] || \
	fail "no installed kernel-devel tree is usable by kmodtool"
test_kernel_one="${test_kernels[${#test_kernels[@]} - 1]}"
test_kernel_two="$test_kernel_one"
if [[ "${#test_kernels[@]}" -gt 1 ]]; then
	test_kernel_two="${test_kernels[${#test_kernels[@]} - 2]}"
fi

for kernel_spec in \
	"${test_kernel_one}:${expanded_kernel_spec_one}" \
	"${test_kernel_two}:${expanded_kernel_spec_two}"
do
	kernel="${kernel_spec%%:*}"
	spec_output="${kernel_spec#*:}"
	[[ "$(buildable_names --define "kernels ${kernel}")" == "kmod-galaxybook-ov02c10-${kernel}" ]] || \
		fail "akmodsbuild would give DNF more than the per-kernel RPM for ${kernel}"
	rpmspec -P \
		--define "_sourcedir ${spec_sourcedir}" \
		--define "kernels ${kernel}" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec > "$spec_output"
	rg -q "^%package[[:space:]]+-n kmod-galaxybook-ov02c10-${kernel}$" \
		"$spec_output" || fail "expanded spec lost the binary kmod package for ${kernel}"
	rg -Fq "/lib/modules/${kernel}/extra/galaxybook-ov02c10/" \
		"$spec_output" || fail "expanded spec lost the kmod payload files for ${kernel}"
	rg -Fq "for kernel_version in ${kernel}___/usr/src/kernels/${kernel}; do" \
		"$spec_output" || fail "expanded spec lost the build loop for ${kernel}"
	rg -Fq 'drivers/media/i2c/ov02c10.ko' "$spec_output" || \
		fail "expanded spec lost the OV02C10 module install for ${kernel}"
	rg -q '^Requires:[[:space:]]+galaxybook-ov02c10-kmod-common >=' "$spec_output" || \
		fail "per-kernel RPM lost its dependency on the common package"
	if rg -q '^Requires\(post(un)?\):[[:space:]]+.*/sbin/depmod$|_kmodtool_depmod_post' \
		"$spec_output"
	then
		fail "expanded exact kmod retains a generated depmod dependency for ${kernel}"
	fi
	awk -v package_name="kmod-galaxybook-ov02c10-${kernel}" '
		$0 ~ "^%post(un)?[[:space:]]+-n[[:space:]]+" package_name "$" {
			if (getline <= 0 || $0 != ":") exit 1
			count++
		}
		END { exit count == 2 ? 0 : 1 }
	' "$spec_output" || fail "expanded exact lifecycle is not queue-only for ${kernel}"
	if rg -q "^%(pre|post|trigger|filetrigger|transfiletrigger)[[:alnum:]_]*[[:space:]].*-n[[:space:]]+kmod-galaxybook-ov02c10-${kernel}$" \
		"$spec_output" | rg -v '^%post(un)?[[:space:]]'
	then
		fail "expanded exact kmod has an unexpected lifecycle entry for ${kernel}"
	fi
done

rpmspec -P \
	--define "_sourcedir ${spec_sourcedir}" \
	--define "kernels ${test_kernel_one}" \
	--define 'with_rhel_kabi 1' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec > "$expanded_kernel_spec_rhel"
if rg -q '/sbin/depmod|_kmodtool_depmod_post|/sbin/weak-modules' \
	"$expanded_kernel_spec_rhel"
then
	fail "with_rhel_kabi expansion retained mutating exact-kmod lifecycle commands"
fi
if rg "^%(pre|post|trigger|filetrigger|transfiletrigger)[[:alnum:]_]*[[:space:]].*-n[[:space:]]+kmod-galaxybook-ov02c10-" \
	"$expanded_kernel_spec_rhel" | rg -v '^%post(un)?[[:space:]]'
then
	fail "with_rhel_kabi expansion retained an unexpected exact-kmod lifecycle entry"
fi
awk '
	/^%post(un)?[[:space:]]+-n[[:space:]]+kmod-galaxybook-ov02c10-/ {
		if (getline <= 0 || $0 != ":") exit 1
		count++
	}
	END { exit count == 2 ? 0 : 1 }
' "$expanded_kernel_spec_rhel" || \
	fail "with_rhel_kabi exact lifecycle is not two strict no-ops"

# RPM ignores the exit status of a shell expansion. The explicit marker check
# must still make spec parsing fail before it can emit a partial expanded spec.
printf '#!/usr/bin/bash\nexit 73\n' \
	> "${failed_filter_sourcedir}/kmodtool-queue-only-filter.sh"
install -m 0644 scripts/finalizer-transaction.sh \
	"${failed_filter_sourcedir}/finalizer-transaction.sh"
sed 's/%/%%/g' scripts/finalizer-transaction.sh \
	> "${failed_filter_sourcedir}/finalizer-transaction-pretrans.sh"
set +e
rpmspec -P --define "_sourcedir ${failed_filter_sourcedir}" \
	packaging/fedora/galaxybook-ov02c10-kmod.spec \
	> "$failed_filter_output" 2> "$failed_filter_error"
failed_filter_status=$?
set -e
[[ "$failed_filter_status" -ne 0 ]] || fail "spec ignored a failed kmodtool filter"
[[ ! -s "$failed_filter_output" ]] || fail "failed filter emitted a partial expanded spec"
rg -q 'kmodtool queue-only filtering failed' "$failed_filter_error" || \
	fail "failed filter did not report the fail-closed spec error"

diff_rc=0
diff -u \
	--label a/sources/intel-ipu6/ov02c10.c sources/intel-ipu6/ov02c10.c \
	--label b/module/ov02c10.c module/ov02c10.c > "$generated_patch" || diff_rc=$?
[[ "$diff_rc" -le 1 ]] || fail "could not regenerate downstream patch"
cmp -s "$generated_patch" patches/0001-galaxy-book-ov02c10-downstream.patch || \
	fail "downstream patch is stale"

rg -q 'static s64 ov02c10_get_pixel_rate' module/ov02c10.c || \
	fail "driver does not calculate per-lane pixel rate"
rg -q 'v4l2_ctrl_new_fwnode_properties' module/ov02c10.c || \
	fail "driver does not expose fwnode controls"
rg -q -- '--add-drivers ov02c10' scripts/finalize-kernel.sh || \
	fail "finalizer must add ov02c10 only after validating the external payload"
rg -Fq 'migrate_command="${script_dir}/migrate-legacy-config"' \
	scripts/finalize-kernel.sh || fail "finalizer does not use the installed migration helper name"
rg -Fq 'cleanup_command="${script_dir}/cleanup-stale-modules"' \
	scripts/finalize-kernel.sh || fail "finalizer does not use the installed cleanup helper name"
rg -Fq '/usr/libexec/galaxybook-ov02c10/state-directory.sh' "$expanded_spec" || \
	fail "expanded package lost the shared state-directory validator"
rg -Fq '/usr/libexec/galaxybook-ov02c10/kmod-lifecycle-lock.sh' "$expanded_spec" || \
	fail "expanded package lost the global kmod lifecycle lock helper"
if rg -q 'GALAXYBOOK_KMOD_LIFECYCLE_LOCK_PATH|\$\{[^}]*KMOD_LIFECYCLE[^}]*PATH' \
	scripts/kmod-lifecycle-lock.sh
then
	fail "global kmod lifecycle path became environment-overridable"
fi
rg -Fq 'kmod_lifecycle_lock_path="/run/lock/galaxybook-kmod-lifecycle.lock"' \
	scripts/kmod-lifecycle-lock.sh || fail "global kmod lifecycle path changed"
rg -Fq 'kmod_lifecycle_lock_timeout_seconds="600"' \
	scripts/kmod-lifecycle-lock.sh || fail "global kmod lifecycle timeout changed"
if rg -qi 'ov02c10|max98390|galaxybook-setup' scripts/kmod-lifecycle-lock.sh; then
	fail "global kmod lifecycle helper contains a project-specific name"
fi
for state_consumer in scripts/queue-finalization.sh scripts/finalize-pending.sh; do
	rg -Fq 'source "${script_dir}/state-directory.sh"' "$state_consumer" || \
		fail "${state_consumer} does not source the installed state validator"
done
for mutating_consumer in \
	scripts/finalize-pending.sh \
	scripts/finalize-kernel.sh \
	scripts/cleanup-stale-modules.sh \
	scripts/migrate-legacy-config.sh
do
	rg -Fq 'source "${script_dir}/kmod-lifecycle-lock.sh"' "$mutating_consumer" || \
		fail "${mutating_consumer} does not source the global lifecycle lock"
done
if rg -q 'kmod-lifecycle-lock|acquire_kmod_lifecycle_lock' \
	scripts/queue-finalization.sh
then
	fail "in-transaction queue trigger must not take the global lifecycle lock"
fi
rg -q 'run_pending_lifecycle\(\).*acquire_kmod_lifecycle_lock.*acquire_lifecycle_lock.*acquire_rpm_read_lock.*process_pending' \
	< <(tr '\n' ' ' < scripts/finalize-pending.sh) || \
	fail "pending worker lost global-private-RPM lock ordering"
rg -q 'reconcile_kernel\(\).*acquire_kmod_lifecycle_lock.*acquire_lifecycle_lock.*acquire_rpm_read_lock.*validate_replacement.*"\$migrate_command".*"\$cleanup_command".*finalize_kernel' \
	< <(tr '\n' ' ' < scripts/finalize-kernel.sh) || \
	fail "public finalizer lost global-private-RPM lifecycle ordering"
rg -q '"\$apply" -eq 1.*acquire_kmod_lifecycle_lock.*acquire_lifecycle_lock.*acquire_rpm_read_lock' \
	< <(tr '\n' ' ' < scripts/cleanup-stale-modules.sh) || \
	fail "cleanup --apply lost global-private-RPM lock ordering"
rg -q '"\$dry_run" -ne 1.*acquire_kmod_lifecycle_lock.*acquire_lifecycle_lock.*acquire_rpm_read_lock' \
	< <(tr '\n' ' ' < scripts/migrate-legacy-config.sh) || \
	fail "non-dry migration lost global-private-RPM lock ordering"
rg -q 'validate_replacement.*"\$migrate_command".*"\$cleanup_command".*finalize_kernel' < <(
	tr '\n' ' ' < scripts/finalize-kernel.sh
) || fail "public finalizer lost validate-before-mutation lifecycle ordering"
rg -Fq 'queue_marker migration "$state_root"' scripts/queue-finalization.sh || \
	fail "common-only migration marker would enter the watched kernel queue"
rg -Fq 'local migration_marker="${state_root}/migration.pending"' \
	scripts/finalize-pending.sh || fail "worker lost the deferred migration marker"
rg -q '^Requires:[[:space:]]+systemd$' packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "common package does not require systemd"
for conditional_requirement in \
	'(galaxybook-max98390-kmod-common >= 1.00.12 if galaxybook-max98390-kmod-common)' \
	'(galaxybook-setup >= 1.00.48 if galaxybook-setup)'
do
	rg -Fq "Requires:       ${conditional_requirement}" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec || \
		fail "common package lost mixed-version guard: ${conditional_requirement}"
	rg -Fq "$conditional_requirement" "$expanded_spec" || \
		fail "expanded common package lost mixed-version guard: ${conditional_requirement}"
done
if rg -q '^Conflicts:[[:space:]]+galaxybook-ov02c10-kmod' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec
then
	fail "common package would deadlock an akmods/exact-kmod bootstrap upgrade"
fi
for pretrans_requirement in bash coreutils diffutils rpm systemd util-linux-core; do
	rg -q "^Requires\(pretrans\):[[:space:]]+${pretrans_requirement}$" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec || \
		fail "missing pretrans dependency: ${pretrans_requirement}"
done
rg -q '^Requires\(posttrans\):[[:space:]]+diffutils$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail 'missing posttrans dependency: diffutils'
rg -Fq '%pretrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}" -f %{SOURCE3}' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "common package does not embed the upgrade quiescence helper"
rg -Fq '%posttrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}"' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "common package posttrans lost the clean finalizer interpreter"
rg -Fq '%{_libexecdir}/%{prjname}/finalizer-transaction --posttrans "$1"' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "common package does not resume finalization after the transaction"
if rg -q -- '--resume-after-rpm' packaging/fedora/galaxybook-ov02c10-kmod.spec; then
	fail "common package retained the nonexistent legacy finalizer CLI"
fi
rg -q '^BuildRequires:[[:space:]]+systemd-rpm-macros$' \
	packaging/fedora/galaxybook-ov02c10-kmod.spec || \
	fail "spec does not declare the systemd RPM macros build dependency"
for unit in service path timer; do
	rg -Fq "/usr/lib/systemd/system/galaxybook-ov02c10-finalize.${unit}" "$expanded_spec" || \
		fail "expanded package lost the ${unit} unit"
done
rg -q '^ExecStart=/usr/bin/systemd-inhibit .*finalize-pending$' \
	data/systemd/galaxybook-ov02c10-finalize.service || \
	fail "pending worker is not protected by a shutdown inhibitor"
rg -q '^ExecStart=/usr/bin/systemd-inhibit --what=shutdown:sleep:idle ' \
	data/systemd/galaxybook-ov02c10-finalize.service || \
	fail "pending worker inhibitor does not cover idle, sleep and shutdown"
rg -q '^Wants=akmods.service systemd-logind.service$' \
	data/systemd/galaxybook-ov02c10-finalize.service || \
	fail "pending worker does not wait for akmods"
rg -q '^enable galaxybook-ov02c10-finalize.path$' \
	data/systemd/90-galaxybook-ov02c10.preset || \
	fail "path unit is not enabled by the vendor preset"
rg -q '^enable galaxybook-ov02c10-finalize.timer$' \
	data/systemd/90-galaxybook-ov02c10.preset || \
	fail "timer unit is not enabled by the vendor preset"
rg -Fq 'PathExistsGlob=/var/lib/galaxybook-ov02c10/pending/*.pending' \
	data/systemd/galaxybook-ov02c10-finalize.path || \
	fail "preexisting pending markers do not reactivate finalization"
rg -Fq '/var/lib/galaxybook-ov02c10/ready' "$expanded_spec" || \
	fail "expanded package lost the readiness state directory"
rg -Fq '/var/lib/galaxybook-ov02c10/pending' "$expanded_spec" || \
	fail "expanded package lost the durable kernel queue"
rg -Fq '/var/lib/galaxybook-ov02c10/ready/<kernel>.state' README.md || \
	fail "Portuguese documentation lost the readiness attestation contract"
for readme in README.md README.en.md README.es.md README.it.md; do
	for compatibility_marker in '1.00.25' '1.00.12' '1.00.48' 'EVR'; do
		rg -Fq "$compatibility_marker" "$readme" || \
			fail "${readme} lost compatibility marker ${compatibility_marker}"
	done
	rg -Fq 'transfiletriggerpostun' "$readme" || \
		fail "${readme} does not document the safe uninstall limitation"
	rg -Fq '`kmodtool`' "$readme" || \
		fail "${readme} does not document filtered kmodtool scriptlets"
	rg -Fq '`%postun`' "$readme" || \
		fail "${readme} does not document the no-op removal scriptlet"
	rg -Fq 'no-op' "$readme" || \
		fail "${readme} does not make the queue-only scriptlets explicit"
	rg -Fq '`dnf`' "$readme" && rg -Fq '`depmod`' "$readme" || \
		fail "${readme} does not reject an incomplete manual removal sequence"
	rg -Fq 'read lock' "$readme" || \
		fail "${readme} does not define the future removal lock contract"
	case "$readme" in
		README.md)
			online_migration_marker='DNF online'
			reboot_guard_marker='Não reinicie'
			;;
		README.en.md)
			online_migration_marker='online DNF'
			reboot_guard_marker='Do not reboot'
			;;
		README.es.md)
			online_migration_marker='DNF en línea'
			reboot_guard_marker='No reinicies'
			;;
		README.it.md)
			online_migration_marker='DNF online'
			reboot_guard_marker='Non riavviare'
			;;
	esac
	rg -Fq "$online_migration_marker" "$readme" && \
		rg -Fq "$reboot_guard_marker" "$readme" || \
		fail "${readme} does not constrain the initial legacy migration to the live procedure"
	if rg -q 'dnf remove "kmod-galaxybook-ov02c10|acquire_kmod_lifecycle_lock.*dnf remove' \
		< <(tr '\n' ' ' < "$readme")
	then
		fail "${readme} still publishes an unsupported manual removal command"
	fi
done

rg -Fq 'não é suportada' README.md || \
	fail "Portuguese documentation does not mark exact removal unsupported"
rg -Fq 'not automatically' README.en.md || \
	fail "English documentation does not mark exact removal unsupported"
rg -Fq 'no está' README.es.md || \
	fail "Spanish documentation does not mark exact removal unsupported"
rg -Fq 'non è supportata' README.it.md || \
	fail "Italian documentation does not mark exact removal unsupported"

if rg -q 'data/modules-load.d/galaxybook-ov02c10.conf' \
	README.md README.en.md README.es.md README.it.md
then
	fail "documentation still references the removed modules-load source file"
fi
rg -q 'não instala mais `modules-load.d`' README.md || \
	fail "Portuguese documentation does not explain modules-load removal"
rg -q 'no longer installs `modules-load.d`' README.en.md || \
	fail "English documentation does not explain modules-load removal"
rg -q 'ya no instala `modules-load.d`' README.es.md || \
	fail "Spanish documentation does not explain modules-load removal"
rg -q 'non installa più `modules-load.d`' README.it.md || \
	fail "Italian documentation does not explain modules-load removal"

printf 'test-packaging-contract: ok\n'
