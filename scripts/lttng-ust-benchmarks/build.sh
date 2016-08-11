#!/bin/bash -exu
#
# Copyright (C) 2015, Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
#               2016, Michael Jeanson <mjeanson@efficios.com>
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

SRCDIR="$WORKSPACE/src/$PROJECT_NAME"

# Create build directory
rm -rf "$WORKSPACE/build"
mkdir -p "$WORKSPACE/build"

PYTHON3=python3
P3_VERSION=$($PYTHON3 -c "import sys;print(sys.version[:3])")

# liburcu
URCU_INCS="$WORKSPACE/deps/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/deps/liburcu/build/lib/"

# lttng-ust
UST_INCS="$WORKSPACE/deps/lttng-ust/build/include/"
UST_LIBS="$WORKSPACE/deps/lttng-ust/build/lib/"
UST_BINS="$WORKSPACE/deps/lttng-ust/build/bin/"

# babeltrace
BABEL_INCS="$WORKSPACE/deps/babeltrace/build/include/"
BABEL_LIBS="$WORKSPACE/deps/babeltrace/build/lib/"
BABEL_PY="$WORKSPACE/deps/babeltrace/build/lib/python$P3_VERSION/site-packages/"

# lttng-tools
TOOLS_INCS="$WORKSPACE/deps/lttng-tools/build/include/"
TOOLS_LIBS="$WORKSPACE/deps/lttng-tools/build/lib/"
TOOLS_BINS="$WORKSPACE/deps/lttng-tools/build/bin/"
TOOLS_PY="$WORKSPACE/deps/lttng-tools/build/lib/python$P3_VERSION/site-packages/"

rm -rf "$WORKSPACE/deps/lttng-modules"
git clone git://github.com/lttng/lttng-modules.git "$WORKSPACE/deps/lttng-modules"

export CFLAGS="-I$URCU_INCS -I$UST_INCS"
export LDFLAGS="-L$URCU_LIBS -L$UST_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:$UST_LIBS:$BABEL_LIBS:$TOOLS_LIBS:${LD_LIBRARY_PATH:-}"
export PYTHONPATH="$TOOLS_PY:$BABEL_PY:${PYTHONPATH:-}"
export PATH="$TOOLS_BINS:$UST_BINS:$PATH"
export LTTNG_MODULES_DIR="$WORKSPACE/deps/lttng-modules/"

export LTTNG_SESSION_CONFIG_XSD_PATH="$WORKSPACE/deps/lttng-tools/build/share/xml/lttng"
export LTTNG_CONSUMERD64_BIN="$WORKSPACE/deps/lttng-tools/build/lib/lttng/libexec/lttng-consumerd"

cd "$SRCDIR"

make

./benchmarks.py

# EOF
