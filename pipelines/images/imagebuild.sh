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
apt-get -y install incus-client ansible jq python3-pip

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

INCUS_ARGS=(incus -q launch "${VM_ARG[@]}" -p default -p "${INCUS_INSTANCE_PROFILE}")
if [[ "${OS}" == "rockylinux" ]] && [[ "${IMAGE_TYPE}" == "vm" ]]; then
    INCUS_ARGS+=(-p vm-agent)
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
    if ! INSTANCE_NAME=$(${INCUS_ARGS[@]} "${SOURCE_IMAGE_NAME}/${IMAGE_TYPE}") ; then
        # Try from images
        if ! INSTANCE_NAME=$(${INCUS_ARGS[@]} images:"${SOURCE_IMAGE_NAME}") ; then
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
sleep "${NETWORK_SLEEP}"

if [[ "${OS}" == "rockylinux" ]] && [ "${RELEASE}" -le "8" ]; then
    incus exec "${INSTANCE_NAME}" -- ip a
    incus exec "${INSTANCE_NAME}" -- dnf install -y python3.12 python3.12-pip python3.12-setuptools python3-virtualenv
    ANSIBLE_PYTHON_INTERPRETER=python3.12
fi

# There's a wide-array of potential targets and hosts, so try to find a version
# of ansible that can be used. E.g., ansible as shipped with Debian bookworm won't
# work when the target is Debian trixie.
#
# Ref: https://docs.ansible.com/ansible/latest/reference_appendices/release_and_maintenance.html#ansible-core-support-matrix
#
ANSIBLE_PYTHON_INTERPRETER="${ANSIBLE_PYTHON_INTERPRETER:-python3}"
TARGET_PYTHON_VERSION="$(incus exec "${INSTANCE_NAME}" -- ${ANSIBLE_PYTHON_INTERPRETER} --version | cut -d' ' -f2 | cut -d'.' -f1,2)"
ANSIBLE_VERSION="$(ansible --version | head -n1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | cut -d'.' -f1,2)"
case "${TARGET_PYTHON_VERSION}" in
    "3.13")
        if [[ "${ANSIBLE_VERSION}" != "2.18" ]]; then
            pip3 install --user --break-system-packages ansible-core==2.18
            export PATH=$PATH:~/.local/bin
        fi
        ;;
    "3.12")
        if [[ "$(echo "${ANSIBLE_VERSION} >= 2.16" | bc)" != "1" ]]; then
            pip3 install --user --break-system-packages ansible-core==2.16
            export PATH=$PATH:~/.local/bin
        fi
        ;;
esac
LANG=C.UTF-8 ansible-playbook --version
LANG=C.UTF-8 ansible-galaxy install -r roles/requirements.yml

# Run playbook
cat > fake-inventory <<EOF
[${PROFILE/-/_}]
${INSTANCE_NAME} ansible_connection=community.general.incus ansible_incus_remote=ci ansible_python_interpreter=${ANSIBLE_PYTHON_INTERPRETER}
EOF
cat fake-inventory
CLEANUP+=(
    "rm -f $(pwd)/fake-inventory"
)

LANG=C.UTF-8 ANSIBLE_STRATEGY=linear ansible-playbook site.yml \
    -e '{"lttng_modules_checkout_repo": false}' \
    -l "${INSTANCE_NAME}" -i fake-inventory

# Cleanup instance side
LANG=C.UTF-8 ANSIBLE_STRATEGY=linear ansible-playbook \
       playbooks/post-imagebuild-clean.yml \
       -l "${INSTANCE_NAME}" -i fake-inventory

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
