#!/bin/bash
#
# Copyright (C) 2016-2019 Michael Jeanson <mjeanson@efficios.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

set -exu

# Parameters
platforms=${platforms:-}
# Derive arch from label if it isn't set
if [ -z "${arch:-}" ] ; then
    # Labels may be platform specific, eg. jammy-amd64, deb12-armhf
    regex='[[:alnum:]]+-([[:alnum:]]+)'
    if [[ "${platforms}" =~ ${regex} ]] ; then
        arch="${BASH_REMATCH[1]}"
    else
        arch="${platforms:-}"
    fi
fi

cross_arch=${cross_arch:-}
ktag=${ktag:-}
kgitrepo=${kgitrepo:-}
mversion=${mversion:-}
mgitrepo=${mgitrepo:-}
make_args=()

DEBUG=${DEBUG:-}

## FUNCTIONS ##

# Kernel version compare functions
verlte() {
    [  "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" ]
}

verlt() {
    # shellcheck disable=SC2015
    [ "$1" = "$2" ] && return 1 || verlte "$1" "$2"
}

vergte() {
    [  "$1" = "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -n1)" ]
}

vergt() {
    # shellcheck disable=SC2015
    [ "$1" = "$2" ] && return 1 || vergte "$1" "$2"
}

git_clone_modules_sources() {
    mkdir -p "$MODULES_GIT_DIR"

    # If the version starts with "refs/", checkout the specific git ref, otherwise treat it
    # as a branch name.
    if [ "${mversion:0:5}" = "refs/" ]; then
        git clone --no-tags --depth=1 "${mgitrepo}" "$MODULES_GIT_DIR"
        (cd "$MODULES_GIT_DIR" && git fetch origin "${mversion}" && git checkout FETCH_HEAD)
    else
        git clone --no-tags --depth=1 -b "${mversion}" "${mgitrepo}" "$MODULES_GIT_DIR"
    fi
}

# Checkout a shallow kernel tree of the specified tag
git_clone_linux_sources() {
    mkdir -p "$LINUX_GIT_DIR"
    git clone --depth=1 -b "${ktag}" --reference "$LINUX_GIT_REF_REPO_DIR" "${kgitrepo}" "$LINUX_GIT_DIR"
}


# Export the kernel sources from the git repo
git_export_linux_sources() {
    cd "$LINUX_GIT_DIR"
    git archive "${ktag}" | tar -x -C "$LINUX_SRCOBJ_DIR"
}


# Upload the tar archive to the object store
upload_archive_obj() {
    s3cmd -c "$WORKSPACE/.s3cfg" put "$WORKSPACE/$obj_name" "$obj_url_prefix/"
    rm -f "$WORKSPACE/$obj_name"
}


extract_archive_obj() {
    tar -xf "$WORKSPACE/$obj_name" -C "$LINUX_OBJ_DIR" -I pbzip2
    rm -f "$WORKSPACE/$obj_name"
}


tar_archive_obj() {
    cd "$LINUX_OBJ_DIR"
    tar -cf "$WORKSPACE/$obj_name" -I pbzip2 .
    cd -
}

list_gccs() {
    local gccs
    gccs=()
    IFS=: read -r -a path_array <<< "$PATH"
    while read -r gcc ; do
        gccs+=("$gcc")
    done < <(find "${path_array[@]}" -maxdepth 1 -regex '.*/gcc-[0-9\.]+$' -printf '%f\n' | sort -t- -k2 -V -r)
    echo "${gccs[@]}"
}

# Find the most recent GCC version supported by the kernel sources
select_compiler() {
    local selected_cc

    cd "$LINUX_SRCOBJ_DIR"

    kversion=$(make -s kernelversion)

    set +e

    for cc in $(list_gccs) ; do
        if "${CROSS_COMPILE:-}${cc}" -I include/ -D__LINUX_COMPILER_H -D__LINUX_COMPILER_TYPES_H -E include/linux/compiler-gcc.h; then
            cc_version=$(echo "${cc}" | cut -d'-' -f2)
            if { verlt "${kversion}" "5.17"; } && { vergt "${cc_version}" "11"; } ; then
                # Using gcc-12+ with '-Wuse-after-free' breaks the build of older
                # kernels (in particular, objtool). Some releases on LTS
                # branches between 4.x and 5.15 can be built with gcc-12.
                # @see https://lore.kernel.org/lkml/20494.1643237814@turing-police/
                # @see https://gitlab.com/linux-kernel/stable/-/commit/52a9dab6d892763b2a8334a568bd4e2c1a6fde66
                continue
            fi
        selected_cc="$cc"
        break
      fi
    done

    set -e

    # Force gcc-4.8 for kernels before 4.4
    if { verlt "$kversion" "4.4"; }; then
        selected_cc='gcc-4.8'
    fi

    if [ -z "$selected_cc" ]; then
      echo "Found no suitable compiler."
      exit 1
    fi

    _KAFLAGS=()
    _KCFLAGS=()
    _KCPPFLAGS=()
    _HOSTCFLAGS=()
    if [ "$selected_cc" != "gcc-4.8" ]; then
        # Older kernel Makefiles do not expect the compiler to default to PIE
        _KAFLAGS+=(-fno-pie)
        _KCFLAGS+=(
            -fno-pie
            -no-pie
            -fno-stack-protector
        )
        _KCPPFLAGS+=(-fno-pie)
    fi

    selected_cc_version="$(echo "${selected_cc}" | cut -d'-' -f2)"
    if { vergte "${selected_cc_version}" "10"; } && { verlt "${kversion}" "5.10"; } ; then
        # gcc-10 changed the default from '-fcommon' to '-fno-common', which
        # causes a linker failure. '-fcommon' can be set on the HOSTCFLAGS
        # to avoid the issue.
        # @see https://gitlab.com/linux-kernel/stable/-/commit/e33a814e772cdc36436c8c188d8c42d019fda639
        _HOSTCFLAGS+=(-fcommon)
    fi

    if [ "${cross_arch:-}" == "armhf" ] ; then
        if { verlt "${kversion}" "5.14"; } ; then
            # Work-around for producing instructions that aren't valid for the
            # default architectures.
            # Eg. Error: selected processor does not support `cpsid i' in ARM mode
            _KCFLAGS+=(-march=armv7-a -mfpu=vfpv3-d16)
            _KCPPFLAGS+=(-march=armv7-a -mfpu=vfpv3-d16)
        fi
    fi

    if { vergt "${selected_cc_version}" "8"; } && { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.17"; } ; then
        # This was added to -Wall in gcc 9 but some kernels do not include the fixes
        # @see https://gcc.gnu.org/bugzilla/show_bug.cgi?id=88583
        _KCFLAGS+=(-Wno-error=packed-not-aligned)
    fi

    export KAFLAGS="${_KAFLAGS[*]}"
    export KCFLAGS="${_KCFLAGS[*]}"
    export KCPPFLAGS="${_KCPPFLAGS[*]}"
    export HOSTCFLAGS="${_HOSTCFLAGS[*]}"
    export CC="${CROSS_COMPILE:-}${selected_cc}"
    export HOSTCC="${selected_cc}"

    make_args=(
        CC="${CC}"
        HOSTCC="${HOSTCC}"
        HOSTCFLAGS="${HOSTCFLAGS:-}"
    )
    if [ -n "${DEBUG}" ] ; then
        make_args+=(
            V=1
        )
    fi
    cd -
}

patch_linux_kernel() {
    local commit_hash
    commit_hash="$1"
    set +e
    git -C "${LINUX_GIT_REF_REPO_DIR}" format-patch -n1 --stdout "${commit_hash}" | patch -p1
    set -e
    if [ "$?" -gt 1 ] ; then
        echo "Serious issue patching"
        exit 1
    fi
}

build_linux_kernel() {
    cd "$LINUX_SRCOBJ_DIR"

    kversion=$(make -s kernelversion "${make_args[@]}")
    pahole_version="$(pahole --version | tr -d 'v')"

    if { verlt "${kversion}" "3.3"; } && [ "${vanilla_config}" = "imx_v6_v7_defconfig" ] ; then
        # imx_v6_v7 didn't exist before 06965c39b4c63933fa0a1cde2237ef85477c5655
        if { verlt "${kversion}" "3.2"; } ; then
            vanilla_config='mx5_defconfig'
        else
            vanilla_config='mx51_defconfig'
        fi
    fi

    if { verlt "${kversion}" "3.13"; } && [ "${vanilla_config}" = "pseries_le_defconfig" ] ; then
        # pseries_le_deconfig was introduced in f53e462e907cbaed29c49c0f10f5b8f614e1bf1d
        vanilla_config='pseries_defconfig'
    fi

    # Generate kernel configuration
    case "$ktag" in
      Ubuntu*)
        if [ "${cross_arch}" = "powerpc" ]; then
          if vergte "${kversion}" "4.10"; then
            echo "Ubuntu removed big endian powerpc configuration from kernel >= 4.10. Don't try to build it."
            exit 0
          fi
        fi

        # Disable riscv64 config generation, we don't have a toolchain on bionic
        sed -i 's/riscv64 //' debian.master/etc/kernelconfig

        fakeroot debian/rules clean KW_DEFCONFIG_DIR=.

        # Hack for kernel Ubuntu-hwe-5.8
        # The debian/control file is produced by the clean target above, so this
        # check needs to happen afterwards.
        if [ ! -f "debian/compat" ] && ! grep -q debhelper-compat debian/control; then
            echo "10" > "debian/compat"
        fi

        # genconfigs check can fail in certain cases, eg. when a more recent
        # compiler exposes kernel configuration flags which aren't set in the
        # Ubuntu annotations.
        # In any case, the configuration will be updated with any missing values
        # later in our build script.
        fakeroot debian/rules genconfigs KW_DEFCONFIG_DIR=. do_skip_checks=true
        cp CONFIGS/"${ubuntu_config}" .config
        ;;

      *)
        # Force 32bit build on i386, default is 64bit
        if [ "$arch" = "i386" ]; then
            export ARCH="i386"
        fi

        make "${vanilla_config}" "${make_args[@]}"
        ;;
    esac

    if [ "${vanilla_config}" = "pseries_defconfig" ] && [ "${cross_arch}" = "ppc64el" ] ; then
        # @see diff <(git show v3.13:arch/powerpc/configs/pseries_defconfig) <(git show v3.13:arch/powerpc/configs/pseries_le_defconfig)
        scripts/config --enable CONFIG_CPU_LITTLE_ENDIAN
        scripts/config --enable CONFIG_CMA
        scripts/config --disable CONFIG_XMON_DEFAULT
        # scripts/config --disable CONFIG_VIRTUALIZATION
        # scripts/config --disable CONFIG_KVM_BOOK3S_64
        scripts/config --disable CONFIG_KVM_BOOK3S_64_HV
    fi

    # oldnoconfig was renamed in 4.19
    if vergte "$kversion" "4.19"; then
        update_conf_target="olddefconfig"
    else
        update_conf_target="oldnoconfig"
    fi

    # Fix 'defined(@array)' was removed from recent perl
    if [ -f "kernel/timeconst.pl" ]; then
      sed -i 's/defined(\@\(.*\))/@\1/' kernel/timeconst.pl
    fi

    # Fix syntax of inline assembly which is confused with C++11 raw strings on gcc >= 5
    if [ "$HOSTCC" != "gcc-4.8" ]; then
      if [ -f "arch/x86/kvm/svm.c" ]; then
        sed -i 's/ R"/ R "/g; s/"R"/" R "/g' arch/x86/kvm/svm.c
      fi

      if [ -f "arch/x86/kvm/vmx.c" ]; then
        sed -i 's/ R"/ R "/g; s/"R"/" R "/g' arch/x86/kvm/vmx.c
      fi
    fi

    if { verlt "${kversion}" "5.11"; } && { vergte "${kversion}" "4.10"; } ; then
        # Binutils > 2.35 strips empty symbol tables, causing obltool to fail
        # in certain cases when files are empty.
        # @see https://gitlab.com/linux-kernel/stable/-/commit/1d489151e9f9d1647110277ff77282fe4d96d09b
        #
        # There doesn't seem to be any LD/AS/AR flags to control this behaviour,
        # therefore patching tools/objtool/elf.c is attempted.
        patch_linux_kernel 1d489151e9f9d1647110277ff77282fe4d96d09b
        if { verlt "${kversion}" "4.18"; } ; then
            patch_linux_kernel e81e0724432542af8d8c702c31e9d82f57b1ff31
        fi
    fi

    if { vergt "${selected_cc_version}" "7"; } && { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.17"; } ; then
        # Builds fail due to -Werror=restrict in pager.o and str_error_r.o
        if { verlt "${kversion}" "4.16"; } ; then
            # This is patched since objtool's Makefile doesn't respect HOSTCFLAGS
            # @see https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=ad343a98e74e85aa91d844310e797f96fee6983b
            patch_linux_kernel ad343a98e74e85aa91d844310e797f96fee6983b
        fi
        if { verlt "${kversion}" "4.17"; } ; then
            # This is patched since objtool's Makefile doesn't respect HOSTCFLAGS
            # @see https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=854e55ad289ef8888e7991f0ada85d5846f5afb9
            patch_linux_kernel 854e55ad289ef8888e7991f0ada85d5846f5afb9
        fi

    fi

    if { vergt "${selected_cc_version}" "9"; } && { verlt "${kversion}" "5.6"; } ; then
        # Duplicate decalarations of __force_order
        # @see https://gitlab.com/linux-kernel/stable/-/commit/df6d4f9db79c1a5d6f48b59db35ccd1e9ff9adfc
        patch_linux_kernel df6d4f9db79c1a5d6f48b59db35ccd1e9ff9adfc
        # However, kaslr_64.c doesn't exit in 4.15, 4.16, it's named pagetable.c
        if [ -f arch/x86/boot/compressed/pagetable.c ] ; then
            sed -i '/^unsigned long __force_order;$/d' arch/x86/boot/compressed/pagetable.c
        fi
    fi

    if { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.18"; } ; then
        # Some old kernels fail to build when make is too new
        # @see https://gitlab.com/linux-kernel/stable/-/commit/9feeb638cde083c737e295c0547f1b4f28e99583
        patch_linux_kernel 9564a8cf422d7b58f6e857e3546d346fa970191e
        # @see https://gitlab.com/linux-kernel/stable/-/commit/9feeb638cde083c737e295c0547f1b4f28e99583
        patch_linux_kernel 9feeb638cde083c737e295c0547f1b4f28e99583
    fi

    if { vergte "${kversion}" "4.12"; } && { verlt "${kversion}" "4.19"; } ; then
        # Old kernels can fail to build while on newer host kernels with errors
        # such as:
        #   In file included from scripts/selinux/genheaders/genheaders.c:19:
        #   ./security/selinux/include/classmap.h:249:2: error: #error New address family defined, please update secclass_map.
        # @see https://gitlab.com/linux-kernel/stable/-/commit/dfbd199a7cfe3e3cd8531e1353cdbd7175bfbc5e
        #
        patch_linux_kernel dfbd199a7cfe3e3cd8531e1353cdbd7175bfbc5e
    fi

    if { vergte "${kversion}" "3.18"; } && { verlt "${kversion}" "4.4"; } ; then
        # Compatibility with binutils >= ~ 2.31
        patch_linux_kernel b21ebf2fb4cde1618915a97cc773e287ff49173e
    fi

    # The above patch only partially applies linux 3.17, and has been, so a
    # rebased version is used instead.
    if { vergte "${kversion}" "3.17"; } && { verlt "${kversion}" "3.18"; } ; then
        cat <<'EOF' | patch -p1
diff --git a/arch/x86/kernel/machine_kexec_64.c b/arch/x86/kernel/machine_kexec_64.c
index 48598105..0652c5b6 100644
--- a/arch/x86/kernel/machine_kexec_64.c
+++ b/arch/x86/kernel/machine_kexec_64.c
@@ -516,6 +516,7 @@ int arch_kexec_apply_relocations_add(const Elf64_Ehdr *ehdr,
 				goto overflow;
 			break;
 		case R_X86_64_PC32:
+		case R_X86_64_PLT32:
 			value -= (u64)address;
 			*(u32 *)location = value;
 			break;
diff --git a/arch/x86/kernel/module.c b/arch/x86/kernel/module.c
index e69f9882..7c6bc9fe 100644
--- a/arch/x86/kernel/module.c
+++ b/arch/x86/kernel/module.c
@@ -180,6 +180,7 @@ int apply_relocate_add(Elf64_Shdr *sechdrs,
 				goto overflow;
 			break;
 		case R_X86_64_PC32:
+		case R_X86_64_PLT32:
 			val -= (u64)loc;
 			*(u32 *)loc = val;
 #if 0
diff --git a/arch/x86/tools/relocs.c b/arch/x86/tools/relocs.c
index bbb1d225..8deeacbc 100644
--- a/arch/x86/tools/relocs.c
+++ b/arch/x86/tools/relocs.c
@@ -763,6 +763,7 @@ static int do_reloc64(struct section *sec, Elf_Rel *rel, ElfW(Sym) *sym,
 	switch (r_type) {
 	case R_X86_64_NONE:
 	case R_X86_64_PC32:
+	case R_X86_64_PLT32:
 		/*
 		 * NONE can be ignored and PC relative relocations don't
 		 * need to be adjusted.
EOF
    fi

    if ( { vergte "${kversion}" "3.14"; } && { verlt "${kversion}" "4.4"; } ) ||
       ( { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.17"; } ); then
        # While the original motivation of this patch is for fixing builds using
        # clang, the same error occurs between linux >= 3.14 and < 4.4, and in
        # 4.15, 4.16.
        #
        # This patch only partially applies due to changes in kernel/Makefile,
        # so a supplementary patch is needed
        #
        # Without this patch, builds fail with
        #   Cannot find symbol for section 2: .text.
        #   kernel/elfcore.o: failed
        #
        # @see https://github.com/linuxppc/issues/issues/388
        # @see https://lore.kernel.org/lkml/20201204165742.3815221-2-arnd@kernel.org/
        #
        patch_linux_kernel 6e7b64b9dd6d96537d816ea07ec26b7dedd397b9
        if grep -q elfcore.o kernel/Makefile ; then
            sed -i '/^.* += elfcore.o$/d' kernel/Makefile
        fi
    fi
    # Same as above for the v4.4 branch
    if ( { vergte "${kversion}" "4.4"; } && { verlt "${kversion}" "4.4.257"; } ); then
        patch_linux_kernel 3140b0740b31cc63cf2ee08bc3f746b423eb068d
        if grep -q elfcore.o kernel/Makefile ; then
            sed -i '/^.* += elfcore.o$/d' kernel/Makefile
        fi
    fi

    # Newer binutils don't accept 3 operand 'cmp' instructions on ppc64
    # Convert them to 'cmpw' which was previously done silently
    if verlt "$kversion" "4.9"; then
	    find arch/powerpc/ -name "*.S" -print0 | xargs -0 sed -i "s/\(cmp\)\(\s\+[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+\)/cmpw\2/"
	    find arch/powerpc/ -name "*.S" -print0 | xargs -0 sed -i "s/\(cmpli\)\(\s\+[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+\)/cmplwi\2/"
	    sed -i "s/\$pie \-o \"\$ofile\"/\$pie --no-dynamic-linker -o \"\$ofile\"/" arch/powerpc/boot/wrapper
    fi

    # Fix a typo in v2.6.36.x
    if [ -f "arch/x86/kernel/entry_64.S" ]; then
      sed -i 's/END(do_hypervisor_callback)/END(xen_do_hypervisor_callback)/' arch/x86/kernel/entry_64.S
    fi

    # Fix compiler switch in vdso Makefile for 2.6.36 to 2.6.36.2
    if { vergte "$kversion" "2.6.36" && verlte "$kversion" "2.6.36.3"; }; then
      sed -i 's/-m elf_x86_64/-m64/' arch/x86/vdso/Makefile
      sed -i 's/-m elf_i386/-m32/' arch/x86/vdso/Makefile
    fi

    # Fix kernel < 3.0 with gcc >= 4.7
    if verlt "$kversion" "3.0"; then
      sed -i '/linux\/compiler.h/a #include <linux\/linkage.h> \/* For asmregparm *\/' arch/x86/include/asm/ptrace.h
      sed -i 's/extern long syscall_trace_enter/extern asmregparm long syscall_trace_enter/' arch/x86/include/asm/ptrace.h
      sed -i 's/extern void syscall_trace_leave/extern asmregparm void syscall_trace_leave/' arch/x86/include/asm/ptrace.h
      echo "header-y += linkage.h" >> include/linux/Kbuild
    fi

    if [ "${cross_arch}" = "powerpc" ] ; then
        if { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.16"; } ; then
            # Avoid register errors such as
            # aes_generic.c:(.text+0x4e0): undefined reference to `_restgpr_31_x'
            # @see https://gitlab.com/linux-kernel/stable/-/commit/148b974deea927f5dbb6c468af2707b488bfa2de
            make_args+=(
                CFLAGS_aes_generic.o=''
            )
        fi
    fi

    if [ "$(scripts/config --state CONFIG_DEBUG_INFO_BTF)" == "y" ] &&
           { vergte "${pahole_version}" "1.24"; } &&
           { vergte "${kversion}" "5.10"; } && { verlt "${kversion}" "6.0"; } ;then
        # Some kernels Eg. Ubuntu-hwe-5.13-5.13.0-52.59_20.04.1
        # fail with the following error:
        #   BTFIDS  vmlinux
        #   FAILED: load BTF from vmlinux: Invalid argument
        #
        # When CONFIG_DEBUG_INFO_BTF is set, certain versions of pahole require
        # `--skip_encoding_btf_enum64` to be passed as the kernel doesn't define
        # BTF_KIND_ENUM64.
        #
        # Introduced in 341dfcf8d78eaa3a2dc96dea06f0392eb2978364 (~v5.10)
        # @see https://lore.kernel.org/bpf/20220825171620.cioobudss6ovyrkc@altlinux.org/t/
        #
        if [ -f "scripts/pahole-flags.sh" ] ; then
            sed -i 's/ -J ${PAHOLE_FLAGS} / -J ${PAHOLE_FLAGS} --skip_encoding_btf_enum64 /' scripts/link-vmlinux.sh
        else
            sed -i 's/ -J ${extra_paholeopt} / -J ${extra_paholeopt} --skip_encoding_btf_enum64 /' scripts/link-vmlinux.sh
        fi
    fi

    # GCC 4.8
    if [ "$HOSTCC" == "gcc-4.8" ]; then
        scripts/config --disable CONFIG_CC_STACKPROTECTOR_STRONG
        scripts/config --disable CONFIG_PPC_OF_BOOT_TRAMPOLINE
    fi

    # Don't try to sign modules
    scripts/config --disable CONFIG_MODULE_SIG

    # Disable kernel stack frame correctness validation, introduced in 4.6.0 and currently fails
    scripts/config --disable CONFIG_STACK_VALIDATION

    # Cause problems with inline assembly on i386
    scripts/config --disable CONFIG_DEBUG_SECTION_MISMATCH

    # Don't build samples, they are broken on some kernel releases
    scripts/config --disable CONFIG_SAMPLES
    scripts/config --disable CONFIG_BUILD_DOCSRC

    # Disable kcov
    scripts/config --disable CONFIG_KCOV

    # Broken on some RT kernels
    scripts/config --disable CONFIG_HYPERV

    # Broken drivers
    scripts/config --disable CONFIG_RAPIDIO_TSI721
    scripts/config --disable CONFIG_SGI_XP
    scripts/config --disable CONFIG_MFD_WM8994
    scripts/config --disable CONFIG_DRM_RADEON
    scripts/config --disable CONFIG_SND_SOC_WM5100
    # More recent compiler optimizations (from gcc 8 onwards )expose build errors
    # with netronome on older kernels.
    # Observed in 4.11-rt, 4.15-4.17, 5.0-rt - 5.16-rt
    # It seems easier to disable the driver than to attempt patching.
    # Eg.
    #   In function ‘ur_load_imm_any’,
    #   inlined from ‘jeq_imm’ at drivers/net/ethernet/netronome/nfp/bpf/jit.c:3146:13:
    #   ./include/linux/compiler.h:350:45: error: call to ‘__compiletime_assert_1062’ declared with attribute error: FIELD_FIT: value too large for the field
    #   350 |         _compiletime_assert(condition, msg, __compiletime_assert_, __COUNTER__)
    #
    scripts/config --disable CONFIG_NET_VENDOR_NETRONOME
    # Eg.
    #  In function ‘memcpy’,
    #  inlined from ‘kszphy_get_strings’ at drivers/net/phy/micrel.c:664:3:
    #  ./include/linux/string.h:305:25: error: call to ‘__read_overflow2’ declared with attribute error: detected read beyond size of object passed as 2nd parameter
    #  305 |                         __read_overflow2();
    #      |                         ^~~~~~~~~~~~~~~~~~
    #  make[3]: *** [scripts/Makefile.build:308: drivers/net/phy/micrel.o] Error 1
    #
    scripts/config --disable CONFIG_MICREL_PHY


    # IGBVF won't build with recent gcc on 2.6.38.x
    if { vergte "$kversion" "2.6.37" && verlt "$kversion" "2.6.38"; }; then
      scripts/config --disable CONFIG_IGBVF
    fi

    # Don't fail the build on warnings
    scripts/config --disable CONFIG_WERROR
    scripts/config --enable CONFIG_PPC_DISABLE_WERROR

    # Set required options
    scripts/config --enable CONFIG_TRACEPOINTS
    scripts/config --enable CONFIG_KALLSYMS
    scripts/config --enable CONFIG_HIGH_RES_TIMERS
    scripts/config --enable CONFIG_KPROBES
    scripts/config --enable CONFIG_FTRACE
    scripts/config --enable CONFIG_BLK_DEV_IO_TRACE
    scripts/config --enable CONFIG_KALLSYMS_ALL
    scripts/config --enable CONFIG_HAVE_SYSCALL_TRACEPOINTS
    scripts/config --enable CONFIG_PERF_EVENTS
    scripts/config --enable CONFIG_EVENT_TRACING
    scripts/config --enable CONFIG_KRETPROBES

    if [ -n "${DEBUG}" ] ; then
        cat .config
    fi

    make "$update_conf_target" "${make_args[@]}"
    make -j"$NPROC" "${make_args[@]}"

    krelease=$(make -s kernelrelease "${make_args[@]}")

    # Save the kernel and modules
    mkdir -p "$LINUX_INSTOBJ_DIR/boot"
    make INSTALL_MOD_PATH="$LINUX_INSTOBJ_DIR" INSTALL_MOD_STRIP=1 modules_install "${make_args[@]}"
    make INSTALL_MOD_PATH="$LINUX_INSTOBJ_DIR" INSTALL_PATH="$LINUX_INSTOBJ_DIR/boot" install "${make_args[@]}"
    rm -f "$LINUX_INSTOBJ_DIR/lib/modules/${krelease}/source" "$LINUX_INSTOBJ_DIR/lib/modules/${krelease}/build"
    ln -s ../../../../sources "$LINUX_INSTOBJ_DIR/lib/modules/${krelease}/source"
    ln -s ../../../../sources "$LINUX_INSTOBJ_DIR/lib/modules/${krelease}/source"
}


extract_distro_headers() {

    # Enter linux source dir
    cd "${LINUX_SRCOBJ_DIR}"


    # For RT kernels, copy version file
    if [ -s localversion-rt ]; then
        cp -a localversion-rt "${LINUX_HDROBJ_DIR}"
    fi

    # Copy all Makefile related stuff
    find . -path './include/*' -prune \
        -o -path './scripts/*' -prune -o -type f \
        \( -name 'Makefile*' -o -name 'Kconfig*' -o -name 'Kbuild*' -o \
            -name '*.sh' -o -name '*.pl' -o -name '*.lds' \) \
        -print | cpio -pd --preserve-modification-time "${LINUX_HDROBJ_DIR}"

    # Copy base scripts and include dirs
    cp -a scripts include "${LINUX_HDROBJ_DIR}"

    # Copy arch includes
    (find arch -name include -type d -print0 | \
        xargs -0 -n1 -I '{}' find '{}' -type f) | \
        cpio -pd --preserve-modification-time "${LINUX_HDROBJ_DIR}"

    # Copy arch scripts
    (find arch -name scripts -type d -print0 | \
        xargs -0 -n1 -I '{}' find '{}' -type f) | \
        cpio -pd --preserve-modification-time "${LINUX_HDROBJ_DIR}"

    # Cleanup scripts
    rm -f "${LINUX_HDROBJ_DIR}/scripts/*.o"
    rm -f "${LINUX_HDROBJ_DIR}/scripts/*/*.o"

    # On powerpc 32bits this object is required to link modules
    if [ "${karch}" = "powerpc" ]; then
        if [ "$(scripts/config -s CONFIG_PPC64)" = "y" ] && vergte "${kversion}" "5.4"; then
            :
        else
            cp -a --parents arch/powerpc/lib/crtsavres.[So] "${LINUX_HDROBJ_DIR}/"
        fi
    fi

    # On arm64 between 4.13 and 1.15 this object is required to build with ftrace support
    if [ "${karch}" = "arm64" ]; then
        if [ -f "arch/arm64/kernel/ftrace-mod.S" ]; then
            cp -a --parents arch/arm64/kernel/ftrace-mod.[So] "${LINUX_HDROBJ_DIR}/"
        fi
    fi

    # Newer kernels need objtool to build modules when CONFIG_STACK_VALIDATION=y
    if [ -f tools/objtool/objtool ]; then
      cp -a --parents tools/objtool/objtool "${LINUX_HDROBJ_DIR}/"
    fi

    if [ -f "arch/x86/kernel/macros.s" ]; then
      cp -a --parents arch/x86/kernel/macros.s "${LINUX_HDROBJ_DIR}/"
    fi

    # Copy modules related stuff, if available
    if [ -s Module.symvers ]; then
        cp Module.symvers "${LINUX_HDROBJ_DIR}"
    fi

    if [ -s System.map ]; then
        cp System.map "${LINUX_HDROBJ_DIR}"
    fi

    if [ -s Module.markers ]; then
        cp Module.markers "${LINUX_HDROBJ_DIR}"
    fi

    # Copy config file
    cp .config "${LINUX_HDROBJ_DIR}"

    # Make sure the Makefile and version.h have a matching timestamp so that
    # external modules can be built
    if [ -s "${LINUX_HDROBJ_DIR}/include/generated/uapi/linux/version.h" ]; then
        touch -r "${LINUX_HDROBJ_DIR}/Makefile" "${LINUX_HDROBJ_DIR}/include/generated/uapi/linux/version.h"
    elif [ -s "${LINUX_HDROBJ_DIR}/include/linux/version.h" ]; then
        touch -r "${LINUX_HDROBJ_DIR}/Makefile" "${LINUX_HDROBJ_DIR}/include/linux/version.h"
    else
        echo "Missing version.h"
        exit 1
    fi
    touch -r "${LINUX_HDROBJ_DIR}/.config" "${LINUX_HDROBJ_DIR}/include/generated/autoconf.h"

    # Copy .config to include/config/auto.conf so "make prepare" is unnecessary.
    if [ ! -f "${LINUX_HDROBJ_DIR}/include/config/auto.conf" ]; then
        cp "${LINUX_HDROBJ_DIR}/.config" "${LINUX_HDROBJ_DIR}/include/config/auto.conf"
    fi

    # Finally clean the object files from the full source tree
    make clean

    # And regen the modules support files
    make modules_prepare "${make_args[@]}"

    # On powerpc 32bits this object is required to link modules
    if [ "${karch}" = "powerpc" ]; then
        if [ "$(scripts/config -s CONFIG_PPC64)" = "y" ] && vergte "${kversion}" "5.4"; then
            :
        else
            make arch/powerpc/lib/crtsavres.o "${make_args[@]}"
        fi
    fi

    # On arm64 between 4.13 and 4.15 this object is required to build with ftrace support
    if [ "${karch}" = "arm64" ]; then
        if [ -f "arch/arm64/kernel/ftrace-mod.S" ]; then
            make arch/arm64/kernel/ftrace-mod.o "${make_args[@]}"
        fi
    fi

    # Version specific tasks
    case "$ktag" in
      Ubuntu*)
        # Add Ubuntu ABI number to kernel headers, this is normally done by the packaging code
        ABINUM="$(echo "$ktag" | grep -P -o 'Ubuntu-(lts-)?.*-\K\d+(?=\..*)')"
        echo "#define UTS_UBUNTU_RELEASE_ABI $ABINUM" >> include/generated/utsrelease.h
        echo "#define UTS_UBUNTU_RELEASE_ABI $ABINUM" >> "${LINUX_HDROBJ_DIR}/include/generated/utsrelease.h"
        ;;
    esac
}


build_modules() {

    local kdir="$1"
    local outdir="$2"
    local kversion

    kversion=$(make -C "$LINUX_HDROBJ_DIR" -s kernelversion)

    # Try to catch some compatibility problems by turning some
    # warnings into errors.
    #export KCFLAGS="$KCFLAGS -Wall -Werror"

    # Enter lttng-modules source dir
    cd "${MODULES_GIT_DIR}"

    # kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
    # timekeeping subsystem. We want those build to fail.
    if { vergte "$kversion" "3.10" && verlte "$kversion" "3.10.13"; } || \
       { vergte "$kversion" "3.11" && verlte "$kversion" "3.11.2"; }; then

        set +e

        # Build modules
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 "${make_args[@]}"
	ret=$?

        set -e

        # We expect this build to fail, if it doesn't, fail the job.
        if [ "$ret" -eq 0 ]; then
            echo "This build should have failed."
            exit 1
        fi

        # We have to publish at least one file or the build will fail
        echo "This kernel is broken, there is a deadlock in the timekeeping subsystem." > "${outdir}/BROKEN.txt.ko"

        KERNELDIR="${kdir}" make clean

    else # Regular build

        # Build modules against full kernel sources
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 "${make_args[@]}"

        # Install modules to build dir
        KERNELDIR="${kdir}" make INSTALL_MOD_PATH="${outdir}" modules_install

        # Clean build dir
        KERNELDIR="${kdir}" make clean
    fi
}


## MAIN ##

# Use all CPU cores
NPROC=$(nproc)

MODULES_GIT_DIR="${WORKSPACE}/src/lttng-modules"
LINUX_GIT_DIR="${WORKSPACE}/src/linux"

LINUX_OBJ_DIR="${WORKSPACE}/linux"
LINUX_SRCOBJ_DIR="${LINUX_OBJ_DIR}/sources"
LINUX_HDROBJ_DIR="${LINUX_OBJ_DIR}/headers"
LINUX_INSTOBJ_DIR="${LINUX_OBJ_DIR}/install"

MODULES_OUTPUT_KSRC_DIR="${WORKSPACE}/build/lttng-modules-ksrc"
MODULES_OUTPUT_KHDR_DIR="${WORKSPACE}/build/lttng-modules-khdr"

LINUX_GIT_REF_REPO_DIR="$HOME/gitcache/linux-stable.git/"

OBJ_STORE_URL="s3://jenkins"

cd "$WORKSPACE"

# Create build directories
mkdir -p "${LINUX_SRCOBJ_DIR}" "${LINUX_HDROBJ_DIR}" "${LINUX_INSTOBJ_DIR}" "${MODULES_OUTPUT_KSRC_DIR}" "${MODULES_OUTPUT_KHDR_DIR}"

git_clone_modules_sources

# Setup cross compile env if available
if [ "x${cross_arch}" != "x" ]; then

    case "$cross_arch" in
        "armhf")
            karch="arm"
            cross_compile="arm-linux-gnueabihf-"
            vanilla_config="imx_v6_v7_defconfig"
            ubuntu_config="armhf-config.flavour.generic"
            ;;

        "arm64")
            karch="arm64"
            cross_compile="aarch64-linux-gnu-"
            vanilla_config="defconfig"
            ubuntu_config="arm64-config.flavour.generic"
            ;;

        "powerpc")
            karch="powerpc"
            cross_compile="powerpc-linux-gnu-"
            vanilla_config="ppc44x_defconfig"
            ubuntu_config="powerpc-config.flavour.powerpc-smp"
            ;;

        "ppc64el")
            karch="powerpc"
            cross_compile="powerpc64le-linux-gnu-"
            vanilla_config="pseries_le_defconfig"
            ubuntu_config="ppc64el-config.flavour.generic"
            ;;

        *)
            echo "Unsupported cross arch $cross_arch"
            exit 1
            ;;
    esac

    # Export variables used by Kbuild for cross compilation
    export ARCH="${karch}"
    export CROSS_COMPILE="${cross_compile}"

# Set arch specific values if we are not cross compiling
elif [ "x${arch}" != "x" ]; then

    case "$arch" in
        "i386")
            karch="x86"
            vanilla_config="allmodconfig"
            ubuntu_config="i386-config.flavour.generic"
            ;;

        "amd64")
            karch="x86"
            vanilla_config="allmodconfig"
            ubuntu_config="amd64-config.flavour.generic"
            ;;

        "armhf")
            karch="arm"
            vanilla_config="allmodconfig"
            ubuntu_config="armhf-config.flavour.generic"
            ;;

        "arm64")
            karch="arm64"
            vanilla_config="allmodconfig"
            ubuntu_config="arm64-config.flavour.generic"
            ;;

        "powerpc")
            karch="powerpc"
            vanilla_config="allmodconfig"
            ubuntu_config="powerpc-config.flavour.powerpc-smp"
            ;;

        "ppc64el")
            karch="powerpc"
            vanilla_config="allmodconfig"
            ubuntu_config="ppc64el-config.flavour.generic"
            ;;

        *)
            echo "Unsupported arch $arch"
            exit 1
            ;;
    esac
else
    echo "No arch or cross_arch specified"
    exit 1
fi



# First get the kernel build from the object store, or build it, if it's
# not available.

echo "# Setup endpoint
host_base = obj.internal.efficios.com
host_bucket = obj.internal.efficios.com
bucket_location = us-east-1
use_https = True

# Setup access keys
access_key = jenkins
secret_key = echo123456

# Enable S3 v4 signature APIs
signature_v2 = False" > "$WORKSPACE/.s3cfg"

url_hash="$(echo -n "$kgitrepo" | md5sum | awk '{ print $1 }')"
obj_name="linux.tar.bz2"

if [ -z "${cross_arch}" ]; then
	obj_url_prefix="$OBJ_STORE_URL/linux-build/$url_hash/$ktag/platform-${platforms}/$arch/native"
else
	obj_url_prefix="$OBJ_STORE_URL/linux-build/$url_hash/$ktag/platform-${platforms}/${cross_arch}"
fi

obj_url="$obj_url_prefix/$obj_name"

set +e
# In s3cmd 2.3, the return code of get when an object does not exist (64)
# is different than in 2.2 (12). The return codes of 's3cmd info' are
# consistent between 2.2 and 2.3.
s3cmd -c "$WORKSPACE/.s3cfg" info "$obj_url"
ret=$?
set -e

case "$ret" in
    "0")
      s3cmd -c "$WORKSPACE/.s3cfg" get "$obj_url"
      extract_archive_obj
      ;;

    "12")
      echo "File not found"

      # Build all the things and upload
      # then finish the module build...

      git_clone_linux_sources
      git_export_linux_sources

      select_compiler

      ## PREPARE FULL LINUX SOURCE TREE
      build_linux_kernel

      ## EXTRACT DISTRO STYLE KERNEL HEADERS / DEVEL
      extract_distro_headers

      tar_archive_obj

      upload_archive_obj

      ;;

    *)
      echo "Unknown error? Abort"
      exit 1
      ;;
esac

select_compiler

selected_cc_version="$(echo "${selected_cc}" | cut -d'-' -f2)"
# lttng-modules requires gcc >= 5.1 for aarch64
# @see https://github.com/lttng/lttng-modules/commit/be06402dbdbea2f3394e60ec15c5d3356e2be416
if { verlt "${selected_cc_version}" "5.1"; } && [ "${cross_arch}" = "arm64" ] ; then
    echo "Building lltng-modules on aarch64 requires gcc >= 5.1"
    exit 0
fi

## BUILD modules
# Either we downloaded a pre-build kernel or we built it and uploaded
# the archive for future builds.

cd "$WORKSPACE"

# Build modules against full kernel sources
build_modules "${LINUX_SRCOBJ_DIR}" "${MODULES_OUTPUT_KSRC_DIR}"

# Build modules against kernel headers
build_modules "${LINUX_HDROBJ_DIR}" "${MODULES_OUTPUT_KHDR_DIR}"

# Make sure some modules were actually built
tree "${MODULES_OUTPUT_KSRC_DIR}"
if [ "x$(find "${MODULES_OUTPUT_KSRC_DIR}" -name '*.ko*' -printf yes -quit)" != "xyes" ]; then
  echo "No modules built!"
  exit 1
fi

tree "${MODULES_OUTPUT_KHDR_DIR}"
if [ "x$(find "${MODULES_OUTPUT_KHDR_DIR}" -name '*.ko*' -printf yes -quit)" != "xyes" ]; then
  echo "No modules built!"
  exit 1
fi

# EOF
