# How to

For Ubuntu trusty amd64
$ ARCH=amd64 DISTRIBUTION=trusty ./lttng-rootfs.sh

For Ubuntu trusty armhf
$ ARCH=armhf DISTRIBUTION=trusty MIRROR=http://ports.ubuntu.com ./lttng-rootfs.sh --foreign=/usr/bin/qemu-arm-static

Can be used for debian rootfs

# Requirement

* vmdeboostrap v1.3 - git://git.liw.fi/vmdebootstrap
  Looks like v1.4 fail on dhcp configuration.
* cliapp - git://git.liw.fi/cliapp

