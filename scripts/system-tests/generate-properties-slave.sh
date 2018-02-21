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

# Use all CPU cores
NPROC=$(nproc)
echo "NPROC=$NPROC" >> properties.txt

LINUX_PATH="$WORKSPACE/src/linux"
LTTNG_MODULES_PATH="$WORKSPACE/src/lttng-modules"

echo "LTTNG_MODULES_GIT=$LTTNG_MODULES_REPO" >> properties.txt
echo "LINUX_PATH=$LINUX_PATH" >> properties.txt
echo "LTTNG_MODULES_PATH=$LTTNG_MODULES_PATH" >> properties.txt

DEPLOYDIR="$WORKSPACE/deploy"
MODULES_INSTALL_FOLDER="$DEPLOYDIR/modules"

echo "DEPLOYDIR=$DEPLOYDIR" >> properties.txt
echo "MODULES_INSTALL_FOLDER=$MODULES_INSTALL_FOLDER" >> properties.txt

BUILD_NAME="$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID"

echo "KERNEL_COMMIT_ID=$KERNEL_COMMIT_ID" >> properties.txt
echo "LTTNG_MODULES_COMMIT_ID=$LTTNG_MODULES_COMMIT_ID" >> properties.txt
echo "BUILD_NAME=$BUILD_NAME" >> properties.txt
echo "BUILD_DEVICE=$BUILD_DEVICE" >> properties.txt

echo "STORAGE_KERNEL_MODULE_SYMVERS=$STORAGE_KERNEL_FOLDER/symvers/$KERNEL_COMMIT_ID.$BUILD_DEVICE.symvers" >>properties.txt
echo "STORAGE_KERNEL_CONFIG=$STORAGE_KERNEL_FOLDER/config/$KERNEL_COMMIT_ID.$BUILD_DEVICE.config" >> properties.txt

echo "STORAGE_HOST=storage.internal.efficios.com" >> properties.txt
echo "STORAGE_USER=jenkins-lava" >> properties.txt

echo SSH_COMMAND="ssh -oStrictHostKeyChecking=no -i $identity_file" >> properties.txt
echo SCP_COMMAND="scp -oStrictHostKeyChecking=no -i $identity_file" >> properties.txt
