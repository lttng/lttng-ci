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

LTTNG_CI_PATH="$WORKSPACE/src/lttng-ci"
echo "LTTNG_CI_PATH=$LTTNG_CI_PATH" >> properties.txt
KERNEL_COMMIT_ID=$KERNEL_TAG_ID

echo "KERNEL_COMMIT_ID=$KERNEL_COMMIT_ID" >> properties.txt
echo "LTTNG_MODULES_COMMIT_ID=$LTTNG_MODULES_COMMIT_ID" >> properties.txt
echo "LTTNG_TOOLS_COMMIT_ID=$LTTNG_TOOLS_COMMIT_ID" >> properties.txt
echo "LTTNG_UST_COMMIT_ID=$LTTNG_UST_COMMIT_ID" >> properties.txt

BASE_STORAGE_FOLDER="/storage/jenkins-lava/baremetal-tests"

echo "BASE_STORAGE_FOLDER=$BASE_STORAGE_FOLDER" >> properties.txt
echo "STORAGE_HOST=storage.internal.efficios.com" >> properties.txt
echo "STORAGE_USER=jenkins-lava" >> properties.txt

echo "BUILD_DEVICE=$BUILD_DEVICE" >> properties.txt
echo "KGITREPO=$KERNEL_REPO" >> properties.txt
echo "STORAGE_KERNEL_FOLDER=$BASE_STORAGE_FOLDER/kernel" >> properties.txt
echo "STORAGE_KERNEL_IMAGE=$BASE_STORAGE_FOLDER/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage" >> properties.txt
echo "STORAGE_LINUX_MODULES=$BASE_STORAGE_FOLDER/modules/linux/$KERNEL_COMMIT_ID.$BUILD_DEVICE.linux.modules.tar.gz" >> properties.txt
echo "STORAGE_LTTNG_MODULES=$BASE_STORAGE_FOLDER/modules/lttng/$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID.$BUILD_DEVICE.lttng.modules.tar.gz" >> properties.txt
