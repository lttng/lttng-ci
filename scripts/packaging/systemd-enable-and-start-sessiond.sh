#!/bin/sh

set -exu

systemctl enable lttng-sessiond

systemctl start lttng-sessiond
