#!/bin/sh

set -exu

lttng create
lttng enable-event -a -k
lttng start
sleep 1
lttng stop

count=$(lttng view | wc -l)
if [ $count -lt "100" ]; then
    false
fi


