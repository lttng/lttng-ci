#!/bin/bash
#
# Copyright (C) 2019 Michael Jeanson <mjeanson@efficios.com>
# Copyright (C) 2019 Francis Deslauriers <francis.deslauriers@efficios.com>
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

set -o pipefail

PYTHON3=python3

SRCDIR="$WORKSPACE/src/babeltrace"
PYENV_HOME="$WORKSPACE/.pyenv/"

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv --system-site-packages -p ${PYTHON3} "$PYENV_HOME"

set +ux
# shellcheck disable=SC1090,SC1091
. "$PYENV_HOME/bin/activate"
set -ux

if [ -f "$SRCDIR/dev-requirements.txt" ]; then
    pip install -r "$SRCDIR/dev-requirements.txt"
else
    pip install black flake8 isort
fi

exit_code=0

cd "$SRCDIR"

black --diff --check . | tee ../../black.out || exit_code=1
flake8 --output-file=../../flake8.out --tee || exit_code=1

ISORT_UNSUPPORTED_BRANCH_REGEX='.*(stable-1\.5|stable-2\.0)$'

if [[ ! ${GIT_BRANCH:-} =~ $ISORT_UNSUPPORTED_BRANCH_REGEX ]] && \
    [[ ! ${GERRIT_BRANCH:-} =~ $ISORT_UNSUPPORTED_BRANCH_REGEX ]]; then
    isort . --diff --check | tee ../../isort.out || exit_code=1
else
    echo "isort is not supported on the 'stable-2.0' branch" > ../../isort.out
fi

if [[ -f tools/format-cpp.sh ]]; then
    FORMATTER="clang-format-15 -i" tools/format-cpp.sh
    git diff --exit-code | tee ../../clang-format.out || exit_code=1
fi

if [[ -f tools/shellcheck.sh ]]; then
    tools/shellcheck.sh | tee ../../shellcheck.out || exit_code=1
fi

exit $exit_code
