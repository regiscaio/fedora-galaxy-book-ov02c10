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

expanded_spec="$(mktemp /tmp/ov02c10-spec-test.XXXXXX)"
expanded_kernel_spec_716="$(mktemp /tmp/ov02c10-spec-kernel-716-test.XXXXXX)"
expanded_kernel_spec_718="$(mktemp /tmp/ov02c10-spec-kernel-718-test.XXXXXX)"
generated_patch="$(mktemp /tmp/ov02c10-patch-test.XXXXXX)"
trap 'rm -f -- "$expanded_spec" "$expanded_kernel_spec_716" "$expanded_kernel_spec_718" "$generated_patch"' EXIT

rpmspec -P packaging/fedora/galaxybook-ov02c10-kmod.spec > "$expanded_spec"
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

for kernel_spec in \
	"7.1.6-201.fc44.x86_64:${expanded_kernel_spec_716}" \
	"7.1.8-200.fc44.x86_64:${expanded_kernel_spec_718}"
do
	kernel="${kernel_spec%%:*}"
	spec_output="${kernel_spec#*:}"
	rpmspec -P --define "kernels ${kernel}" \
		packaging/fedora/galaxybook-ov02c10-kmod.spec > "$spec_output"
	rg -q "^%package[[:space:]]+-n kmod-galaxybook-ov02c10-${kernel}$" \
		"$spec_output" || fail "expanded spec lost the binary kmod package for ${kernel}"
	rg -Fq "/lib/modules/${kernel}/extra/galaxybook-ov02c10/" \
		"$spec_output" || fail "expanded spec lost the kmod payload files for ${kernel}"
	rg -Fq "for kernel_version in ${kernel}___/usr/src/kernels/${kernel}; do" \
		"$spec_output" || fail "expanded spec lost the build loop for ${kernel}"
	rg -Fq 'drivers/media/i2c/ov02c10.ko' "$spec_output" || \
		fail "expanded spec lost the OV02C10 module install for ${kernel}"
done

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
rg -q '^PathChanged=/var/lib/galaxybook-ov02c10/pending$' \
	data/systemd/galaxybook-ov02c10-finalize.path || \
	fail "pending directory is not watched for concurrent requests"
rg -Fq '/var/lib/galaxybook-ov02c10/ready' "$expanded_spec" || \
	fail "expanded package lost the readiness state directory"
rg -Fq '/var/lib/galaxybook-ov02c10/pending' "$expanded_spec" || \
	fail "expanded package lost the durable kernel queue"
rg -Fq '/var/lib/galaxybook-ov02c10/ready/<kernel>.state' README.md || \
	fail "Portuguese documentation lost the readiness attestation contract"
for readme in README.md README.en.md README.es.md README.it.md; do
	rg -Fq 'transfiletriggerpostun' "$readme" || \
		fail "${readme} does not document the safe uninstall limitation"
	rg -Fq '/usr/bin/dracut --force --kver "$1"' "$readme" || \
		fail "${readme} does not provide the safe initramfs rebuild command"
	rg -Fq 'source /usr/libexec/galaxybook-ov02c10/kmod-lifecycle-lock.sh' \
		"$readme" || fail "${readme} uninstall guidance bypasses the global lock"
	rg -q "sudo /usr/bin/bash -c '.*set -euo pipefail.*source /usr/libexec/galaxybook-ov02c10/kmod-lifecycle-lock.sh.*acquire_kmod_lifecycle_lock.*dnf remove.*depmod -a.*dracut --force" \
		< <(tr '\n' ' ' < "$readme") || \
		fail "${readme} uninstall guidance is not fail-closed"
done

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
