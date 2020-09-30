#!/bin/bash

set -exu

# Start the lttng-sessiond
lttng-sessiond -b -vvv 1>lttng-sessiond.log 2>&1
