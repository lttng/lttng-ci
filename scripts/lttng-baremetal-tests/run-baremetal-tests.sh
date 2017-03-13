#!/bin/bash -xeu
# Copyright (C) 2016 - Francis Deslauriers <francis.deslauriers@efficios.com>
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

echo 'At this point, we built the modules and kernel if we needed to.'
echo 'We can now launch the lava job using those artefacts'
git clone https://github.com/lttng/lttng-ci "$LTTNG_CI_PATH"

python3 -u "$LTTNG_CI_PATH"/scripts/lttng-baremetal-tests/lava-submit.py \
                          -t baremetal-tests \
                          -j "$JOB_NAME" \
                          -k "$STORAGE_KERNEL_IMAGE" \
                          -km "$STORAGE_LINUX_MODULES" \
                          -lm "$STORAGE_LTTNG_MODULES" \
                          -tc "$LTTNG_TOOLS_COMMIT_ID" \
                          -uc "$LTTNG_UST_COMMIT_ID"
