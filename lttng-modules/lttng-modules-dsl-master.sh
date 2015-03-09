# Recreate link to kernel source
ln -s $WORKSPACE/linux-source /tmp/linux-source
ln -s $WORKSPACE/linux-artifact /tmp/linux-artifact
ln -s /tmp/linux-source /tmp/linux-artifact/source

make KERNELDIR=/tmp/linux-artifact
#make INSTALL_MOD_PATH="$PREFIX" modules_install
rm -rf /tmp/linux-source
rm -rf /tmp/linux-artifact

