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
    OS
    RELEASE
    ARCH
    IMAGE_TYPE
    VARIANT
    GIT_BRANCH
    GIT_URL
    INCUS_CLIENT_CERT
    INCUS_CLIENT_KEY
    TEST
    DISTROBUILDER_GIT_URL
    DISTROBUILDER_GIT_BRANCH
    INCUS_CI_GIT_URL
    INCUS_CI_GIT_BRANCH
    GO_VERSION
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

# Optional variables
INSTANCE_START_TIMEOUT="${INSTANCE_START_TIMEOUT:-120}"
VM_ARG=()

# Install incus-client
if [[ "$(uname -m)" == "aarch64" ]] && [[ "$(lsb_release -s -r)" == 12 ]]; then
    echo 'deb http://deb.debian.org/debian/ bookworm-backports main' > /etc/apt/sources.list.d/bookwork-backports.list
fi

apt-get update
apt-get install -y incus-client
mkdir -p ~/.config/incus
cp "${INCUS_CLIENT_CERT}" ~/.config/incus/client.crt
cp "${INCUS_CLIENT_KEY}" ~/.config/incus/client.key
CLEANUP+=(
    "rm -f ${HOME}/.config/incus/client.crt"
    "rm -f ${HOME}/.config/incus/client.key"
)
incus remote add ci --accept-certificate --auth-type tls "${INCUS_HOST}"
incus remote switch ci

# Exit gracefully if the incus images: provides the base image
IMAGE_NAME="${OS}/${RELEASE}/${VARIANT}/${ARCH}"
TYPE_FILTER='type=container'
if [[ "${IMAGE_TYPE}" == "vm" ]] ; then
    TYPE_FILTER='type=virtual-machine'
fi
if [[ "$(incus image list -f csv images:"${IMAGE_NAME}" -- "${TYPE_FILTER}" | wc -l)" != "0" ]] ; then
    echo "Image '${IMAGE_NAME}' provided by 'images:' remote"
    exit 0
fi

# Get go
apt-get install -y wget
GO_ARCH='amd64'
case "$(uname -m)" in
    x86_64)
        GO_ARCH='amd64'
        ;;
    aarch64)
        GO_ARCH='arm64'
        ;;
esac

wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -O - | tar -C /usr/local -xzf -
export PATH="${PATH}:/usr/local/go/bin"

# Install distrobuilder
apt-get install -y debootstrap rsync gpg squashfs-tools git \
        btrfs-progs dosfstools qemu-utils gdisk
cd "${WORKSPACE}"
git clone --branch="${DISTROBUILDER_GIT_BRANCH}" "${DISTROBUILDER_GIT_URL}" distrobuilder
cd distrobuilder
make
PATH="${PATH}:${HOME}/go/bin"

# Get CI repo
cd "${WORKSPACE}"
git clone --branch="${GIT_BRANCH}" "${GIT_URL}" ci

# Get the INCUS CI repo
cd "${WORKSPACE}"
git clone --branch="${INCUS_CI_GIT_BRANCH}" "${INCUS_CI_GIT_URL}" incus-ci

IMAGE_DIRS=(
    "${WORKSPACE}/ci/automation/images"
    "${WORKSPACE}/incus-ci/images"
)
EXTENSIONS=(
    'yml'
    'yaml'
)
IMAGE_FILE=''
for IMAGE_DIR in "${IMAGE_DIRS[@]}" ; do
    for EXTENSION in "${EXTENSIONS[@]}" ; do
        if [ -f "${IMAGE_DIR}/${OS}-${RELEASE}.${EXTENSION}" ] ; then
            IMAGE_FILE="${IMAGE_DIR}/${OS}-${RELEASE}.${EXTENSION}"
            break 2;
        fi
    done
    for EXTENSION in "${EXTENSIONS[@]}" ; do
        if [ -f "${IMAGE_DIR}/${OS}.${EXTENSION}" ] ; then
            IMAGE_FILE="${IMAGE_DIR}/${OS}.${EXTENSION}"
            break 2;
        fi
    done
done

if [[ "${IMAGE_FILE}" == "" ]] ; then
    fail 1 "Unable to find image file for '${OS}' in ${IMAGE_DIRS[@]}"
fi

if grep -q -E 'XX[A-Za-z0-9_]+XX' "${IMAGE_FILE}" ; then
    while read -r VAR ; do
        echo "${VAR}"
        SHELLVAR=$(echo "${VAR}" | sed 's/^XX//g' | sed 's/XX$//g')
        set +x
        sed -i "s/${VAR}/${!SHELLVAR:-VARIABLENOTFOUND}/g" "${IMAGE_FILE}"
        set -x
    done < <(grep -E -o 'XX[A-Za-z0-9_]+XX' "${IMAGE_FILE}")
fi

DISTROBUILDER_ARGS=(
    distrobuilder
    build-incus
)
if [[ "${IMAGE_TYPE}" == "vm" ]] ; then
    DISTROBUILDER_ARGS+=('--vm')
    VM_ARG=('--vm')
fi

# This could be quite large, and /tmp may be a tmpfs backed
# by memory, so instead make it relative to the workspace directory
BUILD_DIR=$(mktemp -d -p "${WORKSPACE}")
CLEANUP+=(
    "rm -rf ${BUILD_DIR}"
)
DISTROBUILDER_ARGS+=(
    "${IMAGE_FILE}"
    "${BUILD_DIR}"
    '-o'
    "image.architecture=${ARCH}"
    '-o'
    "image.variant=${VARIANT}"
    '-o'
    "image.release=${RELEASE}"
    '-o'
    "image.serial=$(date -u +%Y%m%dT%H:%M:%S%z)"
)

# Run the build
${DISTROBUILDER_ARGS[@]}

# Import
# As 'distrobuilder --import-into-incus=alias' doesn't work since it only
# connects to the local unix socket, and the remote instance cannot be specified
# at this time.
ROOTFS="${BUILD_DIR}/rootfs.squashfs"
if [[ "${IMAGE_TYPE}" == "vm" ]] ; then
    ROOTFS="${BUILD_DIR}/disk.qcow2"
fi

# Work-around for incus not using qemu-system-i386: set the architecture to x86_64
# which will use qemu-system-x86_64 and still run 32bit userspace/kernels fine.
if [[ "${ARCH}" == "i386" ]] ; then
    TMP_DIR=$(mktemp -d)
    pushd "${TMP_DIR}"
    tar -xf "${BUILD_DIR}/incus.tar.xz"
    sed -i 's/architecture: i386/architecture: x86_64/' metadata.yaml
    tar -cf "${BUILD_DIR}/incus.tar.xz" ./*
    popd
    rm -rf "${TMP_DIR}"
fi

# When using `incus image import` two images cannot have the same alias -
# only the last image imported will keep the alias. Therefore, the
# image type is appended as part of the alias.
IMAGE_NAME="${IMAGE_NAME}/${IMAGE_TYPE}"

if FINGERPRINT=$(incus image import "${BUILD_DIR}/incus.tar.xz" "${ROOTFS}" 2>&1 | grep -E -o '[A-Fa-f0-9]{64}') ; then
    echo "Image imported with fingerprint '${FINGERPRINT}'"
else
    fail 1 "No fingerprint for imported image"
fi

if [[ "${TEST}" == "true" ]] ; then
    set +e
    INSTANCE_NAME=''
    if INSTANCE_NAME="$(incus -q launch -e ${VM_ARG[@]} -p default -p "${INCUS_INSTANCE_PROFILE}" "${FINGERPRINT}")" ; then
        INSTANCE_NAME="$(echo "${INSTANCE_NAME}" | cut -d':' -f2 | tr -d ' ')"
        CLEANUP+=(
            "incus stop -f ${INSTANCE_NAME}"
        )
    else
        fail 1 "Failed to launch instance using image '${FINGERPRINT}'"
    fi
    TIME_REMAINING="${INSTANCE_START_TIMEOUT}"
    INSTANCE_STATUS=''
    while true ; do
        INSTANCE_STATUS="$(incus exec "${INSTANCE_NAME}" hostname)"
        if [[ "${INSTANCE_STATUS}" == "${INSTANCE_NAME}" ]] ; then
            break
        fi
        sleep 1
        TIME_REMAINING=$((TIME_REMAINING - 1))
        if [ "${TIME_REMAINING}" -lt "0" ] ; then
            fail 1 "Timed out waiting for instance to become available via 'incus exec'"
        fi
    done
    set -e
fi

incus image alias delete "${IMAGE_NAME}" || true
incus image alias create "${IMAGE_NAME}" "${FINGERPRINT}"
