#!/bin/bash

WORK_DIR="$(dirname "$(readlink -f "$0")")"
VENV="${WORK_DIR}/venv/bin/activate"

source "${VENV}"

pdudaemon --journal --dbfile="${WORK_DIR}/pdudaemon.db" --conf="${WORK_DIR}/pdudaemon.conf"
