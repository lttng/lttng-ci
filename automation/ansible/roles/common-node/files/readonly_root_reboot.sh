#!/usr/bin/bash

IFS=',' read -r -a OPTIONS < <(findmnt --json / | jq -r '.[][0]["options"]')
RO=
for OPTION in "${OPTIONS[@]}" ; do
    if [[ "${OPTION}" == "ro" ]] ; then
        RO=0
        break
    fi
done

if [[ "${RO}" == "0" ]] ; then
    echo "'/' is mounted read-only, rebooting"
    shutdown -r "+1"
fi
