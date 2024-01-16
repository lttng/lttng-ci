#!/bin/bash
#
# SPDX-FileCopyrightText: 2020 Michael Jeanson <mjeanson@efficios.com>
# SPDX-License-Identifier: GPL-2.0-or-later

set -exu

COLOR_BLUE='\033[0;34m'
COLOR_NONE='\033[0m' # No Color

print_blue() {
	echo -e "${COLOR_BLUE}$1${COLOR_NONE}"
}

print_hardware() {
    if command -v lscpu >/dev/null 2>&1; then
        print_blue "CPU Details"
        lscpu
    fi

    if command -v free >/dev/null 2>&1; then
        print_blue "Memory Details"
        free -m
    else
        print_blue "Memory Details"
        vmstat free
    fi

    print_blue "Storage Details"
    df -H -T
}

print_os() {
    set +ex

    print_blue "Operating System Details"

    if [ -f "/etc/os-release" ]; then
        (. "/etc/os-release"; echo "Version: $NAME $VERSION")
    elif [ -f "/etc/release" ]; then
        echo "Version: $(head -n1 /etc/release)"
    elif command -v sw_vers >/dev/null 2>&1; then
        # For MacOS
	echo "Version: $(sw_vers -productName) $(sw_vers -productVersion)"
    fi

    echo -n "Kernel: "
    uname -a

    set -ex
}

print_pkgconfig_mod() {
    local mod=$1
    if pkg-config --exists "${mod}"; then
        print_blue "$mod version"
        pkg-config --modversion "${mod}"
    fi
}

print_tooling() {
    set +ex

    print_blue "Selected CC version"
    ${CC:-cc} --version | head -n1

    print_blue "Selected CXX version"
    ${CXX:-c++} --version | head -n1

    print_blue "Default gcc version"
    gcc --version | head -n1
    gcc -dumpmachine

    print_blue "Default g++ version"
    g++ --version | head -n1
    g++ -dumpmachine

    if command -v clang >/dev/null 2>&1; then
        print_blue "Default clang version"
        clang --version
    fi

    if command -v clang++ >/dev/null 2>&1; then
        print_blue "Default clang++ version"
        clang++ --version
    fi

    print_blue "git version"
    git --version

    print_blue "bash version"
    bash --version | head -n1

    print_blue "make version"
    ${MAKE:-make} --version | head -n1

    if command -v cmake >/dev/null 2>&1; then
        print_blue "cmake version"
	cmake --version
    fi

    print_blue "automake version"
    automake --version | head -n1

    print_blue "autoconf version"
    autoconf --version | head -n1

    print_blue "libtool version"
    if libtool --version >/dev/null 2>&1; then
        libtool --version | head -n1
    else
        # Thanks Apple!
        libtool -V
    fi

    print_blue "bison version"
    ${BISON:-bison} --version | head -n1

    print_blue "flex version"
    ${FLEX:-flex} --version

    print_blue "swig version"
    swig -version | ${GREP:-grep} SWIG

    print_blue "tar version"
    ${TAR:-tar} --version | head -n1

    print_blue "Selected python version"
    ${PYTHON:-python} --version

    if command -v "${PYTHON2:-python2}" >/dev/null 2>&1; then
        print_blue "python2 version"
        ${PYTHON2:-python2} --version
    fi

    if command -v "${PYTHON3:-python3}" >/dev/null 2>&1; then
        print_blue "python3 version"
        ${PYTHON3:-python3} --version
    fi

    print_blue "java version"
    java -version

    print_blue "javac version"
    javac -version

    if command -v asciidoc >/dev/null 2>&1; then
        print_blue "asciidoc version"
	asciidoc --version
    fi

    if command -v xmlto >/dev/null 2>&1; then
        print_blue "xmlto version"
	xmlto --version
    fi

    if command -v openssl >/dev/null 2>&1; then
        print_blue "openssl version"
	openssl version
    fi

    if command -v pkg-config >/dev/null 2>&1; then
        print_blue "pkg-config version"
        pkg-config --version

        #print_blue "pkg-config modules installed"
        #pkg-config --list-all

        print_pkgconfig_mod glib-2.0
        print_pkgconfig_mod libdw
        print_pkgconfig_mod libelf
        print_pkgconfig_mod libxml-2.0
	print_pkgconfig_mod msgpack
        print_pkgconfig_mod popt
        print_pkgconfig_mod uuid
        print_pkgconfig_mod zlib
    fi

    set -ex
}
