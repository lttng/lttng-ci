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
tls_fallback)  
    echo  "Using pthread_getspecific() to emulate TLS"
    CONF_OPTS="--disable-compiler-tls"
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

./configure --prefix=$PREFIX $CONF_OPTS

make
make install
make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;
