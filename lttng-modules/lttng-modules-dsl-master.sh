# Recreate link to kernel source

NPROC=`nproc`

rm -rf /tmp/linux-source
rm -rf /tmp/linux-artifact

ln -s $WORKSPACE/linux-source /tmp/linux-source
ln -s $WORKSPACE/linux-artifact /tmp/linux-artifact
ln -s /tmp/linux-source /tmp/linux-artifact/source

cd lttng-modules
make -j $NPROC KERNELDIR=/tmp/linux-artifact
#make INSTALL_MOD_PATH="$PREFIX" modules_install
rm -rf /tmp/linux-source
rm -rf /tmp/linux-artifact

