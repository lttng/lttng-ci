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

touch properties.txt
if [ -n "${UST_BRANCH+x}" ]; then
  LTTNG_UST_PATH="$WORKSPACE/src/lttng-ust"
  git clone https://github.com/lttng/lttng-ust "$LTTNG_UST_PATH"

  pushd "$LTTNG_UST_PATH"
  git checkout "$UST_BRANCH"
  popd

  LTTNG_UST_COMMIT_ID="$(git --git-dir="$LTTNG_UST_PATH"/.git/ --work-tree="$LTTNG_UST_PATH" rev-parse --short HEAD)"
  echo "LTTNG_UST_PATH=$LTTNG_UST_PATH" >> properties.txt
  echo "LTTNG_UST_COMMIT_ID=$LTTNG_UST_COMMIT_ID" >> properties.txt
fi

LTTNG_CI_PATH="$WORKSPACE/src/lttng-ci"
LINUX_PATH="$WORKSPACE/src/linux"
LTTNG_MODULES_PATH="$WORKSPACE/src/lttng-modules"
LTTNG_TOOLS_PATH="$WORKSPACE/src/lttng-tools"

echo "LTTNG_CI_PATH=$LTTNG_CI_PATH" >> properties.txt
echo "LINUX_PATH=$LINUX_PATH" >> properties.txt
echo "LTTNG_MODULES_PATH=$LTTNG_MODULES_PATH" >> properties.txt
echo "LTTNG_TOOLS_PATH=$LTTNG_TOOLS_PATH" >> properties.txt

KERNEL_COMMIT_ID="$(git --git-dir="$LINUX_PATH"/.git/ --work-tree="$LINUX_PATH" rev-parse --short HEAD)"
LTTNG_MODULES_COMMIT_ID="$(git --git-dir="$LTTNG_MODULES_PATH"/.git/ --work-tree="$LTTNG_MODULES_PATH" rev-parse --short HEAD)"
LTTNG_TOOLS_COMMIT_ID="$(git --git-dir="$LTTNG_TOOLS_PATH"/.git/ --work-tree="$LTTNG_TOOLS_PATH" rev-parse --short HEAD)"

KERNEL_VERSION="$(make -s --directory=$LINUX_PATH kernelversion | sed 's/\./_/g; s/-/_/g';)"

echo "KERNEL_COMMIT_ID=$KERNEL_COMMIT_ID" >> properties.txt
echo "LTTNG_MODULES_COMMIT_ID=$LTTNG_MODULES_COMMIT_ID" >> properties.txt
echo "LTTNG_TOOLS_COMMIT_ID=$LTTNG_TOOLS_COMMIT_ID" >> properties.txt

BASE_STORAGE_FOLDER="/storage/jenkins-lava/baremetal-tests"

echo "BASE_STORAGE_FOLDER=$BASE_STORAGE_FOLDER" >> properties.txt
echo "STORAGE_HOST=storage.internal.efficios.com" >> properties.txt
echo "STORAGE_USER=jenkins-lava" >> properties.txt

echo "BUILD_DEVICE=$BUILD_DEVICE" >> properties.txt
echo "KGITREPO=git://git-mirror.internal.efficios.com/git/linux-stable.git" >> properties.txt
echo "STORAGE_KERNEL_FOLDER=$BASE_STORAGE_FOLDER/kernel" >> properties.txt
echo "STORAGE_KERNEL_IMAGE=$BASE_STORAGE_FOLDER/kernel/$KERNEL_VERSION-$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage" >> properties.txt
echo "STORAGE_LINUX_MODULES=$BASE_STORAGE_FOLDER/modules/linux/$KERNEL_VERSION-$KERNEL_COMMIT_ID.$BUILD_DEVICE.linux.modules.tar.gz" >> properties.txt
echo "STORAGE_LTTNG_MODULES=$BASE_STORAGE_FOLDER/modules/lttng/$KERNEL_VERSION-$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID.$BUILD_DEVICE.lttng.modules.tar.gz" >> properties.txt

