#!/bin/bash
# SPDX-FileCopyrightText: 2016 Francis Deslauriers <francis.deslauriers@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

# Variables from the job parameters.
#
# 'LTTNG_TOOLS_COMMIT_ID': 'The lttng-tools commit id to build.'
# 'LTTNG_MODULES_COMMIT_ID': 'The lttng-modules commit id to build.'
# 'LTTNG_UST_COMMIT_ID': 'The lttng-ust commit id to build.'
# 'KERNEL_COMMIT_ID': 'The linux kernel commit id to build against.'
# 'KERNEL_REPO': 'Linux kernel git repo to checkout the kernel id'
# 'LTTNG_TOOLS_REPO': 'LTTng-Tools git repo to checkout the tools id'
# 'LTTNG_MODULES_REPO': 'LTTng-Modules git repo to checkout the Modules id'
# 'LTTNG_UST_REPO': 'LTTng-UST git repo to checkout the UST id'
# 'ROOTFS_URL': 'The URL at which the system root FS can be downloaded'
# 'LTTNG_CI_REPO': 'LTTng-ci git repo to checkout the CI scripts'
# 'LTTNG_CI_BRANCH': 'The branch of the CI repository to clone for job scripts'
# 'LAVA_HOST': 'The hostname of the LAVA instance'
# 'LAVA_PROTO': 'The protocol to use with the LAVA host'
# 'S3_HOST': 'Host for the s3 object storage'
# 'S3_BUCKET': 'Bucket for the s3 object storage'
# 'S3_BASE_DIR': 'Base directory for the s3 object storage'
# 'S3_HTTP_BUCKET_URL': 'Base url to access the s3 bucket over unauthenticated HTTP'

S3_HTTP_URL_KERNEL_IMAGE="$S3_HTTP_BUCKET_URL/$S3_BASE_DIR/kernel/$KERNEL_COMMIT_ID.$BUILD_DEVICE.bzImage"
S3_HTTP_URL_LTTNG_MODULES="$S3_HTTP_BUCKET_URL/$S3_BASE_DIR/modules/$KERNEL_COMMIT_ID-$LTTNG_MODULES_COMMIT_ID.$BUILD_DEVICE.lttng.modules.tar.xz"

S3CMD_CONFIG="${WORKSPACE}/s3cfg"

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

# Trigger the lava job and wait for completion
python3 -u "$WORKSPACE/src/lttng-ci/scripts/system-tests/lava2-submit.py" \
                          --type "$BUILD_DEVICE-tests" \
                          --lttng-version "$LTTNG_VERSION" \
                          --job "$JOB_NAME" \
                          --jenkins-build-id "$BUILD_TAG" \
                          --kernel-url "$S3_HTTP_URL_KERNEL_IMAGE" \
                          --modules-url "$S3_HTTP_URL_LTTNG_MODULES" \
                          --rootfs-url "$ROOTFS_URL" \
                          --tools-repo "$LTTNG_TOOLS_REPO" \
                          --tools-commit "$LTTNG_TOOLS_COMMIT_ID" \
                          --ust-repo "$LTTNG_UST_REPO" \
                          --ust-commit "$LTTNG_UST_COMMIT_ID" \
                          --urcu-repo "$URCU_REPO" \
                          --urcu-branch "$URCU_BRANCH" \
                          --bt-repo "$BT_REPO" \
                          --bt-branch "$BT_BRANCH" \
                          --ci-repo "$LTTNG_CI_REPO" \
                          --ci-branch "$LTTNG_CI_BRANCH"

mkdir results

# Attempt to get the job result artifacts if they exist so they can be archived by jenkins for convenience
s3cmd -c "$S3CMD_CONFIG" get "s3://$S3_BUCKET/$S3_BASE_DIR/results/${BUILD_TAG}/logs.tar.xz" results/ || true
s3cmd -c "$S3CMD_CONFIG" get "s3://$S3_BUCKET/$S3_BASE_DIR/results/${BUILD_TAG}/coredump.tar.xz" results/ || true
