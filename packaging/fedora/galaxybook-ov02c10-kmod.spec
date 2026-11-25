%global debug_package %{nil}
%global prjname galaxybook-ov02c10
%global pkg_version %{?pkg_version_override}%{!?pkg_version_override:1.0.0}
%global source_date_epoch_from_changelog 0
%global clamp_mtime_to_source_date_epoch 1
%{!?_depmoddir:%global _depmoddir %{_prefix}/lib/depmod.d}
%global finalizer_interpreter /usr/bin/env -i PATH=/usr/bin:/usr/sbin GALAXYBOOK_FINALIZER_FAMILY=ov02c10 GALAXYBOOK_FINALIZER_COMMON_PACKAGE=galaxybook-ov02c10-kmod-common GALAXYBOOK_FINALIZER_OWN_FLOOR=0:1.00.25-0 GALAXYBOOK_FINALIZER_PEER_PACKAGE=galaxybook-max98390-kmod-common GALAXYBOOK_FINALIZER_PEER_FLOOR=0:1.00.12-0 GALAXYBOOK_FINALIZER_SETUP_PACKAGE=galaxybook-setup GALAXYBOOK_FINALIZER_SETUP_FLOOR=0:1.00.48-0 GALAXYBOOK_FINALIZER_ACTIVATOR_UNITS=galaxybook-ov02c10-finalize.path:galaxybook-ov02c10-finalize.timer GALAXYBOOK_FINALIZER_DEPENDENT_UNITS=- GALAXYBOOK_FINALIZER_SERVICE_UNIT=galaxybook-ov02c10-finalize.service GALAXYBOOK_FINALIZER_PENDING_DIRECTORY=/var/lib/galaxybook-ov02c10/pending GALAXYBOOK_FINALIZER_RECOVERY_UNIT=galaxybook-ov02c10-finalizer-transaction-recovery.service GALAXYBOOK_FINALIZER_STATE_DIRECTORY=/run/galaxybook-ov02c10-finalizer-transaction GALAXYBOOK_FINALIZER_SERVICE_CGROUP=/sys/fs/cgroup/system.slice/galaxybook-ov02c10-finalize.service/cgroup.procs /usr/bin/bash --noprofile --norc

Name:           %{prjname}-kmod
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        Intel IPU6-aligned OV02C10 camera driver for Samsung Galaxy Book on Fedora
License:        GPL-2.0-only
URL:            https://github.com/regiscaio/fedora-galaxy-book-ov02c10
Source0:        %{name}-%{version}.tar.gz
Source1:        kmodtool-queue-only-filter.sh
Source2:        finalizer-transaction.sh
Source3:        finalizer-transaction-pretrans.sh

ExclusiveArch:  x86_64

BuildRequires:  akmods
BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  diffutils
BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  kmodtool
BuildRequires:  make
BuildRequires:  systemd-rpm-macros

%undefine kmodtool_queue_only_filter_ok
%{expand:%(/usr/bin/bash "%{SOURCE1}" --expected-kernels "%{?kernels}" -- /usr/bin/kmodtool --target %{_target_cpu} --repo fedora --kmodname %{prjname} --akmod %{?kernels:--for-kernels "%{?kernels}"})}
%{!?kmodtool_queue_only_filter_ok:%{error:kmodtool queue-only filtering failed}}
%undefine kmodtool_queue_only_filter_ok

%description
This package carries the OV02C10 sensor driver aligned with the Intel IPU6
stack used on Fedora, plus the minimal downstream metadata needed for Samsung
Galaxy Book systems. It is meant to be shipped as an akmod on Fedora so the
module stays in sync with the installed Intel IPU6 userspace and kernel stack.

%package -n %{pkg_kmod_name}-common
Summary:        Common files for the %{prjname} kernel module packaging
Requires:       bash
Requires:       coreutils
Requires:       diffutils
Requires:       dracut
Requires:       findutils
Requires:       kmod
Requires:       rpm
Requires:       systemd
Requires:       util-linux-core
Requires:       (galaxybook-max98390-kmod-common >= 1.00.12 if galaxybook-max98390-kmod-common)
Requires:       (galaxybook-setup >= 1.00.48 if galaxybook-setup)
Requires(pretrans): bash
Requires(pretrans): coreutils
Requires(pretrans): diffutils
Requires(pretrans): rpm
Requires(pretrans): systemd
Requires(pretrans): util-linux-core
Requires(posttrans): diffutils
%{?systemd_requires}

%description -n %{pkg_kmod_name}-common
Common documentation and licensing files for the %{prjname} kernel module
packaging.

%prep
%setup -q -n %{name}-%{version}

%build
for kernel_version in %{?kernel_versions}; do
  cp -a module _kmod_build_${kernel_version%%___*}
  make -C ${kernel_version##*___} M=${PWD}/_kmod_build_${kernel_version%%___*} modules
done

%install
install -d %{buildroot}%{_datadir}/doc/%{pkg_kmod_name}
install -m 0644 README.md %{buildroot}%{_datadir}/doc/%{pkg_kmod_name}/README.md
install -d %{buildroot}%{_datadir}/licenses/%{name}
install -m 0644 LICENSE %{buildroot}%{_datadir}/licenses/%{name}/LICENSE
install -Dm0644 data/modprobe.d/galaxybook-ov02c10.conf \
  %{buildroot}%{_modprobedir}/galaxybook-ov02c10.conf
install -Dm0644 data/depmod.d/galaxybook-ov02c10.conf \
  %{buildroot}%{_depmoddir}/galaxybook-ov02c10.conf
install -Dm0755 scripts/finalize-kernel.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/finalize-kernel
install -Dm0755 scripts/finalize-pending.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/finalize-pending
install -Dm0755 %{SOURCE2} \
  %{buildroot}%{_libexecdir}/%{prjname}/finalizer-transaction
install -Dm0755 scripts/migrate-legacy-config.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/migrate-legacy-config
install -Dm0755 scripts/cleanup-stale-modules.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/cleanup-stale-modules
install -Dm0755 scripts/queue-finalization.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/queue-finalization
install -Dm0644 scripts/rpm-file-owner.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/rpm-file-owner.sh
install -Dm0644 scripts/rpm-read-lock.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/rpm-read-lock.sh
install -Dm0644 scripts/kmod-lifecycle-lock.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/kmod-lifecycle-lock.sh
install -Dm0644 scripts/lifecycle-lock.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/lifecycle-lock.sh
install -Dm0644 scripts/state-directory.sh \
  %{buildroot}%{_libexecdir}/%{prjname}/state-directory.sh
install -Dm0644 data/systemd/galaxybook-ov02c10-finalize.service \
  %{buildroot}%{_unitdir}/galaxybook-ov02c10-finalize.service
install -Dm0644 data/systemd/galaxybook-ov02c10-finalize.path \
  %{buildroot}%{_unitdir}/galaxybook-ov02c10-finalize.path
install -Dm0644 data/systemd/galaxybook-ov02c10-finalize.timer \
  %{buildroot}%{_unitdir}/galaxybook-ov02c10-finalize.timer
install -Dm0644 data/systemd/90-galaxybook-ov02c10.preset \
  %{buildroot}%{_presetdir}/90-galaxybook-ov02c10.preset
install -d -m 0755 \
  %{buildroot}%{_sharedstatedir}/galaxybook-ov02c10/pending
install -d -m 0755 \
  %{buildroot}%{_sharedstatedir}/galaxybook-ov02c10/ready

for kernel_version in %{?kernel_versions}; do
  install -Dm0644 _kmod_build_${kernel_version%%___*}/ov02c10.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/drivers/media/i2c/ov02c10.ko
done

%{?akmod_install}

%post -n %{pkg_kmod_name}-common
%systemd_post galaxybook-ov02c10-finalize.path galaxybook-ov02c10-finalize.timer

%pretrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}" -f %{SOURCE3}

%preun -n %{pkg_kmod_name}-common
%systemd_preun galaxybook-ov02c10-finalize.path galaxybook-ov02c10-finalize.timer

%postun -n %{pkg_kmod_name}-common
%systemd_postun galaxybook-ov02c10-finalize.path galaxybook-ov02c10-finalize.timer

%posttrans -n %{pkg_kmod_name}-common -p "%{finalizer_interpreter}"
%{_libexecdir}/%{prjname}/queue-finalization --migration
%{_libexecdir}/%{prjname}/finalizer-transaction --posttrans "$1"

%transfiletriggerin -n %{pkg_kmod_name}-common -p /usr/bin/bash -- /lib/modules /usr/lib/modules
%{_libexecdir}/%{prjname}/queue-finalization --from-rpm-trigger

%files -n %{pkg_kmod_name}-common
%{_datadir}/doc/%{pkg_kmod_name}/README.md
%license %{_datadir}/licenses/%{name}/LICENSE
%{_modprobedir}/galaxybook-ov02c10.conf
%{_depmoddir}/galaxybook-ov02c10.conf
%dir %{_libexecdir}/%{prjname}
%{_libexecdir}/%{prjname}/cleanup-stale-modules
%{_libexecdir}/%{prjname}/finalize-kernel
%{_libexecdir}/%{prjname}/finalize-pending
%{_libexecdir}/%{prjname}/finalizer-transaction
%{_libexecdir}/%{prjname}/migrate-legacy-config
%{_libexecdir}/%{prjname}/queue-finalization
%{_libexecdir}/%{prjname}/rpm-file-owner.sh
%{_libexecdir}/%{prjname}/rpm-read-lock.sh
%{_libexecdir}/%{prjname}/kmod-lifecycle-lock.sh
%{_libexecdir}/%{prjname}/lifecycle-lock.sh
%{_libexecdir}/%{prjname}/state-directory.sh
%{_unitdir}/galaxybook-ov02c10-finalize.path
%{_unitdir}/galaxybook-ov02c10-finalize.service
%{_unitdir}/galaxybook-ov02c10-finalize.timer
%{_presetdir}/90-galaxybook-ov02c10.preset
%dir %{_sharedstatedir}/galaxybook-ov02c10
%dir %{_sharedstatedir}/galaxybook-ov02c10/pending
%dir %{_sharedstatedir}/galaxybook-ov02c10/ready

%changelog
