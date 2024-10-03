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
    git clone https://github.com/lttng/lttng-ci.git "$SCRIPT_DIR"
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
    python "$SCRIPT_PATH" --generate-jobs --repo-path "$SRC_DIR"
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
