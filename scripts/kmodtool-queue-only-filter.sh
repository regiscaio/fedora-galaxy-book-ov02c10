#!/usr/bin/bash
set -euo pipefail

readonly kmodtool_queue_only_success_macro="kmodtool_queue_only_filter_ok"

kmodtool_queue_only_temp_dir=""
kmodtool_queue_only_expected_kernel_string=""
kmodtool_queue_only_kmodname=""
kmodtool_queue_only_target=""
kmodtool_queue_only_command=()

kmodtool_queue_only_fail() {
	printf 'kmodtool-queue-only-filter: %s\n' "$*" >&2
	return 65
}

kmodtool_queue_only_usage() {
	printf '%s\n' \
		'usage: kmodtool-queue-only-filter.sh --expected-kernels "<list>" -- <kmodtool> [arguments]' >&2
	return 64
}

kmodtool_queue_only_parse_invocation() {
	local -a expected_kernels=()
	local -a generated_kernels=()
	local generated_kernel_string=""
	local seen_for_kernels=0
	local seen_kmodname=0
	local seen_target=0
	local index generated_index

	[[ "$#" -ge 4 && "$1" == "--expected-kernels" ]] || \
		kmodtool_queue_only_usage || return
	kmodtool_queue_only_expected_kernel_string="$2"
	shift 2
	[[ "$1" == "--" ]] || kmodtool_queue_only_usage || return
	shift
	[[ "$#" -gt 0 ]] || kmodtool_queue_only_usage || return
	kmodtool_queue_only_command=("$@")

	if [[ ! "$kmodtool_queue_only_expected_kernel_string" =~ ^([A-Za-z0-9][A-Za-z0-9._+-]*(\ +[A-Za-z0-9][A-Za-z0-9._+-]*)*)?$ ]]; then
		printf 'kmodtool-queue-only-filter: invalid expected kernel list\n' >&2
		return 64
	fi
	if [[ -n "$kmodtool_queue_only_expected_kernel_string" ]]; then
		read -r -a expected_kernels <<< "$kmodtool_queue_only_expected_kernel_string"
	fi

	for ((index = 1; index < ${#kmodtool_queue_only_command[@]}; index++)); do
		case "${kmodtool_queue_only_command[index]}" in
			--for-kernels)
				((seen_for_kernels += 1))
				((index + 1 < ${#kmodtool_queue_only_command[@]})) || \
					kmodtool_queue_only_usage || return
				generated_kernel_string="${kmodtool_queue_only_command[index + 1]}"
				((index += 1))
				;;
			--kmodname)
				((seen_kmodname += 1))
				((index + 1 < ${#kmodtool_queue_only_command[@]})) || \
					kmodtool_queue_only_usage || return
				kmodtool_queue_only_kmodname="${kmodtool_queue_only_command[index + 1]}"
				((index += 1))
				;;
			--target)
				((seen_target += 1))
				((index + 1 < ${#kmodtool_queue_only_command[@]})) || \
					kmodtool_queue_only_usage || return
				kmodtool_queue_only_target="${kmodtool_queue_only_command[index + 1]}"
				((index += 1))
				;;
		esac
	done

	((seen_kmodname == 1 && seen_target == 1 && seen_for_kernels <= 1)) || \
		kmodtool_queue_only_usage || return
	[[ "$kmodtool_queue_only_kmodname" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
		kmodtool_queue_only_usage || return
	[[ "$kmodtool_queue_only_target" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || \
		kmodtool_queue_only_usage || return

	if ((${#expected_kernels[@]} == 0)); then
		((seen_for_kernels == 0)) || kmodtool_queue_only_usage || return
	else
		((seen_for_kernels == 1)) || kmodtool_queue_only_usage || return
		[[ "$generated_kernel_string" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*(\ +[A-Za-z0-9][A-Za-z0-9._+-]*)*$ ]] || \
			kmodtool_queue_only_usage || return
		read -r -a generated_kernels <<< "$generated_kernel_string"
		((${#generated_kernels[@]} == ${#expected_kernels[@]})) || \
			kmodtool_queue_only_usage || return
		for generated_index in "${!expected_kernels[@]}"; do
			[[ "${generated_kernels[generated_index]}" == \
				"${expected_kernels[generated_index]}" ]] || \
				kmodtool_queue_only_usage || return
		done
	fi
}

kmodtool_queue_only_validate_ascii_file() {
	local input_file="$1"
	local scratch_file="$2"

	[[ -s "$input_file" ]] || \
		kmodtool_queue_only_fail "system kmodtool produced no output" || return
	LC_ALL=C /usr/bin/tr -d '\011\012\040-\176' \
		< "$input_file" > "$scratch_file"
	[[ ! -s "$scratch_file" ]] || \
		kmodtool_queue_only_fail \
			"system kmodtool output is not canonical ASCII text" || return
	printf '\n' > "$scratch_file"
	/usr/bin/tail -c 1 -- "$input_file" | \
		/usr/bin/cmp -s - "$scratch_file" || \
		kmodtool_queue_only_fail \
			"system kmodtool output is not newline-terminated" || return
}

kmodtool_queue_only_validate_full_contract() {
	local expected_kernel_string="$1"
	local kmodname="$2"
	local target="$3"
	local -n source_lines="$4"
	local kernel kernel_base kernel_versions_line
	local index
	local -a expected_kernels=()
	local -a expected_lines=(
		''
		'%{?rhel:%global with_rhel_kabi 1}'
		''
		'%if 0%{?rhel} || 0%{?fedora}'
		"%global kmod_pkg_name kmod-${kmodname}"
		"%global pkg_kmod_name ${kmodname}-kmod"
		'%{?obsolete_name:%global kmod_obsolete_name kmod-%{obsolete_name}}'
		'%endif'
		''
	)

	if [[ -n "$expected_kernel_string" ]]; then
		read -r -a expected_kernels <<< "$expected_kernel_string"
	fi

	if ((${#expected_kernels[@]} == 0)); then
		expected_lines+=(
			''
			"%global akmod_install mkdir -p \$RPM_BUILD_ROOT/%{_usrsrc}/akmods/; \\rpmbuild --define \"_sourcedir %{_sourcedir}\" \\--define \"_srcrpmdir \$RPM_BUILD_ROOT/%{_usrsrc}/akmods/\" \\%{?dist:--define 'dist %{dist}}' \\-bs --nodeps %{_specdir}/%{name}.spec ; \\ln -s \$(ls \$RPM_BUILD_ROOT/%{_usrsrc}/akmods/) \$RPM_BUILD_ROOT/%{_usrsrc}/akmods/%{pkg_kmod_name}.latest"
			''
			"%package       -n akmod-${kmodname}"
			"Summary:          Akmod package for ${kmodname} kernel module(s)"
			'Requires:         kmodtool'
			'Requires:         akmods'
			'%{?AkmodsBuildRequires:Requires: %{AkmodsBuildRequires}}'
			'# same requires and provides as a kmods package would have'
			'Requires:         %{pkg_kmod_name}-common >= %{?epoch:%{epoch}:}%{version}'
			'Provides:         %{pkg_kmod_name} = %{?epoch:%{epoch}:}%{version}-%{release}'
			''
			"%description   -n akmod-${kmodname}"
			"This package provides the akmod package for the ${kmodname} kernel modules."
			''
			"%posttrans     -n akmod-${kmodname}"
			"nohup /usr/sbin/akmods --from-akmod-posttrans --akmod ${kmodname} &> /dev/null &"
			''
			"%post     -n akmod-${kmodname}"
			"[ -x /usr/sbin/akmods-ostree-post ] && /usr/sbin/akmods-ostree-post ${kmodname} %{_usrsrc}/akmods/%{pkg_kmod_name}-%{version}-%{release}.src.rpm"
			''
			"%files         -n akmod-${kmodname}"
			'%defattr(-,root,root,-)'
			'%{_usrsrc}/akmods/*'
			''
			'%package       -n %{kmod_pkg_name}'
			"Summary:          Metapackage which tracks in ${kmodname} kernel module for newest kernel"
			''
			'Provides:         %{pkg_kmod_name} = %{?epoch:%{epoch}:}%{version}-%{release}'
			'Provides:         %{kmod_pkg_name}-xen = %{?epoch:%{epoch}:}%{version}-%{release}'
			'Provides:         %{kmod_pkg_name}-smp = %{?epoch:%{epoch}:}%{version}-%{release}'
			'Provides:         %{kmod_pkg_name}-PAE = %{?epoch:%{epoch}:}%{version}-%{release}'
			"Requires:         akmod-${kmodname} = %{?epoch:%{epoch}:}%{version}-%{release}"
			''
			'%description   -n %{kmod_pkg_name}'
			'This is a meta-package without payload which sole purpose is to require the'
			"${kmodname} kernel module(s) for the newest kernel,"
			'to make sure you get it together with a new kernel.'
			''
			'%files         -n %{kmod_pkg_name}'
			'%defattr(644,root,root,755)'
		)
	else
		for kernel in "${expected_kernels[@]}"; do
			kernel_base="${kernel%.*}"
			expected_lines+=(
				'%if 0%{?rhel} || 0%{?fedora}'
				"%global kmod_for_kernel %{?with_rhel_kabi:${kernel_base}}%{!?with_rhel_kabi:${kernel}}"
				'%global package_kmod_name %{kmod_pkg_name}-%{kmod_for_kernel}'
				'%endif'
				'%global  _prefix_usr      /usr'
				''
				'%package       -n %{package_kmod_name}'
				"Summary:          ${kmodname} kernel module(s) for %{kmod_for_kernel}"
				"Provides:         kernel-modules%{!?with_rhel_kabi:-for-kernel} = ${kernel}"
				'%if %{with rhel_kabi}'
				'Provides:         installonlypkg(kernel-module)'
				'%endif'
				'Provides:         %{pkg_kmod_name} = %{?epoch:%{epoch}:}%{version}-%{release}'
				'Requires:         %{pkg_kmod_name}-common >= %{?epoch:%{epoch}:}%{version}'
				'Requires(post):   %{?_prefix_usr}/sbin/depmod'
				'Requires(postun): %{?_prefix_usr}/sbin/depmod'
				'%if %{with rhel_kabi}'
				'Requires(post):   %{?_prefix_usr}/sbin/weak-modules'
				'Requires(postun): %{?_prefix_usr}/sbin/weak-modules'
				'%endif'
				"%global _kmodtool_depmod_post \\if [ -f /boot/System.map-${kernel} ] ; then \\  %{?_prefix_usr}/sbin/depmod -aeF /boot/System.map-${kernel} ${kernel} >/dev/null ; \\elif [ -f /lib/modules/${kernel}/System.map ] ; then \\  %{?_prefix_usr}/sbin/depmod -aeF /lib/modules/${kernel}/System.map ${kernel} >/dev/null ; \\else \\  %{?_prefix_usr}/sbin/depmod -a >/dev/null ; \\fi || :"
				''
				'%if %{with rhel_kabi}'
				"Requires:           kernel-uname-r >= ${kernel}"
				'%else'
				"Requires:           kernel-uname-r = ${kernel}"
				'%endif'
				"BuildRequires:  kernel-devel-uname-r = ${kernel}"
				'BuildRequires:  gcc'
				'BuildRequires:  redhat-rpm-config'
				''
				''
				'%post          -n %{package_kmod_name}'
				'%{_kmodtool_depmod_post}'
				''
				'%if %{with rhel_kabi}'
				"modules=( \$(find /lib/modules/${kernel}/extra/${kmodname}/ -name \"*.ko\"  -o -name \"*.ko.xz\") )"
				"printf '%s\\n' \"\${modules[@]}\" | %{?_prefix_usr}/sbin/weak-modules --add-modules"
				'%endif'
				''
				'%if %{with rhel_kabi}'
				'%preun         -n %{package_kmod_name}'
				"rpm -ql %{package_kmod_name}-%{version}-%{release}.${target} | grep -e '\\.ko\$' -e '\\.ko.xz\$' > /var/run/rpm-%{package_kmod_name}-modules"
				'%endif'
				''
				'%postun        -n %{package_kmod_name}'
				'%{_kmodtool_depmod_post}'
				''
				'%if %{with rhel_kabi}'
				'modules=( $(cat /var/run/rpm-%{package_kmod_name}-modules) )'
				'rm -f /var/run/rpm-%{package_kmod_name}-modules'
				"printf '%s\\n' \"\${modules[@]}\" | %{?_prefix_usr}/sbin/weak-modules --remove-modules"
				'%endif'
				''
				'%description   -n %{package_kmod_name}'
				"This package provides the ${kmodname} kernel modules built for the Linux"
				'kernel %{kmod_for_kernel} for the %{_target_cpu} family of processors.'
				'%files         -n %{package_kmod_name}'
				'%defattr(644,root,root,755)'
				"%dir /lib/modules/${kernel}/extra"
				"/lib/modules/${kernel}/extra/${kmodname}/"
				''
				"%global __kmodtool_kernel_uname_r ${kernel}"
				'%global __spec_install_post \'
				'  %{?__debug_package:%{__debug_install_post}}\'
				'  %{__arch_install_post}\'
				'  %{__os_install_post}\'
				'  %{?__kmodtool_signmodules:%{__kmodtool_modsign_install_post}}\'
				'  %{?__kmodtool_zipmodules:%{__kmodtool_modzip_install_post}}'
				''
			)
		done
		expected_lines+=(
			'%global kmodinstdir_prefix  /lib/modules/'
			"%global kmodinstdir_postfix /extra/${kmodname}/"
		)
		kernel_versions_line='%global kernel_versions    '
		for kernel in "${expected_kernels[@]}"; do
			kernel_versions_line+=" ${kernel}___%{_usrsrc}/kernels/${kernel}"
		done
		expected_lines+=("${kernel_versions_line}" '')
	fi

	if ((${#source_lines[@]} != ${#expected_lines[@]})); then
		kmodtool_queue_only_fail \
			"system kmodtool full template changed (unexpected line count)"
		return
	fi
	for index in "${!expected_lines[@]}"; do
		if [[ "${source_lines[index]}" != "${expected_lines[index]}" ]]; then
			kmodtool_queue_only_fail \
				"system kmodtool full template changed at line $((index + 1))"
			return
		fi
	done
}

kmodtool_queue_only_validate_exact_block() {
	local start_index="$1"
	local kernel="$2"
	local kmodname="$3"
	local target="$4"
	local -n source_lines="$5"
	local expected_index
	local -a expected_lines=(
		'%post          -n %{package_kmod_name}'
		'%{_kmodtool_depmod_post}'
		''
		'%if %{with rhel_kabi}'
		"modules=( \$(find /lib/modules/${kernel}/extra/${kmodname}/ -name \"*.ko\"  -o -name \"*.ko.xz\") )"
		"printf '%s\\n' \"\${modules[@]}\" | %{?_prefix_usr}/sbin/weak-modules --add-modules"
		'%endif'
		''
		'%if %{with rhel_kabi}'
		'%preun         -n %{package_kmod_name}'
		"rpm -ql %{package_kmod_name}-%{version}-%{release}.${target} | grep -e '\\.ko\$' -e '\\.ko.xz\$' > /var/run/rpm-%{package_kmod_name}-modules"
		'%endif'
		''
		'%postun        -n %{package_kmod_name}'
		'%{_kmodtool_depmod_post}'
		''
		'%if %{with rhel_kabi}'
		'modules=( $(cat /var/run/rpm-%{package_kmod_name}-modules) )'
		'rm -f /var/run/rpm-%{package_kmod_name}-modules'
		"printf '%s\\n' \"\${modules[@]}\" | %{?_prefix_usr}/sbin/weak-modules --remove-modules"
		'%endif'
		''
		'%description   -n %{package_kmod_name}'
	)

	for expected_index in "${!expected_lines[@]}"; do
		if ((start_index + expected_index >= ${#source_lines[@]})) ||
			[[ "${source_lines[start_index + expected_index]}" != \
				"${expected_lines[expected_index]}" ]]; then
			kmodtool_queue_only_fail \
				"system kmodtool exact scriptlet body changed for ${kernel}"
			return
		fi
	done
}

kmodtool_queue_only_validate_akmod_block() {
	local start_index="$1"
	local kmodname="$2"
	local -n source_lines="$3"
	local expected_index
	local -a expected_lines=(
		"%posttrans     -n akmod-${kmodname}"
		"nohup /usr/sbin/akmods --from-akmod-posttrans --akmod ${kmodname} &> /dev/null &"
		''
		"%post     -n akmod-${kmodname}"
		"[ -x /usr/sbin/akmods-ostree-post ] && /usr/sbin/akmods-ostree-post ${kmodname} %{_usrsrc}/akmods/%{pkg_kmod_name}-%{version}-%{release}.src.rpm"
		''
		"%files         -n akmod-${kmodname}"
	)

	for expected_index in "${!expected_lines[@]}"; do
		if ((start_index + expected_index >= ${#source_lines[@]})) ||
			[[ "${source_lines[start_index + expected_index]}" != \
				"${expected_lines[expected_index]}" ]]; then
			kmodtool_queue_only_fail \
				"system kmodtool akmod scriptlet body changed"
			return
		fi
	done
}

kmodtool_queue_only_is_scriptlet_header() {
	local line="$1"

	[[ "$line" =~ ^[[:space:]]*%(pre|post)(un|trans|untrans)?([[:space:]]|$) ]] ||
		[[ "$line" =~ ^[[:space:]]*%(trigger|filetrigger|transfiletrigger)(prein|in|un|postun)?([[:space:]]|$) ]] ||
		[[ "$line" =~ ^[[:space:]]*%verifyscript([[:space:]]|$) ]]
}

kmodtool_queue_only_filter() {
	local expected_kernel_string="$1"
	local kmodname="$2"
	local target="$3"
	local line expected_macro expected_index
	local index
	local -a expected_kernels=()
	local -a input_lines=()
	local -a output_lines=()
	local expected_packages=0
	local package_count=0
	local package_name_macro_count=0
	local post_count=0
	local postun_count=0
	local post_requires_count=0
	local postun_requires_count=0
	local weak_requires_block_count=0
	local depmod_macro_count=0
	local depmod_invocation_count=0
	local base_prefix_count=0
	local base_postfix_count=0
	local base_kernel_versions_count=0
	local base_kmod_name_count=0
	local base_pkg_kmod_name_count=0
	local expected_base_header_count=1
	local akmod_post_count=0
	local akmod_posttrans_count=0

	if [[ -n "$expected_kernel_string" ]]; then
		read -r -a expected_kernels <<< "$expected_kernel_string"
	fi
	expected_packages="${#expected_kernels[@]}"
	mapfile -t input_lines
	((${#input_lines[@]} > 0)) || \
		kmodtool_queue_only_fail "system kmodtool produced no output" || return
	kmodtool_queue_only_validate_full_contract \
		"$expected_kernel_string" "$kmodname" "$target" input_lines || return

	for ((index = 0; index < ${#input_lines[@]}; index++)); do
		line="${input_lines[index]}"
		if [[ "$line" == *"${kmodtool_queue_only_success_macro}"* ]]; then
			kmodtool_queue_only_fail "system kmodtool output forged the success marker"
			return
		fi
		if [[ "$line" == "%posttrans     -n akmod-${kmodname}" ]]; then
			((expected_packages == 0 && akmod_posttrans_count == 0)) || \
				kmodtool_queue_only_fail \
					"system kmodtool emitted an unexpected akmod scriptlet" || return
			kmodtool_queue_only_validate_akmod_block \
				"$index" "$kmodname" input_lines || return
			for ((expected_index = 0; expected_index < 6; expected_index++)); do
				output_lines+=("${input_lines[index + expected_index]}")
			done
			((akmod_posttrans_count += 1))
			((akmod_post_count += 1))
			((index += 5))
			continue
		fi
		[[ "$line" =~ ^%global[[:space:]]+kmodinstdir_prefix[[:space:]] ]] && \
			((base_prefix_count += 1))
		[[ "$line" =~ ^%global[[:space:]]+kmodinstdir_postfix[[:space:]] ]] && \
			((base_postfix_count += 1))
		[[ "$line" =~ ^%global[[:space:]]+kernel_versions[[:space:]] ]] && \
			((base_kernel_versions_count += 1))
		[[ "$line" =~ ^%global[[:space:]]+kmod_pkg_name[[:space:]] ]] && \
			((base_kmod_name_count += 1))
		[[ "$line" =~ ^%global[[:space:]]+pkg_kmod_name[[:space:]] ]] && \
			((base_pkg_kmod_name_count += 1))
		[[ "$line" =~ ^%global[[:space:]]+package_kmod_name[[:space:]] ]] && \
			((package_name_macro_count += 1))
		[[ "$line" =~ ^%package[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}[[:space:]]*$ ]] && \
			((package_count += 1))
		if [[ "$line" == '%if %{with rhel_kabi}' &&
			"${input_lines[index + 1]:-}" == 'Requires(post):   %{?_prefix_usr}/sbin/weak-modules' &&
			"${input_lines[index + 2]:-}" == 'Requires(postun): %{?_prefix_usr}/sbin/weak-modules' &&
			"${input_lines[index + 3]:-}" == '%endif' ]]; then
			((weak_requires_block_count += 1))
			((index += 3))
			continue
		fi
		if [[ "$line" =~ ^%post[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}[[:space:]]*$ ]]; then
			((post_count < expected_packages)) || \
				kmodtool_queue_only_fail "system kmodtool emitted an extra exact post scriptlet" || return
			kmodtool_queue_only_validate_exact_block "$index" \
				"${expected_kernels[post_count]}" "$kmodname" "$target" input_lines || return
			output_lines+=(
				'%post          -n %{package_kmod_name}'
				':'
				''
				'%postun        -n %{package_kmod_name}'
				':'
				''
			)
			((post_count += 1))
			((postun_count += 1))
			((depmod_invocation_count += 2))
			((index += 21))
			continue
		fi

		if [[ "$line" =~ ^Requires\(post\):[[:space:]]+%\{\?_prefix_usr\}/sbin/depmod[[:space:]]*$ ]]; then
			((post_requires_count += 1))
			continue
		fi
		if [[ "$line" =~ ^Requires\(postun\):[[:space:]]+%\{\?_prefix_usr\}/sbin/depmod[[:space:]]*$ ]]; then
			((postun_requires_count += 1))
			continue
		fi
		if [[ "$line" =~ ^%global[[:space:]]+_kmodtool_depmod_post[[:space:]] ]]; then
			((depmod_macro_count < expected_packages)) || \
				kmodtool_queue_only_fail "system kmodtool emitted an extra depmod macro" || return
			expected_macro="%global _kmodtool_depmod_post \\if [ -f /boot/System.map-${expected_kernels[depmod_macro_count]} ] ; then \\  %{?_prefix_usr}/sbin/depmod -aeF /boot/System.map-${expected_kernels[depmod_macro_count]} ${expected_kernels[depmod_macro_count]} >/dev/null ; \\elif [ -f /lib/modules/${expected_kernels[depmod_macro_count]}/System.map ] ; then \\  %{?_prefix_usr}/sbin/depmod -aeF /lib/modules/${expected_kernels[depmod_macro_count]}/System.map ${expected_kernels[depmod_macro_count]} >/dev/null ; \\else \\  %{?_prefix_usr}/sbin/depmod -a >/dev/null ; \\fi || :"
			[[ "$line" == "$expected_macro" ]] || \
				kmodtool_queue_only_fail \
					"system kmodtool depmod macro body changed for ${expected_kernels[depmod_macro_count]}" || return
			((depmod_macro_count += 1))
			continue
		fi
		if [[ "$line" =~ [Dd][Ee][Pp][Mm][Oo][Dd] ]] ||
			[[ "$line" == *weak-modules* ]]; then
			kmodtool_queue_only_fail "unrecognized lifecycle mutation in system kmodtool output"
			return
		fi
		if kmodtool_queue_only_is_scriptlet_header "$line"; then
			kmodtool_queue_only_fail \
				"system kmodtool emitted an unexpected scriptlet"
			return
		fi
		output_lines+=("$line")
	done

	((expected_packages == 0)) && expected_base_header_count=0
	if ((base_prefix_count != expected_base_header_count ||
		base_postfix_count != expected_base_header_count ||
		base_kernel_versions_count != expected_base_header_count ||
		base_kmod_name_count != 1 ||
		base_pkg_kmod_name_count != 1)); then
		kmodtool_queue_only_fail "system kmodtool base contract changed"
		return
	fi

	if ((package_count != expected_packages ||
		package_name_macro_count != expected_packages ||
		post_count != expected_packages ||
		postun_count != expected_packages ||
		post_requires_count != expected_packages ||
		postun_requires_count != expected_packages ||
		weak_requires_block_count != expected_packages ||
		depmod_macro_count != expected_packages ||
		depmod_invocation_count != 2 * expected_packages ||
		akmod_post_count != (expected_packages == 0 ? 1 : 0) ||
		akmod_posttrans_count != (expected_packages == 0 ? 1 : 0))); then
		kmodtool_queue_only_fail \
			"system kmodtool exact-package contract changed (expected ${expected_packages})"
		return
	fi

	for line in "${output_lines[@]}"; do
		if [[ "$line" =~ [Dd][Ee][Pp][Mm][Oo][Dd] ]] ||
			[[ "$line" == *weak-modules* ]] ||
			[[ "$line" =~ ^%preun[[:space:]]+-n[[:space:]]+%\{package_kmod_name\} ]]; then
			kmodtool_queue_only_fail "filtered output retained a mutating scriptlet dependency"
			return
		fi
	done

	local filtered_exact_header_count=0
	local filtered_akmod_header_count=0
	for ((index = 0; index < ${#output_lines[@]}; index++)); do
		line="${output_lines[index]}"
		if [[ "$line" =~ ^%(post|postun)[[:space:]]+-n[[:space:]]+%\{package_kmod_name\}[[:space:]]*$ ]]; then
			((index + 2 < ${#output_lines[@]})) || \
				kmodtool_queue_only_fail "filtered exact scriptlet is truncated" || return
			[[ "${output_lines[index + 1]}" == ':' &&
				-z "${output_lines[index + 2]}" ]] || \
				kmodtool_queue_only_fail \
					"filtered exact scriptlet is not a single no-op" || return
			((filtered_exact_header_count += 1))
		elif [[ "$line" == "%posttrans     -n akmod-${kmodname}" ]]; then
			((expected_packages == 0 && filtered_akmod_header_count == 0)) || \
				kmodtool_queue_only_fail \
					"filtered output retained an unexpected akmod scriptlet" || return
			kmodtool_queue_only_validate_akmod_block \
				"$index" "$kmodname" output_lines || return
			((filtered_akmod_header_count += 2))
			((index += 5))
		elif kmodtool_queue_only_is_scriptlet_header "$line"; then
			kmodtool_queue_only_fail \
				"filtered output retained an unexpected scriptlet"
			return
		fi
	done
	((filtered_exact_header_count == 2 * expected_packages)) || \
		kmodtool_queue_only_fail \
			"filtered output has an unexpected exact scriptlet count" || return
	((filtered_akmod_header_count == (expected_packages == 0 ? 2 : 0))) || \
		kmodtool_queue_only_fail \
			"filtered output has an unexpected akmod scriptlet count" || return

	printf '%s\n' "${output_lines[@]}"
}

kmodtool_queue_only_cleanup() {
	if [[ -n "$kmodtool_queue_only_temp_dir" ]]; then
		/usr/bin/rm -f -- \
			"${kmodtool_queue_only_temp_dir}/command.stdout" \
			"${kmodtool_queue_only_temp_dir}/command.stderr" \
			"${kmodtool_queue_only_temp_dir}/filter.stdout" \
			"${kmodtool_queue_only_temp_dir}/filter.stderr" \
			"${kmodtool_queue_only_temp_dir}/scratch"
		/usr/bin/rmdir -- "$kmodtool_queue_only_temp_dir"
	fi
}

kmodtool_queue_only_replay_errors() {
	/usr/bin/cat -- "${kmodtool_queue_only_temp_dir}/command.stderr" >&2
	[[ ! -e "${kmodtool_queue_only_temp_dir}/filter.stderr" ]] || \
		/usr/bin/cat -- "${kmodtool_queue_only_temp_dir}/filter.stderr" >&2
}

kmodtool_queue_only_main() {
	local command_status
	local filter_status=0

	kmodtool_queue_only_parse_invocation "$@" || return
	umask 077
	kmodtool_queue_only_temp_dir="$(/usr/bin/mktemp -d \
		--tmpdir kmodtool-queue-only.XXXXXXXXXX)" || {
		printf 'kmodtool-queue-only-filter: could not create output buffer\n' >&2
		return 70
	}
	trap kmodtool_queue_only_cleanup EXIT

	if "${kmodtool_queue_only_command[@]}" \
		> "${kmodtool_queue_only_temp_dir}/command.stdout" \
		2> "${kmodtool_queue_only_temp_dir}/command.stderr"
	then
		command_status=0
	else
		command_status=$?
	fi
	if ((command_status != 0)); then
		kmodtool_queue_only_replay_errors
		return "$command_status"
	fi
	if [[ -s "${kmodtool_queue_only_temp_dir}/command.stderr" ]]; then
		kmodtool_queue_only_replay_errors
		kmodtool_queue_only_fail "system kmodtool wrote diagnostics with status zero"
		return 65
	fi

	kmodtool_queue_only_validate_ascii_file \
		"${kmodtool_queue_only_temp_dir}/command.stdout" \
		"${kmodtool_queue_only_temp_dir}/scratch" \
		2> "${kmodtool_queue_only_temp_dir}/filter.stderr" || {
		filter_status=$?
		kmodtool_queue_only_replay_errors
		return "$filter_status"
	}

	kmodtool_queue_only_filter \
		"$kmodtool_queue_only_expected_kernel_string" \
		"$kmodtool_queue_only_kmodname" \
		"$kmodtool_queue_only_target" \
		< "${kmodtool_queue_only_temp_dir}/command.stdout" \
		> "${kmodtool_queue_only_temp_dir}/filter.stdout" \
		2> "${kmodtool_queue_only_temp_dir}/filter.stderr" || {
		filter_status=$?
		kmodtool_queue_only_replay_errors
		return "$filter_status"
	}
	printf '%%global %s 1\n' "$kmodtool_queue_only_success_macro" \
		>> "${kmodtool_queue_only_temp_dir}/filter.stdout"

	kmodtool_queue_only_validate_ascii_file \
		"${kmodtool_queue_only_temp_dir}/filter.stdout" \
		"${kmodtool_queue_only_temp_dir}/scratch" \
		2> "${kmodtool_queue_only_temp_dir}/filter.stderr" || {
		filter_status=$?
		kmodtool_queue_only_replay_errors
		return "$filter_status"
	}

	/usr/bin/cat -- "${kmodtool_queue_only_temp_dir}/filter.stdout"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	kmodtool_queue_only_main "$@"
fi
