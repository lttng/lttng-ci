#!/bin/sh -exu
#
# Copyright (C) 2015 Michael Jeanson <mjeanson@efficios.com>
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

PYTHON3=python3

PYENV_HOME="$WORKSPACE/.pyenv/"

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv --system-site-packages -p ${PYTHON3} "$PYENV_HOME"

set +ux
. "$PYENV_HOME/bin/activate"
set -ux

pip install --quiet black

black --diff --check src/babeltrace
