#!/bin/bash -exu
#
# Copyright (C) 2015 - Michael Jeanson <mjeanson@efficios.com>
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

# Has to be set in the environment
#CODECOV_TOKEN=""

SRCDIR="src/lttng-analyses"

PYTHON3="python3"
P3_VERSION=$($PYTHON3 -c "import sys;print(sys.version[:3])")

BABELTRACE_DIR=$WORKSPACE/deps/babeltrace/build

export LD_LIBRARY_PATH="$BABELTRACE_DIR/lib"
export PYTHONPATH="$BABELTRACE_DIR/lib/python${P3_VERSION}/site-packages/"
export PATH="$PATH:$BABELTRACE_DIR/bin"

PYENV_HOME=$WORKSPACE/.pyenv/

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv --system-site-packages -p $PYTHON3 "$PYENV_HOME"

set +ux
. "$PYENV_HOME/bin/activate"
set -ux

pip install --quiet codecov
pip install --quiet tox

cd "$SRCDIR"

# Hack for path too long in venv wrapper shebang
TOXWORKDIR=$(mktemp -d)
export TOXWORKDIR

# Run base test suites and long regression test suite
for suite in py3 noutf8 pep8 longregression; do
	export TOXENV="$suite"
	tox
	codecov -e TOXENV
done

unset TOXENV
rm -rf "$TOXWORKDIR"

# EOF
