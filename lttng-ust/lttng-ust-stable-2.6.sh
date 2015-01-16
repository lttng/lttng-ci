# Create build directory
rm -rf $WORKSPACE/build
mkdir -p $WORKSPACE/build

# liburcu
URCU_INCS="$WORKSPACE/dependencies/liburcu/build/include/"
URCU_LIBS="$WORKSPACE/dependencies/liburcu/build/lib/"

export CPPFLAGS="-I$URCU_INCS"
export LDFLAGS="-L$URCU_LIBS"
export LD_LIBRARY_PATH="$URCU_LIBS:$LD_LIBRARY_PATH"

PREFIX="$WORKSPACE/build"

./bootstrap

CONF_OPTS=""

case "$conf" in
# Unsupported! liblttng-ust can't pull in it's static (.a) dependencies.
#static)
#    echo "Static build"
#    CONF_OPTS="--enable-static --disable-shared"
#    ;;
java-agent)
    echo "Java agent build"
    export CLASSPATH="/usr/share/java/log4j-1.2.jar"
    CONF_OPTS="--enable-java-agent-all"
    ;;
*)
    echo "Standard build"
    CONF_OPTS=""
    ;;
esac

./configure --prefix=$PREFIX $CONF_OPTS
make V=1
make install

# Run tests
rm -rf $WORKSPACE/tap
mkdir -p $WORKSPACE/tap/unit

cd $WORKSPACE/tests

prove --merge --exec '' - < $WORKSPACE/tests/unit_tests --archive $WORKSPACE/tap/unit/ || true

# TAP plugin is having a hard time with .yml files.
rm -f $WORKSPACE/tap/unit/meta.yml

# And also with files without extension, so rename all result to *.tap
find $WORKSPACE/tap/unit/ -type f -exec mv {} {}.tap \;

# Cleanup
make clean

# Cleanup rpath and libtool .la files
find $WORKSPACE/build/lib -name "*.so" -exec chrpath --delete {} \;
find $WORKSPACE/build/lib -name "*.la" -exec rm -f {} \;
