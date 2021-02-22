#!/bin/bash
# Copyright (C) 2021 Jonathan Rajotte-Julien <jonathan.rajotte-julien@efficios.com>
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

# Required variables
WORKSPACE=${WORKSPACE:-}

SRCDIR="$WORKSPACE/src/lttng-tools"
TAPDIR="$WORKSPACE/tap"

cd "$SRCDIR"

# Try to fetch all tap logs.
rsync -a --exclude 'test-suite.log' --include '*/' --include '*.log' --exclude='*' tests/ "$TAPDIR"

# TAP plugin is having a hard time with .yml files.
find "$TAPDIR" -name "meta.yml" -exec rm -f {} \;

# EOF
