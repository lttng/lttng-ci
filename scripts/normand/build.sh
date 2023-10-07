#!/bin/bash -xeu
#
# SPDX-FileCopyrightText: 2023 Philippe Proulx <pproulx@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

SRCDIR="src/normand"
VENV="$WORKSPACE/.pyenv/"

# Delete previously built virtual environment just in case
if [[ -d "$VENV" ]]; then
    rm -rf "$VENV"
fi

# Create virtual environment and enter it
python3 -m venv "$VENV"
set +u
# shellcheck disable=SC1090,SC1091
. "$VENV/bin/activate"
set -u

# Install Poetry and pytest
pip install --quiet poetry pytest

# Install the cloned version of Normand.
#
# Poetry doesn't create another virtual environment because it reuses
# the current one.
cd "$SRCDIR"
poetry install

# Test
pytest -v

# EOF
