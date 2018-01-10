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

# Create a metadata file for this job containing the build_id, timestamp and the commit ids
TIMESTAMP=$(/bin/date --iso-8601=seconds)
LTTNG_CI_COMMIT_ID="$(git --git-dir="$LTTNG_CI_PATH"/.git/ --work-tree="$LTTNG_CI_PATH" rev-parse --short HEAD)"

echo "build_id,timestamp,kernel_commit,modules_commit,tools_commit,ci_commit" > metadata.csv
echo "$BUILD_NUMBER,$TIMESTAMP,$KERNEL_COMMIT_ID,$LTTNG_MODULES_COMMIT_ID,$LTTNG_TOOLS_COMMIT_ID,$LTTNG_CI_COMMIT_ID" >> metadata.csv

# Copy the result files for each benchmark and metadata on storage server
$SCP_COMMAND ./processed_results_close.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/close.csv"
$SCP_COMMAND ./processed_results_ioctl.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/ioctl.csv"
$SCP_COMMAND ./processed_results_open_efault.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/open-efault.csv"
$SCP_COMMAND ./processed_results_open_enoent.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/open-enoent.csv"
$SCP_COMMAND ./processed_results_dup_close.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/dup-close.csv"
$SCP_COMMAND ./processed_results_lttng_test_filter.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/lttng-test-filter.csv"
$SCP_COMMAND ./processed_results_raw_syscall_getpid.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/raw_syscall_getpid.csv"
$SCP_COMMAND ./metadata.csv "$STORAGE_USER@$STORAGE_HOST:$RESULT_STORAGE_FOLDER/metadata.csv"
