#!/bin/bash
#
# SPDX-FileCopyrightText: 2020 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

# This file should be used as a jenkins job builder RAW import allowing the
# override of the "build" variable on shell builder execution.

set -exu

# shellcheck disable=SC2034
build=std
