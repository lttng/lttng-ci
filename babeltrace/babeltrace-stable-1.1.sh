# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

PREFIX="$WORKSPACE/build"

./bootstrap

CONF_OPTS=""

case "$conf" in
static)
    echo "Static build"
    CONF_OPTS="--enable-static --disable-shared"
    ;;
python_bindings)  
    echo "Build with python bindings"
    # We only support bindings built with Python 3
    export PYTHON="python3"
    export PYTHON_CONFIG="/usr/bin/python3-config"
    CONF_OPTS="--enable-python-bindings"
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

./configure --prefix=$PREFIX $CONF_OPTS

make
make install

rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap

cd $WORKSPACE/tests

# Run make check tests
prove --merge --exec '' - < $WORKSPACE/tests/tests --archive $WORKSPACE/tap/ || true

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/ -type f -exec mv {} {}.tap \;

make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/bin -executable -type f -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;
