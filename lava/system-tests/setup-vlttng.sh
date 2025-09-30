#!/bin/bash
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

export TMPDIR=/tmp

# shellcheck disable=SC1091
. "$TMPDIR/python-venv/bin/activate"

# shellcheck disable=SC2086
vlttng --jobs="$(nproc)" $VLTTNG_OPTS "$TMPDIR/vlttng-venv"

sync
