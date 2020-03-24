#!/bin/bash -exu
#
# Copyright (C) 2016-2019 - Michael Jeanson <mjeanson@efficios.com>
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

# Parameters
arch=${arch:-}
cross_arch=${cross_arch:-}
ktag=${ktag:-}
kgitrepo=${kgitrepo:-}
mversion=${mversion:-}
mgitrepo=${mgitrepo:-}


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
    tar -xf "$WORKSPACE/$obj_name" -C "$LINUX_OBJ_DIR"
    rm -f "$WORKSPACE/$obj_name"
}


tar_archive_obj() {
    cd "$LINUX_OBJ_DIR"
    tar -cf "$WORKSPACE/$obj_name" -I pbzip2 .
    cd -
}

# Find the most recent GCC version supported by the kernel sources
select_compiler() {
    local selected_cc

    cd "$LINUX_SRCOBJ_DIR"

    kversion=$(make -s kernelversion)

    set +e

    for cc in gcc-5 gcc-4.8; do
      if "${CROSS_COMPILE:-}${cc}" -I include/ -D__LINUX_COMPILER_H -D__LINUX_COMPILER_TYPES_H -E include/linux/compiler-gcc.h; then
        selected_cc="$cc"
        break
      fi
    done

    set -e

    if [ "x$selected_cc" = "x" ]; then
      echo "Found no suitable compiler."
      exit 1
    fi

    # Force gcc-4.8 for kernels before 3.18
    if { verlt "$kversion" "3.18"; }; then
      selected_cc=gcc-4.8
    fi

    if [ "$selected_cc" != "gcc-4.8" ]; then
        # Older kernel Makefiles do not expect the compiler to default to PIE
        KAFLAGS="-fno-pie"
        KCFLAGS="-fno-pie -no-pie -fno-stack-protector"
        KCPPFLAGS="-fno-pie"
        export KAFLAGS KCFLAGS KCPPFLAGS
    fi

    export CC="${CROSS_COMPILE:-}${selected_cc}"
    export HOSTCC="${selected_cc}"

    cd -
}


build_linux_kernel() {
    cd "$LINUX_SRCOBJ_DIR"

    kversion=$(make -s kernelversion)

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
        fakeroot debian/rules genconfigs KW_DEFCONFIG_DIR=.
        cp CONFIGS/"${ubuntu_config}" .config
        ;;

      *)
        # Force 32bit build on i386, default is 64bit
        if [ "$arch" = "i386" ]; then
            export ARCH="i386"
        fi

        # allyesconfig is mostly broken for kernels of the 2.6 series
        if verlt "$kversion" "3.0"; then
            vanilla_config="defconfig"
        fi

        make "${vanilla_config}"
        ;;
    esac

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

    # GCC 4.8
    if [ "$HOSTCC" == "gcc-4.8" ]; then
      scripts/config --disable CONFIG_CC_STACKPROTECTOR_STRONG
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

    # IGBVF won't build with recent gcc on 2.6.38.x
    if { vergte "$kversion" "2.6.37" && verlt "$kversion" "2.6.38"; }; then
      scripts/config --disable CONFIG_IGBVF
    fi

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

    # Debug
    #cat .config

    make "$update_conf_target" CC="$CC"
    make -j"$NPROC" CC="$CC"

    krelease=$(make -s kernelrelease CC="$CC")

    # Save the kernel and modules
    mkdir -p "$LINUX_INSTOBJ_DIR/boot"
    make INSTALL_MOD_PATH="$LINUX_INSTOBJ_DIR" INSTALL_MOD_STRIP=1 modules_install CC="$CC"
    make INSTALL_PATH="$LINUX_INSTOBJ_DIR/boot" install CC="$CC"
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
        xargs -0 -n1 -i: find : -type f) | \
        cpio -pd --preserve-modification-time "${LINUX_HDROBJ_DIR}"

    # Copy arch scripts
    (find arch -name scripts -type d -print0 | \
        xargs -0 -n1 -i: find : -type f) | \
        cpio -pd --preserve-modification-time "${LINUX_HDROBJ_DIR}"

    # Cleanup scripts
    rm -f "${LINUX_HDROBJ_DIR}/scripts/*.o"
    rm -f "${LINUX_HDROBJ_DIR}/scripts/*/*.o"

    # On powerpc 32bits this object is required to link modules
    if [ "${karch}" = "powerpc" ]; then
        if [ "x$(scripts/config -s CONFIG_PPC64)" = "xy" ] && vergte "${kversion}" "5.4"; then
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
    cp "${LINUX_HDROBJ_DIR}/.config" "${LINUX_HDROBJ_DIR}/include/config/auto.conf"

    # Finally clean the object files from the full source tree
    make clean

    # And regen the modules support files
    make modules_prepare CC="$CC"

    # On powerpc 32bits this object is required to link modules
    if [ "${karch}" = "powerpc" ]; then
        if [ "x$(scripts/config -s CONFIG_PPC64)" = "xy" ] && vergte "${kversion}" "5.4"; then
            :
        else
            make arch/powerpc/lib/crtsavres.o CC="$CC"
        fi
    fi

    # On arm64 between 4.13 and 4.15 this object is required to build with ftrace support
    if [ "${karch}" = "arm64" ]; then
        if [ -f "arch/arm64/kernel/ftrace-mod.S" ]; then
            make arch/arm64/kernel/ftrace-mod.o CC="$CC"
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

    # Enter lttng-modules source dir
    cd "${MODULES_GIT_DIR}"

    # kernels 3.10 to 3.10.13 and 3.11 to 3.11.2 introduce a deadlock in the
    # timekeeping subsystem. We want those build to fail.
    if { vergte "$kversion" "3.10" && verlte "$kversion" "3.10.13"; } || \
       { vergte "$kversion" "3.11" && verlte "$kversion" "3.11.2"; }; then

        set +e

        # Build modules
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 CC="$CC"
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
        KERNELDIR="${kdir}" make -j"${NPROC}" V=1 CC="$CC"

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
            vanilla_config="allyesconfig"
            ubuntu_config="i386-config.flavour.generic"
            ;;

        "amd64")
            karch="x86"
            vanilla_config="allyesconfig"
            ubuntu_config="amd64-config.flavour.generic"
            ;;

        "armhf")
            karch="arm"
            vanilla_config="allyesconfig"
            ubuntu_config="armhf-config.flavour.generic"
            ;;

        "arm64")
            karch="arm64"
            vanilla_config="allyesconfig"
            ubuntu_config="arm64-config.flavour.generic"
            ;;

        "powerpc")
            karch="powerpc"
            vanilla_config="allyesconfig"
            ubuntu_config="powerpc-config.flavour.powerpc-smp"
            ;;

        "ppc64el")
            karch="powerpc"
            vanilla_config="allyesconfig"
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
obj_url_prefix="$OBJ_STORE_URL/linux-build/$url_hash/$ktag/$arch/${cross_arch:-native}"
obj_url="$obj_url_prefix/$obj_name"

set +e
s3cmd -c "$WORKSPACE/.s3cfg" get "$obj_url"
ret=$?
set -e

case "$ret" in
    "0")
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
