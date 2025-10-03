#!/bin/bash
# SPDX-FileCopyrightText: 2021 Jonathan Rajotte <jonathan.rajotte-julien@efficios.com>
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu
set -o pipefail

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

function upload_artifact()
{
    local filepath=$1
    local filename

    filename=$(basename "$filepath")

    md5="$(openssl md5 -binary "$filepath" | openssl base64)"

    curl -s -f -T "$filepath" \
        --config s3curlrc \
        --aws-sigv4 "aws:amz:us-east-1:s3" \
        -H "Content-MD5: $md5" \
        "https://${S3_HOST}/${S3_BUCKET}/${S3_BASE_DIR}/results/${JENKINS_BUILD_ID}/$filename"
}

# Fetch the S3 keys stored in secrets
set +x
# shellcheck disable=SC1091
. ../../../secrets
echo "user = \"$S3_ACCESS_KEY:$S3_SECRET_KEY\"" > s3curlrc
set -x

# Upload the log files
if [ -f "$SCRATCH_DIR/log/logs.tar.xz" ]; then
    print_header "Upload tests logs to object storage"
    upload_artifact "$SCRATCH_DIR/log/logs.tar.xz"
fi

# Upload the coredumps
if [ -z "$(find "$SCRATCH_DIR/coredump" -maxdepth 0 -type d -empty)" ]; then
    print_header "Upload coredumps to object storage"
    tar cJf "$SCRATCH_DIR/coredump.tar.xz" "$SCRATCH_DIR/coredump"
    upload_artifact "$SCRATCH_DIR/coredump.tar.xz"
fi
