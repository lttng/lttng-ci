#!/bin/bash
#
# Copyright (C) 2020 Michael Jeanson <mjeanson@efficios.com>
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

SRCDIR="src/lttng-analyses"

PYTHON3="python3"
P3_VERSION=$($PYTHON3 -c 'import sys;v = sys.version.split()[0].split("."); print("{}.{}".format(v[0], v[1]))')

BABELTRACE_DIR=$WORKSPACE/deps/babeltrace/build

export LD_LIBRARY_PATH="$BABELTRACE_DIR/lib"
export PYTHONPATH="$BABELTRACE_DIR/lib/python${P3_VERSION}/site-packages/"

PYENV_HOME=$WORKSPACE/.pyenv/

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv --system-site-packages -p $PYTHON3 "$PYENV_HOME"

set +ux
# shellcheck disable=SC1090
. "$PYENV_HOME/bin/activate"
set -ux

pip install --quiet pylint


cd "$SRCDIR"

pylint -f parseable --ignore="_version.py" --disable=C0111 lttnganalyses | tee "$WORKSPACE/pylint.out"
