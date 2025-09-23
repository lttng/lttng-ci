#!/bin/bash
# SPDX-FileCopyrightText: 2019 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

SRC_DIR="$WORKSPACE/src/babeltrace"
SCRIPT_DIR="$WORKSPACE/src/lttng-ci"
RESULTS_DIR="$WORKSPACE/results"

REQUIREMENT_PATH="${SCRIPT_DIR}/scripts/babeltrace-benchmark/requirement.txt"
SCRIPT_PATH="${SCRIPT_DIR}/scripts/babeltrace-benchmark/benchmark.py"

VENV="$WORKSPACE/venv"
export TMPDIR="$WORKSPACE/tmp"

mkdir -p "$TMPDIR"
mkdir -p "$RESULTS_DIR"

git clone -q -b "${LTTNG_CI_BRANCH}" "${LTTNG_CI_REPO}" "$SCRIPT_DIR"

virtualenv --python python3 "$VENV"
set +u
# shellcheck disable=SC1091
. "${VENV}/bin/activate"
set -u

pip install -r "$REQUIREMENT_PATH"


FORCE_ARG=''
if [[ "${BENCHMARK_FORCE}" == "true" ]]; then
    FORCE_ARG="--force-jobs"
fi

# Run the lava jobs
python "$SCRIPT_PATH" \
    --generate-jobs \
    --bt-repo-path "$SRC_DIR" \
    --batch-size "${BENCHMARK_BATCH_SIZE}" \
    $FORCE_ARG \
    --max-batches "${BENCHMARK_MAX_BATCHES}" \
    --ci-repo "${LTTNG_CI_REPO}" \
    --ci-branch "${LTTNG_CI_BRANCH}" \
    --nfs-root-url "${NFS_ROOT_URL}"

# Generate the report pdf
python "$SCRIPT_PATH" \
    --generate-report \
    --bt-repo-path "$SRC_DIR" \
    --report-name "${RESULTS_DIR}/babeltrace-benchmark.pdf"

rm -rf "$VENV"
