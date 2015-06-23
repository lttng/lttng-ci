#!/bin/sh

lttng create
lttng enable-event -a -k
lttng start
wait 1
lttng stop

count=$(lttng view | wc -l)
if [ $count -lt "100" ]; then
	false
fi


