#!/bin/bash
#
# Copyright (C) 2017 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

set -xu
cleanup_commands=()

function cleanup {
    for (( idx="${#cleanup_commands[@]}" - 1; idx >= 0 ; idx-- )); do
        ${cleanup_commands[${idx}]}
    done
}

trap cleanup EXIT
PYTHON3="python3"
PYTEST_FILTER="${pytest_filter:-}"

# Create tmp directory
TMPDIR="$WORKSPACE/tmp"
mkdir -p "$TMPDIR"

# Use a symlink in /tmp to point to the the tmp directory
# inside the workspace, this is to work around the path length
# limit of unix sockets which are created by the test suite.
tmpdir="$(mktemp)"
ln -sf "$TMPDIR" "$tmpdir"
cleanup_commands+=("rm -f '${tmpdir}'")
export TMPDIR="$tmpdir"


# Tox does not support long path venv for whatever reason.
PYENV_HOME=$(mktemp -d)
cleanup_commands+=("deactivate")
cleanup_commands+=("rm -rf '${PYENV_HOME}'")

# Create virtualenv and install necessary packages
virtualenv --system-site-packages -p $PYTHON3 "$PYENV_HOME"

set +ux
# shellcheck disable=SC1091
. "$PYENV_HOME/bin/activate"
set -ux

pip install --quiet tox

# Hack for path too long in venv wrapper shebang
TOXWORKDIR=$(mktemp -d)
export TOXWORKDIR
cleanup_commands+=("rm -rf '${TOXWORKDIR}'")

cd src/ || exit 1

# Required to build tools < 2.11 with GCC >= 10
export CFLAGS="-fcommon"

PYTEST_ARGS=(
    "--junit-xml=${WORKSPACE}/result.xml"
)
if [[ "${PYTEST_FILTER}" != "" ]]; then
    PYTEST_ARGS+=(
        "-k" "${PYTEST_FILTER}"
    )
fi

# Run test suite via tox
tox -v -- "${PYTEST_ARGS[@]}"

# Remove base venv
deactivate
rm -rf "$PYENV_HOME"

# Save
LOG_TMPDIR="$(mktemp -d)"
rsync -r --include="**/log/**" "${TOXWORKDIR}/" "${LOG_TMPDIR}/"
mkdir "${WORKSPACE}/artifacts/"
tar czf "${WORKSPACE}/artifacts/log.tgz" -C "${LOG_TMPDIR}" ./
rm -rf "$TOXWORKDIR"

# EOF
