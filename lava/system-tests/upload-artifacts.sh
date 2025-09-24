#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

tar cJf coredump.tar.xz /tmp/coredump

md5="$(openssl md5 -binary coredump.tar.xz | openssl base64)"

# Fetch the S3 keys stored in secrets
set +x
# shellcheck disable=SC1091
. ../../../secrets
echo "user = \"$S3_ACCESS_KEY:$S3_SECRET_KEY\"" > s3curlrc
set -x

curl -v -s -f -T coredump.tar.xz \
    --config s3curlrc \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    -H "Content-MD5: $md5" \
    "https://${S3_HOST}/${S3_BUCKET}/${S3_BASE_DIR}/results/${JENKINS_BUILD_ID}/coredump.tar.xz"
