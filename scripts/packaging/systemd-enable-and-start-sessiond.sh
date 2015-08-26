#!/bin/sh -exu

systemctl enable lttng-sessiond

systemctl start lttng-sessiond
