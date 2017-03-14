#!/bin/bash -xeu
# Copyright (C) 2017 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

$SCP_COMMAND -r "$STORAGE_USER@$STORAGE_HOST:$BASE_STORAGE_FOLDER/benchmark-results/$JOB_NAME/" ./plot-data/

PYTHON3="python3"

PYENV_HOME=$WORKSPACE/.pyenv/

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv -p $PYTHON3 "$PYENV_HOME"

set +ux
. "$PYENV_HOME/bin/activate"
set -ux

pip install pandas
pip install matplotlib

python3 "$LTTNG_CI_PATH"/scripts/lttng-baremetal-tests/generate-plots.py ./plot-data/
