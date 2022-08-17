#!groovy

{% set test_job_name = 'integration_lttng-tools-32-64_test' %}

pipeline {
	agent none

	/* Global options for the pipeline */
	options {
		preserveStashes()
		buildDiscarder(logRotator(numToKeepStr: '5'))
		disableConcurrentBuilds()
		timestamps()
		skipDefaultCheckout()
	}

	triggers {
		pollSCM('@hourly')
	}

	parameters {
	    string(name: 'LTTNG_TOOLS_GIT_REPO', defaultValue: 'https://github.com/lttng/lttng-tools', description: 'The http git repo to be cloned for the lttng-tools project')
	    string(name: 'LTTNG_TOOLS_GIT_BRANCH', defaultValue: '{{ version }}', description: 'The {{ version }} equivalent branch to be checkout-ed')
	}

	stages {
		/*
		 * i386 artefact cannot be reused for 2 reason.
		 * The first one is that the amd64 and i386 node do not run the same distro and libc version.
		 * The second, is that we need to ensure that the lttng-ust used
		 * is the same for the amd64 and i386 and that for now we do not
		 * have this guarantee since we used 2 different jobs
		 */
		stage('Checkout all sources') {
			agent { label 'bionic-amd64' }
			steps {
				dir("src/userspace-rcu") {
					checkout([$class: 'GitSCM', branches: [[name: '{{ urcu_version }}']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/urcu/userspace-rcu']]])
				}
				dir("src/lttng-modules") {
					checkout([$class: 'GitSCM', branches: [[name: '{{ version }}']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/lttng/lttng-modules']]])
				}
				dir("src/lttng-ust") {
					checkout([$class: 'GitSCM', branches: [[name: '{{ version }}']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/lttng/lttng-ust']]])
				}
				dir("src/lttng-tools") {
					checkout([$class: 'GitSCM', branches: [[name: "${params.LTTNG_TOOLS_GIT_BRANCH}"]], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: "${params.LTTNG_TOOLS_GIT_REPO}"]]])
				}
				stash name: 'dep-sources', includes: 'src/userspace-rcu/**,src/lttng-ust/**'
				stash name: 'modules-sources', includes: 'src/lttng-modules/**'
				stash name: 'tools-sources', includes: 'src/lttng-tools/**,'
			}
		}

		stage('Build') {
			parallel {
				stage('Build amd64 deps') {
					agent { label 'bionic-amd64' }
					stages {
						stage('Clean workspace') {
							steps {
								cleanWs()
							}
						}

						stage('Build') {
							environment {
								BASEDIR_64 = "$WORKSPACE/deps-64"
								BASEDIR_BUILD_64 = "$BASEDIR_64/build"
								INCLUDE_DIR_64 = "$BASEDIR_BUILD_64/include"
								CPPFLAGS = "-I$INCLUDE_DIR_64"
								LDFLAGS = "-L$BASEDIR_BUILD_64/lib"
								PKG_CONFIG_PATH = "$BASEDIR_BUILD_64/lib/pkgconfig"
								LD_LIBRARY_PATH ="$BASEDIR_BUILD_64/lib:$LD_LIBRARY_PATH"
								PATH ="$PATH:$BASEDIR_64/bin"
								PREFIX = "/build"
								JAVA_HOME="/usr/lib/jvm/default-java"
								CLASSPATH="/usr/share/java/log4j-api.jar:/usr/share/java/log4j-core.jar:/usr/share/java/log4j-1.2.jar"
								PYTHON3="python3"
								PYTHON_CONFIG="python3-config"
								CXXFLAGS="-g -O0"
								CFLAGS="-g -O0"
							}
							steps {
								unstash name: 'dep-sources'

								/* Prevent non existent include dir warnings */
								sh 'mkdir -p $INCLUDE_DIR_64'

								dir("src/userspace-rcu") {
									sh '''
										./bootstrap
										./configure --prefix="$PREFIX"
										make -j"$(nproc)" V=1
										make install DESTDIR="$WORKSPACE"
									'''

									sh '''
										find "$WORKSPACE/build/lib" -name "*.so" -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.la" -exec rm -vf {} \\;
									'''
								}

								/* Move the artifact of the recently build project to the deps file and remove the "build" directory to prevent `make install` shenanigans for lttng-ust 2.12 */
								sh '''
									cp -rv build/ $BASEDIR_64
									rm -rv build/
								'''

								dir("src/lttng-ust") {
									sh '''
										./bootstrap
										./configure --prefix="$PREFIX" --enable-java-agent-all --enable-jni-interface --enable-python-agent
										make -j"$(nproc)" V=1
										make install DESTDIR="$WORKSPACE"
									'''

									sh '''
										find "$WORKSPACE/build/lib" -name "*.so" -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.la" -exec rm -vf {} \\;
									'''
								}

								/* Move the artifact of the recently build project to the deps file and remove the "build" directory to prevent `make install` shenanigans for lttng-ust 2.12 */
								sh '''
									cp -rv build/ $BASEDIR_64
									rm -rv build/
								'''

								stash name: "amd64-deps-lttng-tools", includes: 'deps-64/**'
							}
						}
					}
				}
				stage('Build i386, including lttng-tools') {
					agent { label 'bionic-i386' }
					stages {
						stage('Clean workspace') {
							steps {
								cleanWs()
							}
						}

						stage('Build') {
							environment {
								BASEDIR_32 = "$WORKSPACE/deps-32"
								BASEDIR_BUILD_32 = "$BASEDIR_32/build"
								INCLUDE_DIR_32 = "$BASEDIR_BUILD_32/include"
								CPPFLAGS = "-I$INCLUDE_DIR_32"
								LDFLAGS = "-L$BASEDIR_BUILD_32/lib"
								PKG_CONFIG_PATH = "$BASEDIR_BUILD_32/lib/pkgconfig"
								LD_LIBRARY_PATH ="$BASEDIR_BUILD_32/lib"
								PATH ="$PATH:$BASEDIR_32/bin"
								PREFIX = "/build"
								CXXFLAGS="-g -O0"
								CFLAGS="-g -O0"
							}
							steps {
								unstash name: 'dep-sources'
								unstash name: 'tools-sources'

								/* Prevent non existent include dir warnings */
								sh 'mkdir -p $INCLUDE_DIR_32'

								dir("src/userspace-rcu") {
									sh '''
										./bootstrap
										./configure --prefix="$PREFIX"
										make -j"$(nproc)" V=1
										make install DESTDIR="$WORKSPACE"
									'''

									sh '''
										find "$WORKSPACE/build/lib" -name "*.so" -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.la" -exec rm -vf {} \\;
									'''
								}

								/* Move the artifact of the recently build project to the deps file and remove the "build" directory to prevent `make install` shenanigans for lttng-ust 2.12 */
								sh '''
									cp -rv build/ $BASEDIR_32
									rm -rv build/
								'''


								dir("src/lttng-ust") {
									sh '''
										./bootstrap
										./configure --prefix="$PREFIX"
										make V=1
										make install DESTDIR="$WORKSPACE"
									'''

									sh '''
										find "$WORKSPACE/build/lib" -name "*.so" -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.la" -exec rm -vf {} \\;
									'''
								}

								/* Move the artifact of the recently build project to the deps file and remove the "build" directory to prevent `make install` shenanigans for lttng-ust 2.12 */
								sh '''
									cp -rv build/ $BASEDIR_32
									rm -rv build/
								'''

								dir("src/lttng-tools") {
									sh '''
										./bootstrap
										./configure --prefix="$PREFIX"
										make V=1
										make install DESTDIR="$WORKSPACE"
									'''
									sh '''
										find "$WORKSPACE/build/bin" -type f -perm -0500 -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.so" -exec chrpath --delete {} \\;
										find "$WORKSPACE/build/lib" -name "*.la" -exec rm -vf {} \\;
									'''
								}

								/* Move the artifact of the recently build project to the deps file and remove the "build" directory to prevent `make install` shenanigans for lttng-ust 2.12 */
								sh '''
									cp -rv build/ $BASEDIR_32
									rm -rv build/
								'''

								stash name: "i386-deps-lttng-tools", includes: 'deps-32/**'

								{% if version != 'stable-2.12' %}
								/* Save the i386 ld_preloaded libraries for sessiond pausing */
								stash name: "i386-deps-sessiond-notification-pause-lib", includes: 'src/lttng-tools/tests/regression/tools/notification/.libs/libpause_sessiond.so'
								{% endif %}
							}
						}
					}
				}
			}
		}
		stage('Object store') {
			agent { label 'bionic-amd64' }
			environment {
				S3_PREFIX = "s3://jenkins/32-64-bit-integration"
			}
			steps {
				cleanWs()
				dir('tar/sources') {
					unstash name: "modules-sources"
					unstash name: "tools-sources"
				}
				dir('tar/deps') {
					unstash name: "i386-deps-lttng-tools"
					unstash name: "amd64-deps-lttng-tools"
				}
				dir('tar/testing-overlay/sessiond') {
					{% if version == 'stable-2.12' %}
					sh '''
					echo "No testing overlay" > testing_overlay.txt
					'''
					{% else %}
					unstash name: "i386-deps-sessiond-notification-pause-lib"
					{% endif %}
				}

				dir('tar') {
					sh '''
						echo $(pwd)
						ls -lah ./
						tar -cf "$WORKSPACE/$BUILD_TAG.tar.bz2" -I pbzip2 .
					'''
				}

				sh '''
					echo "# Setup endpoint
					host_base = obj.internal.efficios.com
					host_bucket = obj.internal.efficios.com
					bucket_location = us-east-1
					use_https = True

					# Setup access keys
					access_key = jenkins
					secret_key = echo123456

					# Enable S3 v4 signature APIs
					signature_v2 = False" > "$WORKSPACE/.s3cfg"
					s3cmd -c "$WORKSPACE/.s3cfg" put "$WORKSPACE/$BUILD_TAG.tar.bz2" "$S3_PREFIX/"
				'''
			}

		}
		stage('Testing') {
			parallel {
				stage('canary') {
					agent none
					steps {
						build job: '{{ test_job_name }}', parameters: [string(name: 'ARTIFACT_ID', value: "${BUILD_TAG}.tar.bz2"), string(name: 'TEST_TYPE', value: 'canary'), string(name: 'BT_VERSION', value: "{{ babelversion }}")]
					}
				}
				stage('CLI 32-bit') {
					agent none
					steps {
						build job: '{{ test_job_name }}', parameters: [string(name: 'ARTIFACT_ID', value: "${BUILD_TAG}.tar.bz2"), string(name: 'TEST_TYPE', value: '32bit-cli'), string(name: 'BT_VERSION', value: "{{ babelversion }}")]
					}
				}
				stage('sessiond 32-bit') {
					agent none
					steps {
						build job: '{{ test_job_name }}', parameters: [string(name: 'ARTIFACT_ID', value: "${BUILD_TAG}.tar.bz2"), string(name: 'TEST_TYPE', value: '32bit-sessiond'), string(name: 'BT_VERSION', value: "{{ babelversion }}")]
					}
				}
				stage('relayd 32-bit') {
					agent none
					steps {
						build job: '{{ test_job_name }}', parameters: [string(name: 'ARTIFACT_ID', value: "${BUILD_TAG}.tar.bz2"), string(name: 'TEST_TYPE', value: '32bit-relayd'), string(name: 'BT_VERSION', value: "{{ babelversion }}")]
					}
				}
			}
		}
	}
}
