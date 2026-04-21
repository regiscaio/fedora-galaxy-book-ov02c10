%global debug_package %{nil}
%global prjname galaxybook-ov02c10
%global pkg_version %{?pkg_version_override}%{!?pkg_version_override:1.0.0}
%global source_date_epoch_from_changelog 0

Name:           %{prjname}-kmod
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        Intel IPU6-aligned OV02C10 camera driver for Samsung Galaxy Book on Fedora
License:        GPL-2.0-only
URL:            https://github.com/regiscaio/fedora-galaxy-book-ov02c10
Source0:        %{name}-%{version}.tar.gz

ExclusiveArch:  x86_64

BuildRequires:  akmods
BuildRequires:  elfutils-libelf-devel
BuildRequires:  gcc
BuildRequires:  kmodtool
BuildRequires:  make

%{expand:%(kmodtool --target %{_target_cpu} --repo fedora --kmodname %{prjname} --akmod 2>/dev/null)}

%description
This package carries the OV02C10 sensor driver aligned with the Intel IPU6
stack used on Fedora, plus the minimal downstream metadata needed for Samsung
Galaxy Book systems. It is meant to be shipped as an akmod on Fedora so the
module stays in sync with the installed Intel IPU6 userspace and kernel stack.

%package -n %{pkg_kmod_name}-common
Summary:        Common files for the %{prjname} kernel module packaging

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
install -Dm0644 data/modules-load.d/galaxybook-ov02c10.conf \
  %{buildroot}%{_modulesloaddir}/galaxybook-ov02c10.conf
install -Dm0644 data/modprobe.d/galaxybook-ov02c10.conf \
  %{buildroot}%{_modprobedir}/galaxybook-ov02c10.conf

for kernel_version in %{?kernel_versions}; do
  install -Dm755 _kmod_build_${kernel_version%%___*}/ov02c10.ko \
    %{buildroot}%{kmodinstdir_prefix}/${kernel_version%%___*}/%{kmodinstdir_postfix}/drivers/media/i2c/ov02c10.ko
done

%{?akmod_install}

%files -n %{pkg_kmod_name}-common
%{_datadir}/doc/%{pkg_kmod_name}/README.md
%license %{_datadir}/licenses/%{name}/LICENSE
%{_modulesloaddir}/galaxybook-ov02c10.conf
%{_modprobedir}/galaxybook-ov02c10.conf

%changelog
