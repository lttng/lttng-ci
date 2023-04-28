#!/bin/sh
#
# SPDX-FileCopyrightText: 2015-2023 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

SRCDIR="src/barectf"

PYTHON3="python3"
PYENV_HOME=$WORKSPACE/.pyenv/

# Delete previously built virtualenv
if [ -d "$PYENV_HOME" ]; then
    rm -rf "$PYENV_HOME"
fi

# Create virtualenv and install necessary packages
virtualenv -p $PYTHON3 "$PYENV_HOME"

set +u
# shellcheck disable=SC1090,SC1091
. "$PYENV_HOME/bin/activate"
set -u

pip install --quiet tox poetry

cd "$SRCDIR"

# test
tox -v

# EOF
