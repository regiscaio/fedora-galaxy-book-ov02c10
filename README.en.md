<p>
  <a href="README.md">🇧🇷 Português</a>
  <a href="README.en.md">🇺🇸 English</a>
  <a href="README.es.md">🇪🇸 Español</a>
  <a href="README.it.md">🇮🇹 Italiano</a>
</p>

# Galaxy Book OV02C10

## Quick install

To install the driver from the public DNF repository:

```bash
sudo dnf config-manager addrepo --from-repofile=https://packages.caioregis.com/fedora/caioregis.repo
sudo dnf install akmod-galaxybook-ov02c10
```

As complementary diagnostics and userspace tools for the Galaxy Book4 Ultra,
it also makes sense to install:

```bash
sudo dnf install galaxybook-camera galaxybook-setup
```

`fedora-galaxy-book-ov02c10` is the repository for the downstream `ov02c10`
driver used on Samsung Galaxy Book laptops under Fedora, currently focused on
the **Galaxy Book4 Ultra**.

The goal of this project is to keep a **small and reviewable** delta on top of
the `ov02c10` base used by the **Intel IPU6** stack packaged for Fedora, not
on top of the pure upstream Linux kernel driver. That avoids large divergences
between the sensor module and the rest of the IPU6 stack installed on the
system.

## Current status

In August 2026 the external module registered the sensor in the IPU6 graph
and `libcamera` listed the camera, but capture delivered no frames. The
journal reported `csi2-4 error: Frame sync error`.

The new timing adjustment applies only to a Samsung Galaxy Book4 Ultra
`960XGL` with DMI board `NP960XGL-XG1BR`, a **26 MHz** sensor clock and two
CSI-2 lanes. For the nominal 400 MHz mode, the driver now reports the actual
link frequency of **541666666 Hz** and **216666666 pixels/s**; the default
VTS is **3152 lines**. It does not reprogram the PLL or change the IPU6
bridge. Other boards, clocks and lane counts retain their previous timing.

On October 21, [4nrry measured 30.08 fps on this board model](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/123#issuecomment-6319696718)
using another driver with these timings. This is not a capture result for
this Fedora package: use the ten-frame test below to verify it locally.

## What this repository provides

The repository separates three layers clearly:

- `sources/intel-ipu6/ov02c10.c`: snapshot of the `ov02c10` driver extracted
  from the Intel IPU6 source RPM used in Fedora;
- `module/ov02c10.c`: downstream version with the required project-specific
  delta;
- `patches/0001-galaxy-book-ov02c10-downstream.patch`: patch generated from
  the difference between those two files;
- `data/modprobe.d/galaxybook-ov02c10.conf`: `softdep` asking for `ov02c10`
  before `intel_ipu6_isys`;
- `data/depmod.d/galaxybook-ov02c10.conf`: override to prioritize the packaged
  module in `extra/galaxybook-ov02c10/drivers/media/i2c` over Fedora's in-tree
  copy;
- `scripts/finalize-kernel.sh`: same-kernel `depmod` and initramfs finalization
  after validating RPM ownership, vermagic, and the external payload;
- `scripts/kmod-lifecycle-lock.sh`: authenticated global mutex that serializes
  module maintenance across Galaxy Book drivers;
- `scripts/migrate-legacy-config.sh`: conservative removal of old `/etc`
  shadows only when their bytes exactly match project-generated content;
- `scripts/cleanup-stale-modules.sh`: detection and guarded cleanup of old
  manually installed module copies.

The project no longer installs `modules-load.d`. Forcing the sensor early in
boot could run probe before the IPU6 graph was ready and produce a transient
defer. Device demand now drives loading, while `softdep` preserves the required
ordering.

Fedora packaging generates:

- `akmod-galaxybook-ov02c10`
- `kmod-galaxybook-ov02c10`
- `galaxybook-ov02c10-kmod-common`

## What the patch changes today

The current downstream delta is intentionally small:

- it exposes `get_selection()` and crop metadata so userspace can correctly see
  the active sensor area on top of the Intel IPU6 base;
- it applies the OV02C10 rotation quirk to the Samsung Galaxy Book4 Ultra as
  well, so the image is not inverted when the fixed module is in use;
- it validates power-management resources and SSDB data, reports probe defers
  through the appropriate API, and publishes firmware orientation/rotation
  controls;
- it keeps `HTS=2280` in two-lane mode. The nominal rate at 19.2 MHz is
  160 million pixels/s; only the 26 MHz configuration described above changes
  the reported rates and the default frame length.

Rebasing on the Intel IPU6 base was a deliberate decision: the old module,
although it solved sensor probing, had drifted too far from the Fedora 44
installed stack and started breaking `libcamera` integration with the media
graph exposed by IPU6.

## Relationship to the community Galaxy Book3 fix

This work was enabled by the learnings from the community repository:

- <https://github.com/abdallah-alkanani/galaxybook3-ov02c10-fix/>

That repository guided the investigation of the camera path and the clock and
crop points. It does not, however, provide a validated 26 MHz PLL sequence for
this machine. This project is **not** a direct fork of that code: the goal is
to keep a small patch on top of the Intel IPU6 `ov02c10` that tracks Fedora.

## Scope

This repository only covers the **kernel side** of the solution.

For the userspace camera application, see:

- <https://github.com/regiscaio/fedora-galaxy-book-camera>

For the graphical installer and diagnostics helper, see:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Installation for users

### Via local RPMs

After generating packages with `make rpm`, the recommended local installation
is:

```bash
sudo dnf install \
  /path/to/galaxybook-ov02c10-kmod-common-*.rpm \
  /path/to/akmod-galaxybook-ov02c10-*.rpm \
  /path/to/kmod-galaxybook-ov02c10-*.rpm
kernel="$(uname -r)"
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$kernel"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$kernel"
sudo reboot
```

This is the recommended flow because the `akmod` automatically builds the
module for the running kernel. If a binary RPM already exists for a specific
kernel, it will have a name like
`kmod-galaxybook-ov02c10-<kernel>.rpm`; that is the real module payload. The
`kmod-galaxybook-ov02c10` package without a kernel version in its name is only
the tracking metapackage and is not enough on its own to guarantee that the
`.ko` file will already be available at boot.

If you are updating already installed local RPMs, always include the three
files in the same transaction (`common`, `akmod`, and `kmod`). An old
`kmod-galaxybook-ov02c10` metapackage can pin the previous `akmod` version
through an exact dependency and make `dnf` ignore the driver update.

OV02C10 `1.00.25` coordinates transactions only with
`galaxybook-max98390-kmod-common` `1.00.12` or newer and
`galaxybook-setup` `1.00.48` or newer when those packages are already
installed. Update the set in one operation; the conditional dependencies do
not automatically install a missing component.

The initial migration from the public legacy line is supported only through
the online DNF procedure with systemd running. Do not reboot until recovery
and reconciliation finish. An initial upgrade inside a chroot or offline image
does not apply the new activators' state; after one, run the complete online
procedure before treating the path unit and timer as armed. Pre-existing
administrator masks are not removed: migration fails closed so the
administrator can retain or review that policy.

The worker also requires the kernel-specific kmod and the `common` package to
have the same EVR. If the new `common` package arrives before its matching
kmod, the queue remains durable and no `depmod`, initramfs, or `ready` state is
published for the old payload. A public legacy installation without a worker
remains worker-free after rollback. An older transactional preview with a
worker stays masked and adoptable until a new compatible transaction completes
recovery.

The common package installs two important configurations:

- a `softdep` to prefer `ov02c10` before `intel_ipu6_isys`;
- a `depmod.d` override to prioritize the packaged module in
  `extra/galaxybook-ov02c10/drivers/media/i2c` over Fedora's in-tree driver.

An RPM `transfiletrigger` reacts when the real kmod is installed, including
when that happens in a later transaction started by `akmods`, but never queries
the RPM database from inside that transaction. It validates the exact regular
path, module name, and vermagic, records a durable request, and starts a
systemd worker outside the transaction. The worker acquires, in order, the
cross-driver global mutex, the OV02C10-private exclusive lifecycle lock, and an
RPM 6-compatible read lock. While holding all three, it migrates legacy files
and requires exactly one payload owned by
`kmod-galaxybook-ov02c10-<kernel>` with matching vermagic. Only then does it
run `depmod`, require `modinfo` to resolve that same payload, rebuild the
initramfs, use `lsinitrd` to reject any in-tree copy, publish the ready state,
and acknowledge the queued request. OV02C10 therefore cannot alter indexes or
initramfs images in parallel with another driver that follows the same
contract. The worker
inhibits shutdown/sleep for the full lifecycle, waits for `akmods.service`,
retries through a path unit and timer, and preserves its queue after failure or
an installation inside a chroot.

A common-package-only update keeps migration queued and preserves the legacy
load configuration until a kernel request proves a valid replacement. The
worker waits up to 600 seconds for both the global mutex and an existing RPM
transaction. Once it owns the read lock, it blocks new RPM writes until
`dracut` completes; during that short window DNF5 can fail immediately instead
of waiting. Wait for the worker and retry the DNF operation in that case.

After verification, the same lifecycle atomically publishes a root-owned
`/var/lib/galaxybook-ov02c10/ready/<kernel>.state` attestation containing
fingerprints of the module and initramfs. The setup only verifies it, and any
later change to either file invalidates it.

The package also migrates legacy files under `/etc/modules-load.d`,
`/etc/modprobe.d`, and `/etc/depmod.d`. It removes an unowned regular file only
when its bytes exactly match a historically generated variant; symlinks and
local customizations are preserved.

If you need to force a module rebuild, use:

```bash
sudo akmods --force --akmod galaxybook-ov02c10 --kernels "$(uname -r)"
sudo /usr/libexec/galaxybook-ov02c10/finalize-kernel --kernel "$(uname -r)"
sudo reboot
```

If DNF, PackageKit, or the transaction log starts showing `depmod` warnings
that mention `/lib/modules/<kernel>/updates/ov02c10.ko`, look for stale module
copies that are not owned by any RPM:

```bash
make cleanup-stale-modules
sudo make cleanup-stale-modules-apply
```

The cleanup target only considers old direct overrides in `updates/` or
`extra/` when they are not owned by any package. Even with `--apply`, it
refuses removal unless the same kernel already has exactly one external
replacement owned by the expected RPM and carrying the correct vermagic.
Fedora's in-tree module and Intel IPU6-packaged modules are left untouched.

The `%post` and `%postun` sections normally generated by `kmodtool` for each
binary kmod are explicit no-ops: they neither run `depmod` nor try to acquire
the global mutex while RPM holds its own lock. On installation, the
`transfiletriggerin` above only queues work for the worker to run after the
transaction. On removal, `%postun` intentionally remains a no-op and the
manual limitation below applies.

Deliberate limitation: exact removal of the binary kmod is **not automatically
supported in this release**. `transfiletriggerpostun` does not provide removed
paths, `%postun` is deliberately a no-op, and the common package that owns the
worker could leave in the same transaction. Keep the common package installed,
and do not treat a manual `dnf`, `depmod`, and `dracut` sequence as coordinated
removal. A future package-owned API must validate module absence and the
pending/ready markers, perform the transaction, and then hold, in order, the
global mutex, private lock, and shared RPM read lock for the complete
post-transaction reconciliation.

### Validation after installation

Before rebooting, the `finalize-kernel` command above is the gate: it succeeds
only when the external module and the initramfs for the **same kernel** are
consistent. After reboot, separate validation into three levels:

```bash
modinfo -n ov02c10
rpm -qf "$(modinfo -n ov02c10)"
lsmod | grep '^ov02c10 '
cam -l
capture_start=$(date --iso-8601=seconds)
timeout 15s cam -c 1 --capture=10
journalctl -b -k --since "$capture_start" | grep -Ei 'ov02c10|frame sync|csi2'
```

The three levels mean:

- **installed**: `modinfo` points to
  `extra/galaxybook-ov02c10/drivers/media/i2c`, and `rpm -qf` returns exactly
  the kmod for the running kernel;
- **registered**: the module is present in `lsmod`, and the camera appears in
  `cam -l`;
- **capturing**: choose the internal camera's number from `cam -l` (the example
  uses `1`). The test must complete with ten frames, each with `bytesused > 0`.
  It does not save images; omit `--file`.

A single sync warning at stream start is not evidence of a dropped frame.
Repeated errors during streaming, empty buffers or a timeout do not count as
a successful test.

If boot still shows:

```text
external clock 26000000 is not supported
probe with driver ov02c10 failed with error -22
```

that log is consistent with the in-tree driver's 26 MHz rejection, but it is
not provenance proof by itself. `modinfo -n` and `rpm -qf` identify the file
on disk, not the module in memory. If the RPM was installed after boot, the
kernel may still be using the previous copy. Additional checks:

```bash
journalctl -b -u akmods --no-pager
sed -n '1,260p' /var/cache/akmods/galaxybook-ov02c10/*.failed.log
```

If packages are installed and `akmods` is healthy, but `modinfo -n ov02c10`
still resolves to `kernel/drivers/...`, the generated `akmods` package probably
does not contain the `kmod-galaxybook-ov02c10-<kernel>` payload. Reinstall the
fixed version, force `akmods` again, and confirm that `modinfo -n ov02c10`
points to an external path before rebooting. The graphical interface also
exposes this flow at:

- <https://github.com/regiscaio/fedora-galaxy-book-setup>

## Secure Boot

If `Secure Boot` is enabled, the system module-signing flow must be configured
for `akmods`. Otherwise the module may build successfully but still be rejected
at boot time.

## Build and maintenance

Build the module for the current kernel:

```bash
make build
```

Run driver, patch, helper, and packaging contract tests:

```bash
make test
```

Regenerate the patch after editing `module/ov02c10.c`:

```bash
make export-patch
```

Refresh the Intel IPU6 base used as reference from the source RPM installed on
the system:

```bash
make refresh-base
```

By default this target reads `/usr/src/akmods/intel-ipu6-kmod.latest`. If you
want to point to another source RPM, use:

```bash
INTEL_IPU6_SRPM=/path/to/intel-ipu6-kmod.src.rpm make refresh-base
```

Generate source RPM and binary RPMs:

```bash
make srpm
make rpm
```

Relevant files:

- RPM spec: [`packaging/fedora/galaxybook-ov02c10-kmod.spec`](packaging/fedora/galaxybook-ov02c10-kmod.spec)
- downstream patch: [`patches/0001-galaxy-book-ov02c10-downstream.patch`](patches/0001-galaxy-book-ov02c10-downstream.patch)
- Intel IPU6 reference base: [`sources/intel-ipu6/ov02c10.c`](sources/intel-ipu6/ov02c10.c)
