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

echo 'At this point, we built the modules and kernel if we needed to.'
echo 'We can now launch the lava job using those artefacts'

venv=$(mktemp -d)
virtualenv -p python3 "$venv"
set +eu
source "${venv}/bin/activate"
set -eu
pip install pyyaml Jinja2

python -u "$LTTNG_CI_PATH"/scripts/system-tests/lava2-submit.py \
                          -t kvm-fuzzing-tests \
                          -j "$JOB_NAME" \
                          -k "$S3_URL_KERNEL_IMAGE" \
                          -lm "$S3_URL_LTTNG_MODULES" \
                          -tc "$LTTNG_TOOLS_COMMIT_ID" \
                          -uc "$LTTNG_UST_COMMIT_ID" \
                          --debug

python -u "$LTTNG_CI_PATH"/scripts/system-tests/lava-submit.py \
                          -t kvm-fuzzing-tests \
                          -j "$JOB_NAME" \
                          -k "$STORAGE_KERNEL_IMAGE" \
                          -lm "$STORAGE_LTTNG_MODULES" \
                          -tc "$LTTNG_TOOLS_COMMIT_ID" \
                          -uc "$LTTNG_UST_COMMIT_ID"

set +eu
deactivate
set -eu
rm -rf "$venv"
