#!/bin/bash
#
# Copyright (C) 2019 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

set -exu

SRC_DIR="$WORKSPACE/src/babeltrace"
SCRIPT_DIR="$WORKSPACE/src/lttng-ci"
RESULTS_DIR="$WORKSPACE/results"

REQUIREMENT_PATH="${SCRIPT_DIR}/scripts/babeltrace-benchmark/requirement.txt"
SCRIPT_PATH="${SCRIPT_DIR}/scripts/babeltrace-benchmark/benchmark.py"
VENV="$(mktemp -d)"
TMPDIR="${VENV}/tmp"

mkdir -p "$TMPDIR"
export TMPDIR

function checkout_scripts() {
    git clone -b "${BENCHMARK_REPO_BRANCH}" "${BENCHMARK_REPO_URL}" "$SCRIPT_DIR"
}

function setup_env ()
{
    mkdir -p "$RESULTS_DIR"
    virtualenv --python python3 "$VENV"
    set +u
    # shellcheck disable=SC1090
    . "${VENV}/bin/activate"
    set -u
    pip install -r "$REQUIREMENT_PATH"
}

function run_jobs ()
{
    FORCE_ARG=''
    if [[ "${BENCHMARK_FORCE}" == "true" ]]; then
        FORCE_ARG="--force-jobs"
    fi
    python "$SCRIPT_PATH" --generate-jobs --repo-path "$SRC_DIR" --batch-size "${BENCHMARK_BATCH_SIZE}" $FORCE_ARG --max-batches "${BENCHMARK_MAX_BATCHES}" --script-repo "${BENCHMARK_REPO_URL}" --script-branch "${BENCHMARK_REPO_BRANCH}" --nfs-root-url "${NFS_ROOT_URL}"
}

function generate_report ()
{
    python "$SCRIPT_PATH" --generate-report --repo-path "$SRC_DIR" --report-name "${RESULTS_DIR}/babeltrace-benchmark.pdf"
}

checkout_scripts
setup_env
run_jobs
generate_report

rm -rf "$VENV"
