#!/usr/bin/bash -eux

CLEANUP=()

function cleanup {
    set +e
    for (( index=${#CLEANUP[@]}-1 ; index >= 0 ; index-- )) ;do
        ${CLEANUP[$index]}
    done
    CLEANUP=()
    set -e
}

function fail {
    CODE="${1:-1}"
    REASON="${2:-Unknown reason}"
    cleanup
    echo "${REASON}" >&2
    exit "${CODE}"
}

trap cleanup EXIT TERM INT

env

REQUIRED_VARIABLES=(
    OS              # OS name
    RELEASE         # OS release
    ARCH            # The image architecture
    IMAGE_TYPE      # The image type to create
    VARIANT         # The variant of the base image to use
    PROFILE         # The ansible group to apply to the new image
    GIT_BRANCH      # The git branch of the automation repo to checkout
    GIT_URL         # The git URL of the automation repo to checkout
    INCUS_CLIENT_CERT # Path to INCUS client certificate
    INCUS_CLIENT_KEY  # Path to INCUS client certificate key
    SSH_PRIVATE_KEY # Path to SSH private key
    TEST            # 'true' to test launching published image
)
MISSING_VARS=0
for var in "${REQUIRED_VARIABLES[@]}" ; do
    if [ ! -v "$var" ] ; then
        MISSING_VARS=1
        echo "Missing required variable: '${var}'" >&2
    fi
done
if [[ ! "${MISSING_VARS}" == "0" ]] ; then
    fail 1 "Missing required variables"
fi

# Default optional variables
INSTANCE_START_TIMEOUT="${INSTANCE_START_TIMEOUT:-120}"
NETWORK_SLEEP="${NETWORK_SLEEP:-15}"

# Dependencies
apt-get update -y
apt-get -y install incus-client ansible jq

# Configuration
mkdir -p ~/.config/incus
cp "${INCUS_CLIENT_CERT}" ~/.config/incus/client.crt
cp "${INCUS_CLIENT_KEY}" ~/.config/incus/client.key
CLEANUP+=(
    "rm -f ${HOME}/.config/incus/client.crt"
    "rm -f ${HOME}/.config/incus/client.key"
)
incus remote add ci --accept-certificate --auth-type tls "${INCUS_HOST}"
incus remote switch ci

# Clone lttng-ci
git clone -b "${GIT_BRANCH}" "${GIT_URL}" ci
cd ci/automation/ansible || exit 1

SOURCE_IMAGE_NAME="${OS}/${RELEASE}/${VARIANT}/${ARCH}"
# Include IMAGE_TYPE since an alias may only be defined once even if the
# type of the image differs
TARGET_IMAGE_NAME="${OS}/${RELEASE}/${VARIANT}/${ARCH}/${PROFILE}/${IMAGE_TYPE}"
INSTANCE_NAME=''
# Try from local cache
VM_ARG=()
if [ "${IMAGE_TYPE}" == "vm" ] ; then
    VM_ARG=("--vm")
fi

set +e
# Test
# It's possible that concurrent image creation when running parallel jobs causes
# an error during the launch:
#   Error: Failed instance creation: UNIQUE constraint failed: images.project_id, images.fingerprint
# C.f. https://github.com/canonical/lxd/issues/11636
#
TRIES_MAX=3
TRIES=0
while [[ "${TRIES}" -lt "${TRIES_MAX}" ]] ; do
    if ! INSTANCE_NAME=$(incus -q launch "${VM_ARG[@]}" -p default -p "${INCUS_INSTANCE_PROFILE}" "${SOURCE_IMAGE_NAME}/${IMAGE_TYPE}") ; then
        # Try from images
        if ! INSTANCE_NAME=$(incus -q launch "${VM_ARG[@]}" -p default -p "${INCUS_INSTANCE_PROFILE}" images:"${SOURCE_IMAGE_NAME}") ; then
            TRIES=$((TRIES + 1))
            echo "Failed to deployed ephemereal instance attempt ${TRIES}/${TRIES_MAX}"
            if [[ "${TRIES}" -lt  "${TRIES_MAX}" ]] ; then
                continue
            fi
            fail 1 "Failed to deploy ephemereal instance"
        else
            break
        fi
    else
        break
    fi
done
INSTANCE_NAME="$(echo "${INSTANCE_NAME}" | cut -d ':' -f 2 | tr -d ' ')"
set -e

CLEANUP+=(
    "incus delete -f ${INSTANCE_NAME}"
    "incus stop ${INSTANCE_NAME}"
)

# VMs may take more time to start, wait until instance is running
TIME_REMAINING="${INSTANCE_START_TIMEOUT}"
while true ; do
    set +e
    INSTANCE_STATUS=$(incus exec "${INSTANCE_NAME}" hostname)
    set -e
    if [[ "${INSTANCE_STATUS}" == "${INSTANCE_NAME}" ]] ; then
        break
    fi
    sleep 1
    TIME_REMAINING=$((TIME_REMAINING - 1))
    if [ "${TIME_REMAINING}" -lt "0" ] ; then
        fail 1 "Timed out waiting for instance to become available via 'incus exec'"
    fi
done

# Wait for cloud-init to finish
if [[ "${VARIANT}" == "cloud" ]] ; then
    # It's possible for cloud-init to fail, but to still be able to continue.
    # Eg., a profile asks for netplan.io on a system that doesn't have that
    # package available.
    incus exec "${INSTANCE_NAME}" -- cloud-init status -w || true
fi

# Wait for instance to have an ip address (@TODO: is there a better approach?)
sleep "${NETWORK_SLEEP}"

# @TODO: Handle case when iputils2 is not installed
INSTANCE_IP=''
POTENTIAL_INTERFACES=(eth0 enp5s0)
incus exec "${INSTANCE_NAME}" -- ip a
set +e
for interface in "${POTENTIAL_INTERFACES[@]}" ; do
    if ! DEV_INFO="$(incus exec "${INSTANCE_NAME}" -- ip a show dev "${interface}")" ; then
        continue
    fi
    INSTANCE_IP="$(echo "${DEV_INFO}" | grep -Eo 'inet [^ ]* ' | cut -d' ' -f2 | cut -d'/' -f1)"
    if [[ "${INSTANCE_IP}" != "" ]] ; then
        break
    fi
done
set -e
if [[ "${INSTANCE_IP}" == "" ]] ; then
    fail 1 "Failed to determine instance IP address"
fi

ssh-keyscan "${INSTANCE_IP}" >> ~/.ssh/known_hosts2
#incus exec "${INSTANCE_NAME}" -- bash -c 'for i in /etc/ssh/ssh_host_*_key ; do ssh-keygen -l -f "$i" ; done' >> "${HOME}/.ssh/known_hosts"
CLEANUP+=(
    "rm -f ${HOME}/.ssh/known_hosts2"
)
cp "${SSH_PRIVATE_KEY}" ~/.ssh/id_rsa
ssh-keygen -f ~/.ssh/id_rsa -y > ~/.ssh/id_rsa.pub
CLEANUP+=(
    "rm -f ${HOME}/.ssh/id_rsa.pub"
    "rm -f ${HOME}/.ssh/id_rsa"
)
incus file push ~/.ssh/id_rsa.pub "ci:${INSTANCE_NAME}/root/.ssh/authorized_keys2"
# Some distros, eg. Rocky Linux, don't enable the use of authorized_keys2
# by default
incus exec "ci:${INSTANCE_NAME}" -- bash -c 'if test -f /etc/redhat-release ; then sed -i "s#^AuthorizedKeysFile.*#AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2#" /etc/ssh/sshd_config ; systemctl restart sshd ; fi'


# Confirm working SSH connection
if ! ssh "${INSTANCE_IP}" hostname ; then
    fail 1 "Unable to reach ephemereal instance over SSH"
fi

# Run playbook
cat > fake-inventory <<EOF
[${PROFILE/-/_}]
${INSTANCE_IP}
EOF
cat fake-inventory
CLEANUP+=(
    "rm -f $(pwd)/fake-inventory"
)

LANG=C ANSIBLE_STRATEGY=linear ansible-playbook site.yml \
    -e '{"jenkins_user": false, "lttng_modules_checkout_repo": false}' \
    -l "${INSTANCE_IP}" -i fake-inventory

# Cleanup instance side
LANG=C ANSIBLE_STRATEGY=linear ansible-playbook \
       playbooks/post-imagebuild-clean.yml \
       -l "${INSTANCE_IP}" -i fake-inventory

# Graceful shutdown
incus stop "${INSTANCE_NAME}"

# Publish
PUBLISH_OUTPUT=$(incus publish "${INSTANCE_NAME}" 2>&1)
if FINGERPRINT=$(echo "${PUBLISH_OUTPUT}" | grep -E -o '[A-Fa-f0-9]{64}') ; then
    echo "Published instance with fingerprint '${FINGERPRINT}'"
else
    echo "${PUBLISH_OUTPUT}"
    fail 1 "No fingerprint for published instance"
fi

TRIES=0

if [[ "${TEST}" == "true" ]] ; then
    set +e
    while [[ "${TRIES}" -lt "${TRIES_MAX}" ]] ; do
        if ! INSTANCE_NAME=$(incus -q launch -e "${VM_ARG[@]}" -p default -p "${INCUS_INSTANCE_PROFILE}" "${FINGERPRINT}")  ; then
            TRIES=$((TRIES + 1))
            echo "Failed to launch instance try ${TRIES}/${TRIES_MAX}"
            if [[ "${TRIES}" -lt "${TRIES_MAX}" ]] ; then
                sleep $((1 + RANDOM % 10))
                continue
            fi
            fail 1 "Failed to launch an instance using newly published image '${FINGERPRINT}'"
        else
            INSTANCE_NAME="$(echo "${INSTANCE_NAME}" | cut -d':' -f2 | tr -d ' ')"
            CLEANUP+=(
                "incus stop -f ${INSTANCE_NAME}"
            )
            break
        fi
    done
    set -e
fi

incus image alias delete "${TARGET_IMAGE_NAME}" || true
incus image alias create "${TARGET_IMAGE_NAME}" "${FINGERPRINT}"
