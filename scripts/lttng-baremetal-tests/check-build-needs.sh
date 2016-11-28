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

$SSH_COMMAND "$STORAGE_USER@$STORAGE_HOST" ls "$STORAGE_LTTNG_MODULES"
if [ $? -ne 0 ]; then
  NEED_MODULES_BUILD=1
fi
set -e

# We need to fetch the kernel source and lttng-modules to build either the
# kernel or modules
if [ $NEED_MODULES_BUILD -eq 1 ] || [ $NEED_KERNEL_BUILD -eq 1 ] ; then

  git clone "$KGITREPO" "$LINUX_PATH"
  pushd "$LINUX_PATH"
  git checkout "$KERNEL_COMMIT_ID"
  popd
  git clone "$LTTNG_MODULES_GIT" "$LTTNG_MODULES_PATH"
  pushd "$LTTNG_MODULES_PATH"
  git checkout "$LTTNG_MODULES_COMMIT_ID"
  popd

  git clone https://github.com/lttng/lttng-ci "$LTTNG_CI_PATH"
  cp "$LTTNG_CI_PATH"/lava/kernel/vanilla/x86_64_server.config "$LINUX_PATH/.config"
  make --directory="$LINUX_PATH" olddefconfig

  if [ $BUILD_DEVICE = 'kvm' ] ; then
    make --directory="$LINUX_PATH" kvmconfig
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
