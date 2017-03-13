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
                          -t baremetal-benchmarks \
                          -j "$JOB_NAME" \
                          -k "$STORAGE_KERNEL_IMAGE" \
                          -km "$STORAGE_LINUX_MODULES" \
                          -lm "$STORAGE_LTTNG_MODULES" \
                          -tc "$LTTNG_TOOLS_COMMIT_ID"

# Create a results folder for this job
RESULT_STORAGE_FOLDER="$BASE_STORAGE_FOLDER/benchmark-results/$JOB_NAME/$BUILD_NUMBER"
$SSH_COMMAND "$STORAGE_USER@$STORAGE_HOST" mkdir -p "$RESULT_STORAGE_FOLDER"

# Create a metadata file for this job containing the build_id and the commit ids
echo "build_id,kernel_commit,modules_commit,tools_commit" > metadata.csv
echo "$BUILD_NUMBER,$KERNEL_COMMIT_ID,$LTTNG_MODULES_COMMIT_ID,$LTTNG_TOOLS_COMMIT_ID" >> metadata.csv

# Copy the result files for each benchmark and metadata on storage server
$SCP_COMMAND ./processed_results_close.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/close.csv"
$SCP_COMMAND ./processed_results_open_efault.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/open-efault.csv"
$SCP_COMMAND ./processed_results_dup_close.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/dup-close.csv"
$SCP_COMMAND ./metadata.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/metadata.csv"
