#!/bin/sh

set -exu

systemctl enable lttng-relayd

systemctl start lttng-relayd
