#!/bin/bash
#
# SPDX-FileCopyrightText: 2016 Francis Deslauriers <francis.deslauriers@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    # Ignore the shellcheck warning, we want splitting to happen based on IFS.
    # shellcheck disable=SC2206
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [[ -z ${ver2[i]} ]]; then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            return 2
        fi
    done
    set -u
    return 0
}

# Shellcheck flags the following functions that are unused as "unreachable",
# ignore that.

# shellcheck disable=SC2317
verlte() {
    vercomp "$1" "$2"
    local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

# shellcheck disable=SC2317
verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

# shellcheck disable=SC2317
vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317
vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

# shellcheck disable=SC2317
verne() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -ne "0" ]
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

# Variables from the job parameters.
#
# 'LTTNG_MODULES_COMMIT_ID': 'The lttng-modules commmit to build.'
# 'LTTNG_MODULES_REPO': 'The LTTng Modules git repo to fetch from'
# 'KERNEL_COMMIT_ID': 'The kernel commit to build.'
# 'KERNEL_REPO': 'The kernel git repo to fetch from'
# 'BUILD_DEVICE': 'The target device. (kvm or baremetal)'
# 'LTTNG_CI_REPO': 'lttng-ci git repo to checkout the CI scripts'
# 'LTTNG_CI_BRANCH': 'The branch of the lttng-ci repo to clone for job scripts'
# 'S3_HOST': 'Host for the s3 object storage'
# 'S3_BUCKET': 'Bucket for the s3 object storage'
# 'S3_BASE_DIR': 'Base directory for the s3 object storage'
# 'S3_HTTP_BUCKET_URL': 'Base url to access the s3 bucket over unauthenticated HTTP'


# Use all CPU cores
NPROC=$(nproc)

LINUX_GIT_REF_REPO_DIR="$HOME/gitcache/linux-stable.git/"
LINUX_GIT_DIR="$WORKSPACE/src/linux"
MODULES_GIT_DIR="$WORKSPACE/src/lttng-modules"

OUTPUTDIR="$WORKSPACE/out"
MODULES_INSTALL_DIR="$OUTPUTDIR/modules"
BUILD_NAME="$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID"

S3_KERNEL_MODULE_SYMVERS=$S3_BUCKET/$S3_BASE_DIR/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.symvers
S3_KERNEL_CONFIG=$S3_BUCKET/$S3_BASE_DIR/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.config
S3_KERNEL_IMAGE=$S3_BUCKET/$S3_BASE_DIR/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage
S3_LINUX_MODULES=$S3_BUCKET/$S3_BASE_DIR/modules/$KERNEL_COMMIT_ID.$BUILD_DEVICE.linux.modules.tar.xz
S3_LTTNG_MODULES=$S3_BUCKET/$S3_BASE_DIR/modules/$BUILD_NAME.$BUILD_DEVICE.lttng.modules.tar.xz

S3CMD_CONFIG="${WORKSPACE}/s3cfg"

NEED_MODULES_BUILD=0
NEED_KERNEL_BUILD=0

# Create the credential file to access the object storage with s3cmd
echo "# Setup endpoint
host_base = $S3_HOST
host_bucket = $S3_HOST
use_https = True

# Setup access keys
access_key = $S3_ACCESS_KEY
secret_key = $S3_SECRET_KEY

# Enable S3 v4 signature APIs
signature_v2 = False" > "$S3CMD_CONFIG"

print_header "Check for pre-built artifacts"

if ! s3cmd -c "$S3CMD_CONFIG" info "s3://$S3_KERNEL_IMAGE"; then
  NEED_KERNEL_BUILD=1
  # We need to build the lttng modules if the kernel has changed.
  NEED_MODULES_BUILD=1
elif ! s3cmd -c "$S3CMD_CONFIG" info "s3://$S3_LTTNG_MODULES"; then
  NEED_MODULES_BUILD=1
fi

# Create the temporary output dir
mkdir -p "$OUTPUTDIR"

# We need to fetch the kernel source and lttng-modules to build either the
# kernel or modules
if [ $NEED_MODULES_BUILD -eq 1 ] || [ $NEED_KERNEL_BUILD -eq 1 ] ; then
    print_header "Checkout linux sources from git"

    git clone --quiet --no-tags --depth=1 --reference-if-able "$LINUX_GIT_REF_REPO_DIR" "$KERNEL_REPO" "$LINUX_GIT_DIR"
    git -C "$LINUX_GIT_DIR" fetch origin "$KERNEL_COMMIT_ID"
    git -C "$LINUX_GIT_DIR" checkout FETCH_HEAD

    print_header "Prepare the linux source tree"

    # Get the kernel version from the source tree
    kversion=$(make -C "$LINUX_GIT_DIR" -s kernelversion)

    # Prepare version string for comparison.  Strip any '-rc tag'.
    kversion=${kversion%%"-"*}

    # Configure the kernel
    cp src/lttng-ci/lava/kernel/vanilla/x86_64_server.config "$LINUX_GIT_DIR/.config"
    make --directory="$LINUX_GIT_DIR" olddefconfig

    # Add the kvm_guest fragment when running on kvm
    if [ "$BUILD_DEVICE" = 'kvm' ] ; then
        if vergte "$kversion" "3.19"; then
            make --directory="$LINUX_GIT_DIR" kvm_guest.config
        else
            make --directory="$LINUX_GIT_DIR" kvmconfig
        fi
    fi

    make --directory="$LINUX_GIT_DIR" -j"$NPROC" modules_prepare
fi

# Build the kernel
if [ $NEED_KERNEL_BUILD -eq 1 ] ; then
    print_header "Build the linux kernel"

    make --directory="$LINUX_GIT_DIR" -j"$NPROC" bzImage modules
    make --directory="$LINUX_GIT_DIR" INSTALL_MOD_PATH="$MODULES_INSTALL_DIR" modules_install

    cp "$LINUX_GIT_DIR"/arch/x86/boot/bzImage "$OUTPUTDIR"/"$KERNEL_COMMIT_ID".bzImage
    cp "$LINUX_GIT_DIR"/.config "$OUTPUTDIR"/"$KERNEL_COMMIT_ID".config

    tar -cJf "$OUTPUTDIR/$KERNEL_COMMIT_ID.linux.modules.tar.xz" -C "$MODULES_INSTALL_DIR/" lib/

    print_header "Upload the kernel to object storage"

    s3cmd -c "$S3CMD_CONFIG" put "$OUTPUTDIR/$KERNEL_COMMIT_ID.bzImage" s3://"$S3_KERNEL_IMAGE"
    s3cmd -c "$S3CMD_CONFIG" put "$OUTPUTDIR/$KERNEL_COMMIT_ID.config" s3://"$S3_KERNEL_CONFIG"
    s3cmd -c "$S3CMD_CONFIG" put "$OUTPUTDIR/$KERNEL_COMMIT_ID.linux.modules.tar.xz" s3://"$S3_LINUX_MODULES"
    s3cmd -c "$S3CMD_CONFIG" put "$LINUX_GIT_DIR/Module.symvers" s3://"$S3_KERNEL_MODULE_SYMVERS"
fi

# Build lttng-modules
if [ $NEED_MODULES_BUILD -eq 1 ] ; then
    print_header "Checkout lttng-modules sources from git"

    git clone --quiet --no-tags --depth=1 "$LTTNG_MODULES_REPO" "$MODULES_GIT_DIR"
    git -C "$MODULES_GIT_DIR" fetch origin "$LTTNG_MODULES_COMMIT_ID"
    git -C "$MODULES_GIT_DIR" checkout FETCH_HEAD

    # Get the Modules.symver if we don't already have it from a local build
    s3cmd -c "$S3CMD_CONFIG" get --skip-existing s3://"$S3_KERNEL_MODULE_SYMVERS" "$LINUX_GIT_DIR/Module.symvers"

    print_header "Build lttng-modules"

    KERNELDIR="$LINUX_GIT_DIR" make -j"$NPROC" --directory="$MODULES_GIT_DIR"
    KERNELDIR="$LINUX_GIT_DIR" make -j"$NPROC" --directory="$MODULES_GIT_DIR" modules_install INSTALL_MOD_PATH="$MODULES_INSTALL_DIR"

    # Extract the upstream linux kernel modules to MODULES_INSTALL_DIR.
    # The resulting tarball will contain both lttng-modules and linux modules needed
    # for testing
    s3cmd -c "$S3CMD_CONFIG" get "s3://$S3_LINUX_MODULES"
    tar -xvf "$(basename "$S3_LINUX_MODULES")" -C "$MODULES_INSTALL_DIR"

    tar -cJf "$OUTPUTDIR/$BUILD_NAME.lttng.modules.tar.xz" -C "$MODULES_INSTALL_DIR/" lib/

    # Push the combined upstream kernel and lttng modules to object storage
    s3cmd -c "$S3CMD_CONFIG" put "$OUTPUTDIR/$BUILD_NAME.lttng.modules.tar.xz" s3://"$S3_LTTNG_MODULES"
fi

# Clean the temporary output dir
rm -rf "$OUTPUTDIR"
