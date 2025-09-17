#!/bin/bash
#
# Copyright (C) 2016-2023 Michael Jeanson <mjeanson@efficios.com>
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
platform=${platforms:-}
cross_arch=${cross_arch:-}
kconfig_profile="${kconfig_profile:-default}"
ktag=${ktag:-}
kgitrepo=${kgitrepo:-}
mversion=${mversion:-}
mgitrepo=${mgitrepo:-}
make_args=()

DEBUG=${DEBUG:-}
FAIL_ON_WARNINGS="${FAIL_ON_WARNINGS:-}"
if [[ "${FAIL_ON_WARNINGS}" == "false" ]] ; then
    FAIL_ON_WARNINGS=''
fi

# Derive arch from label if it isn't set
if [ -z "${arch:-}" ] ; then
    # Labels may be platform specific, eg. jammy-amd64, deb12-armhf
    regex='[[:alnum:]]+-([[:alnum:]]+)'
    if [[ "${platform}" =~ ${regex} ]] ; then
        arch="${BASH_REMATCH[1]}"
    else
        arch="${platform:-}"
    fi
fi

# Misc globals
BINUTILS_VERSION=''
SLES_RELEASE=''  # Set in select_compiler

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

print_header() {
    set +x

    local message=" $1 "
    local message_len
    local padding_len

    message_len="${#message}"
    padding_len=$(( (80 - (message_len)) / 2 ))

    printf '\n'; printf -- '#%.0s' {1..80}; printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' $(seq 1 $padding_len); printf '%s' "$message"; printf -- '#%.0s' $(seq 1 $padding_len); printf '\n'
    printf -- '-%.0s' {1..80}; printf '\n'
    printf -- '#%.0s' {1..80}; printf '\n\n'

    set -x
}

git_clone_modules_sources() {
    mkdir -p "$MODULES_GIT_DIR"

    # If the version starts with "refs/" or looks like a commit hash,
    # checkout the specific git ref, otherwise treat it as a branch name.
    pattern="^[0-9a-f]{40}$"
    if [ "${mversion:0:5}" = "refs/" ] || [[ "${mversion}" =~ $pattern ]]; then
        git clone --no-tags --depth=1 "${mgitrepo}" "$MODULES_GIT_DIR"
        (cd "$MODULES_GIT_DIR" && git fetch origin "${mversion}" && git checkout FETCH_HEAD)
    else
        git clone --no-tags --depth=1 -b "${mversion}" "${mgitrepo}" "$MODULES_GIT_DIR"
    fi
}

# Checkout a shallow kernel tree of the specified tag
git_clone_linux_sources() {
    mkdir -p "$LINUX_GIT_DIR"
    case "${distroversion:-}" in
        el*)
            git clone -b "${ktag}" "${kgitrepo}" src/linux-rpm

            # Get the source files
            pushd src/linux-rpm
            "${WORKSPACE}/src/getsrc/getsrc/getsrc.sh"
            tar -x -C "${LINUX_GIT_DIR}" --strip-components=1 -f SOURCES/linux-*.tar.xz
            popd

            # Pretend we're a repo like the default expects
            pushd "${LINUX_GIT_DIR}"
            git init .
            git config user.name 'Jenkins'
            git config user.email 'jenkins@efficios.com'
            git add .
            git commit -a -m 'Initial commit'
            git tag "${ktag}"
            echo "${LINUX_GIT_REF_REPO_DIR}" > .git/objects/info/alternates
            popd
            ;;

        *)
            git clone --depth=1 -b "${ktag}" --reference-if-able "$LINUX_GIT_REF_REPO_DIR" "${kgitrepo}" "$LINUX_GIT_DIR"
            ;;
    esac
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

# List all GCC versions present in the PATH
list_gccs() {
    local gccs
    gccs=()
    IFS=: read -r -a path_array <<< "$PATH"

    if grep -q "rhel" /etc/os-release ; then
        # EL uses scl w/ gcc-toolset-NN
        # while read -r line ; do
        #   gccs+=("/opt/rh/${line}/root/usr/bin/gcc")
        # done < <(scl list-collections | grep gcc-toolset)
        gccs+=("$(command -v gcc)")
    else
        while read -r gcc ; do
            gccs+=("$gcc")
        done < <(find "${path_array[@]}" -maxdepth 1 -regex '.*/gcc-[0-9\.]+$' -printf '%f\n' | sort -t- -k2 -V -r)
    fi

    echo "${gccs[@]}"
}

# Find the most recent GCC version supported by the kernel sources
select_compiler() {

    # Enter linux source dir
    cd "$LINUX_SRCOBJ_DIR"

    # Get the kernel version using the host toolchain, some cross-compiled arch may be broken
    kversion=$(unset ARCH; unset CROSS_COMPILE; make -s kernelversion)

    if [ "${cross_arch}" = "riscv64" ] && verlt "${kversion}" "5.12"; then
        echo "RISC-V support was upstreamed in kernel v4.19 but kprobes support was only added in v5.12. Don't try to build it."
        exit 0
    fi

    if [ "${cross_arch}" = "arm64" ] && verlt "${kversion}" "3.7"; then
        echo "ARM64 support was added as of v3.7. Don't try to build it."
        exit 0
    fi

    if [ "${cross_arch}" = "arm64" ] && verlt "${kversion}" "3.18"; then
        echo "lttng-modules requires gcc >= 5.1 for ARM64 due to compiler bugs in gcc."
        echo "gcc-5 support was added to the kernel as of v3.18. Don't this to build it."
        exit 0
    fi

    if [ -f "init/Kconfig.suse" ]; then
        # Get values from git tag, eg. 'rpm-5.14.21-150400.24.108'
        # Note: the "150400" type of SUSE major version is only present on tags
        # from 2022 and newer (about half-way through SLE15SP3).
        # This will not work as expected on earlier tags.
        SLES_RELEASE="$(echo "${ktag}" | cut -d '-' -f 3 | cut -d'.' -f 1)"
    fi

    if { verlt "$kversion" "4.4"; }; then
        # Force gcc-4.8 for kernels before 4.4
        selected_cc='gcc-4.8'
        # Due to compiler bugs in gcc on arm64, lttng-modules disallows
        # compilation with gcc < 5.1.
        if [[ "${cross_arch}" == "arm64" ]] ; then
            selected_cc='gcc-5.5'
            export PATH="${PATH:-}:/usr/local/gcc5.5/bin"
            export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:/usr/local/gcc5.5/lib"
        fi
        selected_cc_version=$(echo "${selected_cc}" | cut -d'-' -f2)
    else
        for cc in $(list_gccs) ; do
            if "${CROSS_COMPILE:-}${cc}" -I include/ -D__LINUX_COMPILER_H -D__LINUX_COMPILER_TYPES_H -E include/linux/compiler-gcc.h; then
                if [[ "${cc}" =~ gcc-[0-9]+$ ]]; then
                    cc_version=$(echo "${cc}" | cut -d'-' -f2)
                else
                    cc_version="$("${cc}" --version | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
                fi

                if { verlt "${kversion}" "5.17"; } && { vergt "${cc_version}" "11"; } ; then
                    # Using gcc-12+ with '-Wuse-after-free' breaks the build of older
                    # kernels (in particular, objtool). Some releases on LTS
                    # branches between 4.x and 5.15 can be built with gcc-12.
                    # @see https://lore.kernel.org/lkml/20494.1643237814@turing-police/
                    # @see https://gitlab.com/linux-kernel/stable/-/commit/52a9dab6d892763b2a8334a568bd4e2c1a6fde66
                    # As Debian trixie doesn't ship with gcc-11, try to fiddle with flags instead.
                    # For Debian bookworm, skip this compiler to maintain the same behaviour as
                    # done previously.
                    if command -v lsb_release ; then
                        if { verlt "$(lsb_release --short --release)" "13"; }; then
                            continue
                        fi
                    fi
                fi

                if { verlt "${kversion}" "6.9"; } && { vergt "${cc_version}" "12"; } ; then
                    if [ "${cross_arch}" = "powerpc" ] || [ "${cross_arch}" = "ppc64el" ] ; then
                        # skip this compiler
                        # gcc-13+ properly enforces assembly alignment and not all powerpc
                        # assembly is properly aligned
                        # @see 2d43cc701b96f910f50915ac4c2a0cae5deb734c
                        # @see 39190ac7cff1fd15135fa8e658030d9646fdb5f2
                        continue
                    fi
                fi

                if { verlt "${kversion}" "6.1"; } && { vergt "${cc_version}" "12"; } ; then
                    # Older kernels don't build on gcc-13+
                    # @see https://gcc.gnu.org/bugzilla/show_bug.cgi?id=107405
                    if [ "${cross_arch}" = "armhf" ]; then
                        continue
                    fi
                fi

                selected_cc="$cc"
                #if [[ "${selected_cc}" =~ gcc-toolset-[0-9]+ ]]; then
                #    toolset="$(echo "${selected_cc}" | grep -Eo 'gcc-toolset-[0-9]+')"
                #    # shellcheck disable=SC1091
                #    source scl_source enable "${toolset}"
                #    selected_cc=gcc
                #fi

                selected_cc_version="$cc_version"
                BINUTILS_VERSION="$(get_ld_version)"
                break
            fi
        done
    fi

    if [ -z "${selected_cc:-}" ]; then
      echo "Found no suitable compiler."
      exit 1
    fi

    # lttng-modules requires gcc >= 5.1 for aarch64
    # @see https://github.com/lttng/lttng-modules/commit/be06402dbdbea2f3394e60ec15c5d3356e2be416
    if { verlt "${selected_cc_version}" "5.1"; } && [ "${cross_arch}" = "arm64" ] ; then
        echo "Building lttng-modules on aarch64 requires gcc >= 5.1"
        exit 1
    fi

    cd -
}

get_libc_version() {
    ldd --version | head -n1 | grep -Eo 'GLIBC [0-9]+\.[0-9]+' | cut -d' ' -f2
}

get_ld_version() {
    "${CROSS_COMPILE:-}ld" --version | head -n1 | grep -Eo '[0-9]+\.[0-9]+'
}

export_kbuild_flags() {
    local _KAFLAGS
    local _KCFLAGS
    local _KCPPFLAGS
    local _HOSTCFLAGS

    _KAFLAGS=()
    _KCFLAGS=()
    _KCPPFLAGS=()
    _HOSTCFLAGS=()

    if { vergte "$selected_cc_version" "6"; }; then
        # Older kernel Makefiles do not expect the compiler to default to PIE
        _KAFLAGS+=(-fno-pie)
        _KCFLAGS+=(
            -fno-pie
            -no-pie
            -fno-stack-protector
        )
        _KCPPFLAGS+=(-fno-pie)
    fi

    if { vergte "${selected_cc_version}" "14"; } && [ "${SLES_RELEASE}" == "150500" ]; then
        # This warning didn't happen on deb12 runners w/ gcc-12.
        # kernel/sched/sched.h:3043:32: error: passing argument 1 of ‘cpu_util_cfs’
        # makes pointer from integer without a cast [-Wint-conversion]
        _HOSTCFLAGS+=(-Wno-error=int-conversion)
        _KCFLAGS+=(-Wno-error=int-conversion)
    fi

    if { vergte "${selected_cc_version}" "10"; } && { verlt "${kversion}" "5.10"; } ; then
        # gcc-10 changed the default from '-fcommon' to '-fno-common', which
        # causes a linker failure. '-fcommon' can be set on the HOSTCFLAGS
        # to avoid the issue.
        # @see https://gitlab.com/linux-kernel/stable/-/commit/e33a814e772cdc36436c8c188d8c42d019fda639
        _HOSTCFLAGS+=(-fcommon)
    fi

    if { verlt "${kversion}" "5.14"; } && [ "${cross_arch:-}" == "armhf" ] ; then
        # Work-around for producing instructions that aren't valid for the
        # default architectures.
        # Eg. Error: selected processor does not support `cpsid i' in ARM mode
        _KCFLAGS+=(-march=armv7-a -mfpu=vfpv3-d16)
        _KCPPFLAGS+=(-march=armv7-a -mfpu=vfpv3-d16)
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
}

patch_linux_kernel() {
    local commit_hash
    commit_hash="$1"

    # Show the title of the patch in the build log
    git -C "${LINUX_GIT_REF_REPO_DIR}" show --oneline -s "${commit_hash}"

    # Apply patch, don't fail if it doesn't apply cleanly
    set +e
    git -C "${LINUX_GIT_REF_REPO_DIR}" format-patch -n1 --stdout "${commit_hash}" | patch -p1
    set -e

    if [ "$?" -gt 1 ] ; then
        echo "Serious issue patching"
        exit 1
    fi
}

fetch_ubuntu_versions() {
    local uversion="${1}"
    local arch="${2}"
    local retries=5
    local backoff=0
    local backoff_delta=10
    local output_file
    local endpoint="https://api.launchpad.net/1.0/ubuntu/+archive/primary?ws.op=getPublishedBinaries&binary_name=linux-image-generic&distro_arch_series=https://api.launchpad.net/1.0/ubuntu/${uversion}/${arch}"

    output_file="$(mktemp)"
    if ! test -f "${output_file}" ; then
        echo "Failed to create temp file"
        exit 1
    fi

    ret=
    while [[ "${ret}" != "0" ]]; do
        if [[ "${ret}" != "" ]]; then
            sleep "${backoff}"
            backoff=$((backoff + backoff_delta))
        fi

        curl -o "${output_file}" "${endpoint}"
        ret=$?
    done

    if [[ "${ret}" != "0" ]]; then
        echo "Failed to get ubuntu versions" >&2
        exit 1
    fi

    echo "${output_file}"
}


build_linux_kernel() {
    local libc_version=
    cd "$LINUX_SRCOBJ_DIR"

    kversion=$(make -s kernelversion "${make_args[@]}")
    pahole_version="$(pahole --version | tr -d 'v')"
    libc_version="$(get_libc_version)"

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
      *el*)
        # Copy the EL kernel configuration
        el_arch="${cross_arch:-$arch}"
        case "${el_arch}" in
          amd64)
            el_arch=x86_64
            ;;
          arm64)
            el_arch=aarch64
            ;;
          ppc64el)
            el_arch=ppc64le
            ;;
          *)
            ;;
        esac
        ls "${WORKSPACE}/src/linux-rpm/SOURCES/"
        if [ -f "${WORKSPACE}/src/linux-rpm/SOURCES/kernel-${el_arch}.config" ] ; then
          cp "${WORKSPACE}/src/linux-rpm/SOURCES/kernel-${el_arch}.config" .config
        elif [ -f "${WORKSPACE}/src/linux-rpm/SOURCES/kernel-${el_arch}-rhel.config" ] ; then
          cp "${WORKSPACE}/src/linux-rpm/SOURCES/kernel-${el_arch}-rhel.config" .config
        fi

        # Eg.
        # mm/mempolicy.c: In function ‘mpol_parse_str’:
        # mm/mempolicy.c:2980:26: error: writing 1 byte into a region of size 0 [-Werror=stringop-overflow=]
        KCFLAGS="${KCFLAGS} -Wno-error -Wno-all -Wno-error=stringop-overflow"
        if { vergte "${selected_cc_version}" "9"; }; then
            KCFLAGS="${KCFLAGS} -Wno-error=address-of-packed-member"
        fi

        export KCFLAGS="${KCFLAGS}"
        ;;

      Ubuntu*)
        if [ "${cross_arch}" = "powerpc" ] && vergte "${kversion}" "4.10"; then
          echo "Ubuntu removed big endian powerpc configuration from kernel >= 4.10. Don't try to build it."
          exit 0
        fi

        if [ "${cross_arch}" = "riscv64" ] && verlt "${kversion}" "6.2"; then
          echo "Ubuntu added RISC-V config to their 'regular' kernels in v6.2. Don't try to build it."
          exit 0
        fi

        # A lot of Ubuntu tags don't build against all architectures. Double-check
        # that there is a linux-image for the cross architecture in an archive for
        # the distribution version (e.g. noble).
        if [ -n "${cross_arch:-}" ]; then
            if [ -z "${uversion:-}" ]; then
                echo "uversion not set"
                exit 1
            fi

            # Extract version for package name
            #ubuntu_package_name="linux-image-$(echo "${ktag}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+')-generic"
            version_from_tag="$(echo "${ktag}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+.*' | tr '_' '~')"
            versions_file="$(fetch_ubuntu_versions "${uversion}" "${cross_arch}")"
            versions=()
            while read -r line ; do
                versions+=("${line}")
            done < <(jq -r '.entries[] | select(.pocket != "Proposed") | .binary_package_version' < "${versions_file}" | sort -V | uniq)
            rm -f "${versions_file}"

            found=
            for version in "${versions[@]}" ; do
                if [ "${version}" == "${version_from_tag}" ]; then
                    found=0
                    break
                fi
            done

            if [ -z "${found}" ]; then
                echo "No binary with version '${version_from_tag}' matching tag '${ktag}' found, skipping build" >&2
                echo "Versions:" >&2
                echo "${versions[*]}" >&2
                exit 0
            fi
        fi

        FAKEROOT_ARGS=(
            'KW_DEFCONFIG_DIR=.'
        )
        fakeroot debian/rules clean "${FAKEROOT_ARGS[@]}"

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
        FAKEROOT_ARGS+=('do_skip_checks=true')

        # Some Ubuntu tags default the toolchain using `gcc?=gcc-XX` in
        # `debian/rules.d/0-common-vars.mk`. This may fail if the gcc version
        # used as a default isn't available.
        # For example, Ubuntu-6.8.0-7.7 sets `gcc?=gcc-13`, and that version
        # of gcc isn't available on the deb12-amd64 ci-nodes.
        # Work has also already been done in `select_compiler` to make our
        # own decision of which compiler to use. As a result of both cases,
        # our compiler choice should be passed into genconfigs.
        FAKEROOT_ARGS+=("gcc=${selected_cc}")

        fakeroot debian/rules genconfigs "${FAKEROOT_ARGS[@]}"
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

    case "${kconfig_profile}" in
        default)
            ;;
        nocompat)
            scripts/config --disable CONFIG_COMPAT_32BIT_TIME
            scripts/config --disable CONFIG_COMPAT_BRK
            case "${karch}" in
                arm)
                    ;;
                arm64)
                    scripts/config --disable CONFIG_COMPAT
                    scripts/config --disable CONFIG_COMPAT_32
                    ;;
                x86_64|amd64)
                    scripts/config --disable CONFIG_X86_X32_ABI
                    scripts/config --disable CONFIG_IA32_EMULATION
                    scripts/config --disable CONFIG_COMPAT
                    scripts/config --disable CONFIG_COMPAT_32
                    scripts/config --disable CONFIG_COMPAT_OLD_SIGACTION
                    ;;
                i386|x86)
                    scripts/config --disable CONFIG_COMPAT_OLD_SIGACTION
                    ;;
                powerpc)
                    ;;
                riscv)
                    ;;
                *)
                    echo "kconfig_profile '${kconfig_profile}' doesn't support arch '${karch}'"
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Unknown kconfig_profile: '${kconfig_profile}'"
            exit 1
            ;;
    esac

    if [ -f "init/Kconfig.suse" ] ; then
        scripts/config --set-val CONFIG_SUSE_VERSION $((10#"$(echo "${SLES_RELEASE}" | head -c 2)"))
        scripts/config --set-val CONFIG_SUSE_PATCHLEVEL $((10#"$(echo "${SLES_RELEASE}" | head -c 4 | tail -c 2)"))

        # Disable the renesas clk driver that has build issues,
        # eg. drivers/clk/renesas/renesas-rzg2l-cpg.c:185:17: error: ‘clk’ undeclared (first use in this function)
        scripts/config --disable CONFIG_CLK_RENESAS

        # From drives/spi/spi-atmel.c
        # ./include/linux/gpio/consumer.h:141:49: note: expected ‘struct gpio_desc *’ but argument is of type 'int'
        scripts/config --disable CONFIG_SPI_ATMEL
        scripts/config --disable CONFIG_SPI_AT91_USART
        scripts/config --disable CONFIG_SPI_ATMEL_QUADSPI

        # drivers/net/wireless/mediatek/mt76/mt7915/testmode.c: In function ‘mt7915_tm_set_wmm_qid’:
        # drivers/net/wireless/mediatek/mt76/mt7915/testmode.c:176:30: error: ‘struct mt7915_vif’ has no member named ‘mt76’
        scripts/config --disable CONFIG_WLAN_VENDOR_MEDIATEK

        # drivers/net/wireless/microchip/wilc1000/cfg80211.c: In function ‘wilc_wfi_cfg_parse_ch_attr’:
        # drivers/net/wireless/microchip/wilc1000/cfg80211.c:970:17: error: ‘for’ loop initial declarations are only allowed in C99 or C11 mode
        scripts/config --disable CONFIG_WLAN_VENDOR_MICROCHIP

        # fs/f2fs/file.c: In function ‘punch_hole’:
        # fs/f2fs/file.c:1093:49: error: ‘mapping’ undeclared (first use in this function)
        scripts/config --disable CONFIG_F2FS_FS

        if [[ "${SLES_RELEASE}" == "150500" ]]; then
            # kernel/dma/swiotlb.c:1013:64: error: ‘debugfs_dir’ undeclared (first use in this function)
            scripts/config --set-val CONFIG_DMA_RESTRICTED_POOL n

            # drivers/iommu/apple-dart.c:756:9: error: ‘const struct iommu_domain_ops’ has no member named ‘owner’
            scripts/config --set-val CONFIG_APPLE_DART n

            # drivers/gpu/drm/panel/panel-samsung-atna33xc20.c:134:9: error: implicit declaration of function ‘drm_dp_dpcd_set_powered’
            scripts/config --disable CONFIG_DRM_PANEL_SAMSUNG_ATNA33XC20

            # drivers/net/ethernet/8390/ax88796.c:754:42: error: assignment of read-only location ‘*(dev->dev_addr + (sizetype)i)’
            scripts/config --disable CONFIG_AX88796B_PHY
            scripts/config --disable CONFIG_AX88796
            scripts/config --disable CONFIG_PCMCIA_AXNET

            # rivers/gpu/drm/i915/gt/selftest_slpc.c:73:18: error: implicit declaration of function ‘measure_power’; did you mean ‘measure_power_at’?
            scripts/config --disable CONFIG_DRM_I915

            # There are more broken ethernet drivers
            scripts/config --disable CONFIG_PCMCIA_PCNET
            scripts/config --disable CONFIG_SH_ETH
            scripts/config --disable CONFIG_RAVB

            # s/ntfs/attrib.c:609:56: error: ‘mrec_end’ undeclared (first use in this function)
            scripts/config --disable CONFIG_NTFS_FS
        fi
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

    if { vergte "${BINUTILS_VERSION}" "2.38"; } && { vergte "${selected_cc_version}" "12"; } && [ "${cross_arch}" = "riscv64" ] && { verlt "${kversion}" "5.17"; }; then
        # ./arch/riscv/include/asm/vdso/gettimeofday.h:71: Error: unrecognized opcode
        # `csrr a5,0xc01', extension `zicsr' required
        patch_linux_kernel 6df2a016c0c8a3d0933ef33dd192ea6606b115e3
    fi

    if [ "${cross_arch}" = "powerpc" ] || [ "${cross_arch}" = "ppc64el" ]; then
        if { vergte "${selected_cc_version}" "12";} && { verlt "${kversion}" "5.10"; }; then
            # arch/powerpc/boot/util.S:49: Error: junk at end of line
            patch_linux_kernel 8b14e1dff067195dca7a42321771437cb33a99e9
        fi

        # Preferably not using gcc-13+ with these versions, but attempt to patch as a fallback
        if { vergte "${selected_cc_version}" "13"; }; then
            if { verlt "${kversion}" "6.10"; }; then
                # Error: operand out of domain (19 is not a multiple of 4
                patch_linux_kernel 2d43cc701b96f910f50915ac4c2a0cae5deb734c
            fi

            if { verlt "${kversion}" "6.12"; }; then
                patch_linux_kernel 39190ac7cff1fd15135fa8e658030d9646fdb5f2
            fi
        fi
    fi

    if [ "${cross_arch}" = "armhf" ]; then
        # binutils >= 2.41 stops accepting solaris-style section names for
        # non-SPARC elf targets
        # @see binutils-gdb 4cb88cfae84363cef6ed59d9d458a20ff2e1e893
        # ("PR11601, Solaris assembler compatibility doesn't work")
        #
        if { vergte "${BINUTILS_VERSION}" "2.41"; } && { verlt "${kversion}" "5.5"; }; then
            # arch/arm/mm/proc-v6.S:267: Error: junk at end of line,
            # first unrecognized character is `#'
            patch_linux_kernel 790756c7e0229dedc83bf058ac69633045b1000e
            if [[ "$(find arch/arm -iname '*.S.rej' | wc -l)" -gt "0" ]]; then
                while read -r reject_file ; do
                    base_file="${reject_file%.rej}"
                    sed -i 's/#alloc, #execinstr/"ax"/' "${base_file}"
                    sed -i 's/#alloc/"a"/' "${base_file}"
                done < <(find arch/arm/ -iname '*.S.rej')
            fi

            if { verlt "${kversion}" "4.6"; }; then
                while read -r file ; do
                    sed -i 's/#alloc, #execinstr/"ax"/' "${file}"
                    sed -i 's/#alloc/"a"/' "${file}"
                done < <(find arch/arm -iname 'piggy.*.S')
            fi
       fi
    fi

    if [ "${cross_arch}" = "arm64" ]; then
        if { vergte "${BINUTILS_VERSION}" "2.41"; } && { verlt "${kversion}" "4.5"; }; then
            # binutils >= 2.41 stops accepting solaris-style section names for
            # non-SPARC elf targets
            # @see binutils-gdb 4cb88cfae84363cef6ed59d9d458a20ff2e1e893
            # ("PR11601, Solaris assembler compatibility doesn't work")
            #
            patch_linux_kernel f00083cae331e5d3eecade6b4fdc35d0825e73ef
        fi
    fi

    if { vergte "${kversion}" "6.13"; } && [ "${cross_arch}" = "powerpc" ]; then
        # @see https://lore.kernel.org/lkml/20250218-buildfix-extmod-powerpc-v2-1-1e78fcf12b56@efficios.com/
        sed -i 's#KBUILD_LDFLAGS_MODULE += arch/powerpc/lib/crtsavres.o#KBUILD_LDFLAGS_MODULE += $(objtree)/arch/powerpc/lib/crtsavres.o#' arch/powerpc/Makefile
    fi

    openssl_version="$(pkg-config --modversion openssl)"
    if { verlt "${kversion}" "5.19"; } && { vergt "${openssl_version}" "3.0"; }; then
        # Silence deprecation warnings in sign-file.c
        patch_linux_kernel 6bfb56e93bcef41859c2d5ab234ffd80b691be35
    fi

    if { verlt "${kversion}" "5.17"; } && { vergt "${selected_cc_version}" "11"; } ; then
        # Using gcc-12+ with '-Wuse-after-free' breaks the build of older
        # kernels (in particular, objtool). Some releases on LTS
        # branches between 4.x and 5.15 can be built with gcc-12.
        # @see https://lore.kernel.org/lkml/20494.1643237814@turing-police/
        # @see https://gitlab.com/linux-kernel/stable/-/commit/52a9dab6d892763b2a8334a568bd4e2c1a6fde66
        patch_linux_kernel 52a9dab6d892763b2a8334a568bd4e2c1a6fde66

        # check.c:2836:58: error: ‘%d’ directive output may be truncated writing between 1 and 10
        # bytes into a region of size 9 [-Werror=format-truncation=]
        patch_linux_kernel 82880283d7fcd0a1d20964a56d6d1a5cc0df0713
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

    if { verlt "${kversion}" "5.6"; } && { vergte "${libc_version}" "2.38"; }; then
        # glibc introduces strlcpy, this causes redundant declaration warnings prior to 5.6
        # e.g. tools/include/linux/string.h:17:15: error: redundant redeclaration of ‘strlcpy’ [-Werror=redundant-decls]
        # @see https://gitlab.com/linux-kernel/stable/-/commit/6c4798d3f08b81c2c52936b10e0fa872590c96ae
        patch_linux_kernel 6c4798d3f08b81c2c52936b10e0fa872590c96ae
    fi

    if { vergt "${selected_cc_version}" "7"; } && { vergte "${kversion}" "4.14"; } && { verlt "${kversion}" "4.17"; } ; then
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
        # However, kaslr_64.c doesn't exit in 4.15, 4.16, it's named pagetable.c
        if [ -f arch/x86/boot/compressed/pagetable.c ] ; then
            sed -i '/^unsigned long __force_order;$/d' arch/x86/boot/compressed/pagetable.c
        fi
        if [ -f arch/x86/boot/compressed/kaslr_64.c ] ; then
            patch_linux_kernel df6d4f9db79c1a5d6f48b59db35ccd1e9ff9adfc
        fi
    fi

    if { vergte "${kversion}" "4.18"; } && { verlt "${kversion}" "4.19"; } ; then
        # In some cases, compiling net/bpfilter can fail with the following error:
        #   net/bpfilter/main.c:9:10: fatal error: include/uapi/linux/bpf.h: No such file or directory
        #   make[2]: *** [scripts/Makefile.host:107: net/bpfilter/main.o] Error 1
        #
        # While the issue is potentially in a number of old versions, it has only
        # been observed in v4.18-rt
        #
        patch_linux_kernel 303a339f30a9441c4695d3d2cc78f1b33cd959ff
    fi

    if { vergte "${kversion}" "4.18"; } && { verlt "${kversion}" "4.19"; } ; then
        # In some cases, compiling net/bpfilter can fail with the following error:
        #   net/bpfilter/main.c:9:10: fatal error: include/uapi/linux/bpf.h: No such file or directory
        #   make[2]: *** [scripts/Makefile.host:107: net/bpfilter/main.o] Error 1
        #
        # While the issue is potentially in a number of old versions, it has only
        # been observed in v4.18-rt
        #
        patch_linux_kernel 303a339f30a9441c4695d3d2cc78f1b33cd959ff
    fi

    if { vergte "${kversion}" "4.17"; } && { verlt "${kversion}" "4.18"; } && { vergt "${selected_cc_version}" "13"; }; then
        # In function ‘check_copy_size’,
        # inlined from ‘copy_to_user’ at ./include/linux/uaccess.h:154:6,
        # inlined from ‘afs_proc_rootcell_read’ at fs/afs/proc.c:370:6:
        # ./include/linux/thread_info.h:134:25: error: call to ‘__bad_copy_from’ declared with attribute error: copy source size is too small
        scripts/config --disable CONFIG_AFS_FS
    fi

    if { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.18"; } ; then
        # Some old kernels fail to build when make is too new
        # @see https://gitlab.com/linux-kernel/stable/-/commit/9feeb638cde083c737e295c0547f1b4f28e99583
        patch_linux_kernel 9564a8cf422d7b58f6e857e3546d346fa970191e
    fi

    if { vergte "${kversion}" "4.14"; } && { verlt "${kversion}" "4.14.55"; } ; then
        # Some old kernels fail to build when make is too new
        # @see https://gitlab.com/linux-kernel/stable/-/commit/9feeb638cde083c737e295c0547f1b4f28e99583
        patch_linux_kernel e82885490a611f2b75a6c27cd7bb09665c1740be
    fi

    if ( { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.18"; } ) || \
       ( { vergte "${kversion}" "4.14"; } && { verlt "${kversion}" "4.14.56"; } ) ; then
        # Some old kernels fail to build when make is too new
        # @see https://gitlab.com/linux-kernel/stable/-/commit/9feeb638cde083c737e295c0547f1b4f28e99583
        patch_linux_kernel 9feeb638cde083c737e295c0547f1b4f28e99583
    fi

    if ( { vergte "${kversion}" "4.12"; } && { verlte "${kversion}" "4.20.17"; } ) || \
       ( { vergte "${kversion}" "5.0"; } && { verlt "${kversion}" "5.0.12"; } ) ; then
        # Old kernels can fail to build while on newer host kernels with errors
        # such as:
        #   In file included from scripts/selinux/genheaders/genheaders.c:19:
        #   ./security/selinux/include/classmap.h:249:2: error: #error New address family defined, please update secclass_map.
        # @see https://gitlab.com/linux-kernel/stable/-/commit/dfbd199a7cfe3e3cd8531e1353cdbd7175bfbc5e
        #
        patch_linux_kernel dfbd199a7cfe3e3cd8531e1353cdbd7175bfbc5e
    fi

    # Compatibility with binutils >= ~ 2.31
    if { vergte "${kversion}" "3.19"; } && { verlt "${kversion}" "4.16"; } ; then
        patch_linux_kernel b21ebf2fb4cde1618915a97cc773e287ff49173e
    fi
    if { vergte "${kversion}" "3.17"; } && { verlt "${kversion}" "3.18.69"; } ; then
        patch_linux_kernel edb9d2d5e647e7a8521b0d35f8452deb02dfd138
    fi
    if { vergte "${kversion}" "3.17"; } && { verlt "${kversion}" "3.18.100"; } ; then
        patch_linux_kernel 3be6583f0b6f1bf1ee650ebf473d9dee36836527
        patch_linux_kernel 12d839211d080f6a9c370398c41a260365d34c62
    fi
    if { vergte "${kversion}" "3.16"; } && { verlt "${kversion}" "3.16.82"; } ; then
        patch_linux_kernel ad10e6d464796f2a481de4039a43b9cfca034e1c
    fi

    if ( { vergte "${kversion}" "3.14"; } && { verlt "${kversion}" "4.4"; } ) ||
       ( { vergte "${kversion}" "4.8"; } && { verlt "${kversion}" "4.18"; } ); then
        # While the original motivation of this patch is for fixing builds using
        # clang, the same error occurs between linux >= 3.14 and < 4.4, and in
        # 4.15, 4.16.
        # For rt-linux, the error has been observed in 4.8, 4.11, and 4.13.
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

    if { vergte "${kversion}" "4.5"; } && { verlt "${kversion}" "4.8"; } ; then
        # Kernels between v4.5 and v4.8 built with gcc >= 8 on arm will hit an
        # assembler error :
        #
        #  kernel/.tmp_fork.s: Assembler messages:
        #  kernel/.tmp_fork.s:1790: Error: .err encountered
        #
        # @see https://gcc.gnu.org/bugzilla/show_bug.cgi?id=85745
        #
        patch_linux_kernel 9f73bd8bb445e0cbe4bcef6d4cfc788f1e184007
    fi

    if ( { vergte "${kversion}" "4.4"; } && { verlt "${kversion}" "4.4.136"; } ) ||
       ( { vergte "${kversion}" "4.5"; } && { verlt "${kversion}" "4.8"; } ); then
        # Hacky patch to deal with the following build error:
        #   Cannot find symbol for section 7: .text.unlikely.
        #   kernel/kexec_file.o: failed
        #   make[1]: *** [scripts/Makefile.build:291: kernel/kexec_file.o] Error 1
        #
        # This error happens with binutils 2.36 and 2.37, but should probably not
        # be an issue with binutils 2.38.
        # @see https://github.com/linuxppc/issues/issues/388
        # @see https://github.com/bminor/binutils-gdb/commit/c09c8b42021180eee9495bd50d8b35e683d3901b
        #
        # There is some sort of config (unspecified in past discussions) which
        # provokes the error, and there was never a potential fix merged in
        # this discussion, in part because the build systems of the kernel
        # switched to objtool instead.
        #
        # @see https://lore.kernel.org/all/20210215162209.5e2a475b@gandalf.local.home/
        #
        sed -i 's/return txtname;/return shdr0->sh_size ? txtname : NULL;/' scripts/recordmcount.h

        # After applying the above patch, the build continues but fails with
        # head64.c:(.text.exit+0x5): undefined reference to `__gcov_exit'
        #
        scripts/config --disable CONFIG_GCOV_KERNEL
    fi

    if { vergte "${kversion}" "4.5"; } && { verlt "${kversion}" "4.5.5"; } ; then
        # drivers/staging/wilc1000/wilc_spi.c:123:34: error: storage size of ‘wilc1000_spi_ops’ isn’t known
        patch_linux_kernel ce7b516f3f9e11fe4ee06fad0d7e853bb6e8f160
    fi

    # Newer binutils don't accept 3 operand 'cmp' instructions on ppc64
    # Convert them to 'cmpw' which was previously done silently
    if verlt "$kversion" "4.9"; then
        find arch/powerpc/ -name "*.S" -print0 | xargs -0 sed -i "s/\(cmp\)\(\s\+[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+\)/cmpw\2/"
        find arch/powerpc/ -name "*.S" -print0 | xargs -0 sed -i "s/\(cmpli\)\(\s\+[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+,\s*[a-zA-Z0-9]\+\)/cmplwi\2/"
        sed -i "s/\$pie \-o \"\$ofile\"/\$pie --no-dynamic-linker -o \"\$ofile\"/" arch/powerpc/boot/wrapper
    fi

    if [ "$(scripts/config --state CONFIG_EXTCON_ADC_JACK)" != "n" ] &&
           ( { vergte "${kversion}" "4.2"; } && { verlt "${kversion}" "4.12"; } ); then
        # 73b6ecdb93e8e77752cae9077c424fcdc6f23c39 introduced a change where
        # extcon-adc-jack.h has an incompatible pointer type.
        # In GCC >= 5 this will provoke a warning and build failure.
        # Eg.
        #   drivers/extcon/extcon-adc-jack.c: In function ‘adc_jack_probe’:
        #   drivers/extcon/extcon-adc-jack.c:111:64: error: passing argument 2 of ‘devm_extcon_dev_allocate’ from incompatible pointer type [-Werror=incompatible-pointer-types]
        #   make[2]: *** [scripts/Makefile.build:295: drivers/extcon/extcon-adc-jack.o] Error 1
        #
        # 8a522bf2d4f788306443d36b26b54f0aedcdfdbe (in 4.11) has a fix for this warning
        #
        patch_linux_kernel 8a522bf2d4f788306443d36b26b54f0aedcdfdbe
    fi

    if ( { vergte "${kversion}" "4.15"; } && { verlt "${kversion}" "4.15.2"; } ) || \
       ( { vergte "${kversion}" "4.14"; } && { verlt "${kversion}" "4.14.18"; } ) ; then
        # Fix an objtool Segmentation fault
        patch_linux_kernel dd12561854824fd1f05baf2a1b794faa046e2425
    fi

    if { vergte "${kversion}" "4.14"; } && { verlt "${kversion}" "4.14.268"; } ; then
        # Builds fail due to -Werror=use-after-free in sigchain.o and help.o
        patch_linux_kernel e89bb266b710ce056f141f29f091fd468a4a8185
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
           (
               ( { vergte "${kversion}" "5.10"; } && { verlt "${kversion}" "6.0"; } ) || [[ "${ktag}" =~ .el8 ]]
           ) ; then
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
            # shellcheck disable=SC2016
            sed -i 's/ -J ${PAHOLE_FLAGS} / -J ${PAHOLE_FLAGS} --skip_encoding_btf_enum64 /' scripts/link-vmlinux.sh
        else
            # shellcheck disable=SC2016
            sed -i 's/ -J ${extra_paholeopt} / -J ${extra_paholeopt} --skip_encoding_btf_enum64 /' scripts/link-vmlinux.sh
            # Some older versions of RHEL don't have '${extra_paholeopt}'
            sed -i 's/${PAHOLE} -J ${1}/${PAHOLE} -J --skip_encoding_btf_enum64 ${1}/' scripts/link-vmlinux.sh
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


    # IGBVF won't build with recent gcc on 2.6.38.2
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

    # Starting in linux 6.9-rc1, TRIM_UNUSED_SYMS seems to be true
    # for out build configurations. In earlier versions the default
    # was set depending on the value of `COMPILE_TEST`.
    # See upstream commit d2d5cba5d92c4ed23caa86228a1bc31b07e90fe9.
    scripts/config --disable CONFIG_TRIM_UNUSED_KSYMS

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

    # On riscv with 5.14 the vsdo objects are required
    if [ "${karch}" = "riscv" ] && \
           ( { vergte "${kversion}" "5.14"; } && { verlt "${kversion}" "5.15"; } ); then
            cp -a --parents arch/riscv/kernel/vdso/*.o "${LINUX_HDROBJ_DIR}/"
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
      rpm-*)
        # Update the definition of UTS_RELEASE to match something akin to '5.14.21-150400.24.108-default'
        if [ -f "init/Kconfig.suse" ] ; then
          SLESVERSION="$(echo "${ktag}" | cut -d'-' -f 3)-default"
          sed -E -i "s%^(#define UTS_RELEASE \"[\.a-z0-9]+)(\")%\1-${SLESVERSION}\2%g" include/generated/utsrelease.h
          sed -E -i "s%^(#define UTS_RELEASE \"[\.a-z0-9]+)(\")%\1-${SLESVERSION}\2%g" "${LINUX_HDROBJ_DIR}/include/generated/utsrelease.h"
        fi
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

    # Try to catch some compatibility problems by turning some
    # warnings into errors, but only on -rc kernels.
    pattern="rc[0-9]+$"
    if [[ "${kversion}" =~ ${pattern} ]] || [[ -n "${FAIL_ON_WARNINGS:-}" ]] ; then
        export KCFLAGS="${KCFLAGS} -Wall -Werror"
        # Without the verbose build, the warnings aren't visible.
        export V=1
    fi

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

print_header "Clone LTTng-modules sources"
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

        "riscv64")
            karch="riscv"
            cross_compile="riscv64-linux-gnu-"
            vanilla_config="defconfig"
            ubuntu_config="riscv64-config.flavour.generic"
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

        "riscv64")
            karch="riscv"
            vanilla_config="allmodconfig"
            ubuntu_config="riscv64-config.flavour.generic"
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

set +x
echo "# Setup endpoint
host_base = obj2.internal.efficios.com
host_bucket = obj2.internal.efficios.com
use_https = True

# Setup access keys
access_key = GKe5a61b33d45c0b4b107d7f56
secret_key = a886e12457cad34169acc7324f3304a73b5a7e922a3b8c6e761e7e0d3f7f8a86

# Enable S3 v4 signature APIs
signature_v2 = False" > "$WORKSPACE/.s3cfg"
set -x

url_hash="$(echo -n "$kgitrepo" | md5sum | awk '{ print $1 }')"
obj_name="linux.tar.bz2"
if [[ "${kconfig_profile}" != "default" ]]; then
    obj_name="${kconfig_profile}-${obj_name}"
fi

if [ -z "${cross_arch}" ]; then
    obj_url_prefix="$OBJ_STORE_URL/linux-build/$url_hash/$ktag/platform-${platform}/$arch/native"
else
    obj_url_prefix="$OBJ_STORE_URL/linux-build/$url_hash/$ktag/platform-${platform}/${cross_arch}"
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
      print_header "Get sources and prebuilt kernel"
      s3cmd -c "$WORKSPACE/.s3cfg" get "$obj_url"
      extract_archive_obj

      print_header "Select compiler and set build flags"
      select_compiler
      export_kbuild_flags
      ;;

    "12")
      print_header "Clone kernel sources"

      # Build all the things and upload
      # then finish the module build...

      git_clone_linux_sources
      git_export_linux_sources

      print_header "Select compiler and set build flags"
      select_compiler
      export_kbuild_flags

      ## PREPARE FULL LINUX SOURCE TREE
      print_header "Build kernel from source"
      build_linux_kernel

      ## EXTRACT DISTRO STYLE KERNEL HEADERS / DEVEL
      extract_distro_headers

      print_header "Upload kernel to object storage"
      tar_archive_obj
      upload_archive_obj

      ;;

    *)
      echo "Unknown error? Abort"
      exit 1
      ;;
esac


## BUILD modules
# Either we downloaded a pre-build kernel or we built it and uploaded
# the archive for future builds.

cd "$WORKSPACE"

print_header "Build modules against full kernel sources"
build_modules "${LINUX_SRCOBJ_DIR}" "${MODULES_OUTPUT_KSRC_DIR}"

print_header "Build modules against kernel headers"
build_modules "${LINUX_HDROBJ_DIR}" "${MODULES_OUTPUT_KHDR_DIR}"


print_header "Check for built modules in install directory"

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
