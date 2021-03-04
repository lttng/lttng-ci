#!/bin/bash -xeu
# Copyright (C) 2016 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

# Version compare functions
vercomp () {
    set +u
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
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

verlte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "2" ]
}

verlt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "2" ]
}

vergte() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "0" ] || [ "$res" -eq "1" ]
}

vergt() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -eq "1" ]
}

verne() {
    vercomp "$1" "$2"; local res="$?"
    [ "$res" -ne "0" ]
}

mkdir -p "$DEPLOYDIR"

NEED_MODULES_BUILD=0
NEED_KERNEL_BUILD=0

set +e
$SSH_COMMAND "$STORAGE_USER@$STORAGE_HOST" ls "$STORAGE_KERNEL_IMAGE"
if [ $? -ne 0 ]; then
  NEED_KERNEL_BUILD=1
  # We need to build the lttng modules if the kernel has changed.
  NEED_MODULES_BUILD=1
fi

$S3_COMMAND info "s3://$S3_STORAGE_KERNEL_IMAGE"
if [ $? -ne 0 ]; then
  NEED_KERNEL_BUILD=1
  # We need to build the lttng modules if the kernel has changed.
  NEED_MODULES_BUILD=1
fi

$SSH_COMMAND "$STORAGE_USER@$STORAGE_HOST" ls "$STORAGE_LTTNG_MODULES"
if [ $? -ne 0 ]; then
  NEED_MODULES_BUILD=1
fi

$S3_COMMAND info "s3://$S3_STORAGE_LTTNG_MODULES"
if [ $? -ne 0 ]; then
  NEED_MODULES_BUILD=1
fi

set -e

# We need to fetch the kernel source and lttng-modules to build either the
# kernel or modules
if [ $NEED_MODULES_BUILD -eq 1 ] || [ $NEED_KERNEL_BUILD -eq 1 ] ; then
  mkdir -p "$LINUX_PATH"
  pushd "$LINUX_PATH"
  git init
  git remote add origin "$KGITREPO"
  git fetch --depth 1 origin "$KERNEL_COMMIT_ID"
  git checkout FETCH_HEAD
  version=$(make -s kernelversion)
  popd


  # Prepare version string for comparison.
  # Strip any '-rc tag'.
  version=${version%%"-"*}

  cp src/lttng-ci/lava/kernel/vanilla/x86_64_server.config "$LINUX_PATH/.config"
  make --directory="$LINUX_PATH" olddefconfig

  if [ $BUILD_DEVICE = 'kvm' ] ; then
    if vergte "$version" "3.19"; then
      make --directory="$LINUX_PATH" kvm_guest.config
    else
      make --directory="$LINUX_PATH" kvmconfig
    fi
  fi

  make --directory="$LINUX_PATH" modules_prepare
fi

#We create files to specify what needs to be built for the subsequent build steps
if [ $NEED_MODULES_BUILD -eq 0 ] ; then
  touch modules-built.txt
fi
if [ $NEED_KERNEL_BUILD -eq 0 ] ; then
  touch kernel-built.txt
fi
