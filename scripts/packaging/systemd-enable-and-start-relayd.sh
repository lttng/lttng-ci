#!/bin/sh -exu

systemctl enable lttng-relayd

systemctl start lttng-relayd
