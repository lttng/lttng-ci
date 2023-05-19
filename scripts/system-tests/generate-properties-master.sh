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

echo "# Setup endpoint
host_base = obj.internal.efficios.com
host_bucket = obj.internal.efficios.com
bucket_location = us-east-1
use_https = True

# Setup access keys
access_key = jenkins
secret_key = echo123456

# Enable S3 v4 signature APIs
signature_v2 = False" > "$WORKSPACE/s3cfg"

echo "LAVA_HOST=$LAVA_HOST" >> properties.txt
echo "LAVA_PROTO=$LAVA_PROTO" >> properties.txt

LTTNG_CI_PATH="$WORKSPACE/src/lttng-ci"
echo "LTTNG_CI_PATH=$LTTNG_CI_PATH" >> properties.txt
echo "LTTNG_CI_REPO=$LTTNG_CI_REPO" >> properties.txt
echo "LTTNG_CI_BRANCH=$LTTNG_CI_BRANCH" >> properties.txt
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
echo "LTTNG_VERSION=$LTTNG_VERSION" >> properties.txt
echo "KGITREPO=$KERNEL_REPO" >> properties.txt
echo "LTTNG_MODULES_REPO=$LTTNG_MODULES_REPO" >> properties.txt
echo "ROOTFS_URL=$ROOTFS_URL" >> properties.txt
echo "STORAGE_KERNEL_FOLDER=$BASE_STORAGE_FOLDER/kernel" >> properties.txt
echo "STORAGE_KERNEL_IMAGE=$BASE_STORAGE_FOLDER/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage" >> properties.txt
echo "STORAGE_LINUX_MODULES=$BASE_STORAGE_FOLDER/modules/linux/$KERNEL_COMMIT_ID.$BUILD_DEVICE.linux.modules.tar.gz" >> properties.txt
echo "STORAGE_LTTNG_MODULES=$BASE_STORAGE_FOLDER/modules/lttng/$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID.$BUILD_DEVICE.lttng.modules.tar.gz" >> properties.txt

BASE_S3_STORAGE="lava"
BASE_S3_URL="https://obj.internal.efficios.com"

S3_STORAGE_KERNEL_IMAGE=$BASE_S3_STORAGE/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage
S3_STORAGE_LINUX_MODULES=$BASE_S3_STORAGE/modules/linux/$KERNEL_COMMIT_ID.$BUILD_DEVICE.linux.modules.tar.gz
S3_STORAGE_LTTNG_MODULES=$BASE_S3_STORAGE/modules/lttng/$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID.$BUILD_DEVICE.lttng.modules.tar.gz

echo "BASE_S3_STORAGE=$BASE_S3_STORAGE" >> properties.txt
echo "S3_STORAGE_KERNEL_FOLDER=$BASE_S3_STORAGE/kernel" >> properties.txt
echo "S3_STORAGE_KERNEL_IMAGE=$S3_STORAGE_KERNEL_IMAGE" >> properties.txt
echo "S3_STORAGE_LINUX_MODULES=$S3_STORAGE_LINUX_MODULES" >> properties.txt
echo "S3_STORAGE_LTTNG_MODULES=$S3_STORAGE_LTTNG_MODULES" >> properties.txt

# Generate S3 https url directly
echo "S3_URL_KERNEL_IMAGE=${BASE_S3_URL}/$S3_STORAGE_KERNEL_IMAGE" >> properties.txt
echo "S3_URL_LINUX_MODULES=${BASE_S3_URL}/$S3_STORAGE_LINUX_MODULES" >> properties.txt
echo "S3_URL_LTTNG_MODULES=${BASE_S3_URL}/$S3_STORAGE_LTTNG_MODULES" >> properties.txt
