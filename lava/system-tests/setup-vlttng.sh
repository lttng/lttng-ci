#!/bin/bash
# SPDX-FileCopyrightText: 2025 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -exu

# shellcheck disable=SC1091
. /tmp/python-venv/bin/activate

# shellcheck disable=SC2086
vlttng --jobs="$(nproc)" $VLTTNG_OPTS /tmp/vlttng-venv

sync
