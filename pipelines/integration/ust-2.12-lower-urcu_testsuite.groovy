#!groovy

pipeline {
  agent none

  /* Global options for the pipeline */
  options {
    preserveStashes()
    buildDiscarder(logRotator(numToKeepStr: '5'))
    timeout(time: 2, unit: 'HOURS')
    disableConcurrentBuilds()
    timestamps()
    skipDefaultCheckout()
  }

  triggers {
    pollSCM('@hourly')
  }

  /* Top level sequential stages */
  stages {

    /* First level stage */
    stage('Prepare targets') {
      agent { label 'amd64' }

      stages {
        stage('Checkout sources') {
          steps {
            cleanWs()

            dir("src/ust/stable-2.12-lower-urcu-dep") {
              checkout([$class: 'GitSCM', branches: [[name: 'stable-2.12-lower-urcu-dep']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://git.efficios.com/deliverable/lttng-ust.git']]])
            }
            dir("src/ust/stable-2.13") {
              checkout([$class: 'GitSCM', branches: [[name: 'stable-2.13']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/lttng/lttng-ust']]])
            }

            dir("src/urcu/stable-0.9") {
              checkout([$class: 'GitSCM', branches: [[name: 'stable-0.9']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://git.lttng.org/userspace-rcu']]])
            }
            dir("src/urcu/stable-0.12") {
              checkout([$class: 'GitSCM', branches: [[name: 'stable-0.12']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/urcu/userspace-rcu']]])
            }

            dir("src/babeltrace/stable-2.0") {
              checkout([$class: 'GitSCM', branches: [[name: 'stable-2.0']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/efficios/babeltrace']]])
            }
          }
        }

        stage('Generate UST 2.12 targets') {
           environment {
             TARGETS = "$WORKSPACE/targets"
             CUR_TARGET = "current"
             CPPFLAGS = "-I$TARGETS/$CUR_TARGET/include"
             LDFLAGS = "-L$TARGETS/$CUR_TARGET/lib"
             CLASSPATH = "/usr/share/java/log4j-1.2.jar"
           }

          steps {
            // Create empty include dir to make gcc '-Wmissing-include-dirs' happy
            sh 'mkdir -p "$TARGETS/$CUR_TARGET/include"'

            // Build babeltrace 2.0
            dir("src/babeltrace/stable-2.0") {
              sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --disable-static && make -j"$(nproc)" V=1 && make check && make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Add symlink from babeltrace2 to babeltrace
            dir("$TARGETS/$CUR_TARGET/bin") {
              sh 'ln -s babeltrace2 babeltrace'
            }

            // Build liburcu 0.9 for ust 2.12
            dir("src/urcu/stable-0.9") {
              sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --disable-static && make -j"$(nproc)" V=1 && make check && make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Build ust 2.12 against liburcu 0.9
            dir("src/ust/stable-2.12-lower-urcu-dep") {
              sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --enable-python-agent --enable-java-agent-all --enable-jni-interface && make -j"$(nproc)" V=1 && make check && make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Make a copy of the ust 2.12 target with only urcu 0.9
            dir("$TARGETS") {
              sh 'cp -dpr "$CUR_TARGET" "ust-2.12-urcu-0.9"'
            }

            // Remove the 'dev' part of liburcu 0.9, keep only the versionned SO
            dir("$TARGETS/$CUR_TARGET") {
              sh 'rm -rf "$TARGETS/$CUR_TARGET/include/urcu" && rm -f "$TARGETS/$CUR_TARGET/include/"urcu*.h && rm -f "$TARGETS/$CUR_TARGET/lib/"liburcu*.so && rm -f "$TARGETS/$CUR_TARGET/lib/pkgconfig/"liburcu*'
            }

            // Build liburcu 0.12 for tools 2.12
            dir("src/urcu/stable-0.12") {
              sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --disable-static && make -j"$(nproc)" V=1 && make check && make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Copy the liburcu 0.12 runtime SO to the ust-2.12-urcu-0.9 target
            sh 'cp -dpr "$TARGETS/$CUR_TARGET/lib/"liburcu*.so.6* "$TARGETS/ust-2.12-urcu-0.9/lib"'

            dir("$TARGETS") {

              // Archive the first ust 2.12 target with urcu 0.9 dev+runtime and 0.12 runtime
              stash name: "ust-2.12-urcu-0.9", includes: 'ust-2.12-urcu-0.9/**'
              archiveArtifacts artifacts: 'ust-2.12-urcu-0.9/**', fingerprint: false

              // Archive the second ust 2.12 target with urcu 0.9 runtime and 0.12 dev+runtime
              sh 'mv "$CUR_TARGET" "ust-2.12-urcu-0.12"'
              stash name: "ust-2.12-urcu-0.12", includes: 'ust-2.12-urcu-0.12/**'
              archiveArtifacts artifacts: 'ust-2.12-urcu-0.12/**', fingerprint: false
            }
          }
        }

        stage('Generate UST 2.13 target') {
           environment {
             TARGETS = "$WORKSPACE/targets"
             CUR_TARGET = "current"
             CPPFLAGS = "-I$TARGETS/$CUR_TARGET/include"
             LDFLAGS = "-L$TARGETS/$CUR_TARGET/lib"
             PKG_CONFIG_PATH = "$TARGETS/$CUR_TARGET/lib/pkgconfig"
             CLASSPATH = "/usr/share/java/log4j-1.2.jar"
           }

          steps {
            // Create empty include dir to make gcc '-Wmissing-include-dirs' happy
            sh 'mkdir -p "$TARGETS/$CUR_TARGET/include"'

            // Install babeltrace 2.0 built in the previous stage in a fresh target
            dir("src/babeltrace/stable-2.0") {
              sh 'make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Add symlink from babeltrace2 to babeltrace
            dir("$TARGETS/$CUR_TARGET/bin") {
              sh 'ln -s babeltrace2 babeltrace'
            }

            // Install liburcu 0.12 built in the previous stage in a fresh target
            dir("src/urcu/stable-0.12") {
              sh 'make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Build ust 2.13 against liburcu 0.12
            dir("src/ust/stable-2.13") {
              sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --enable-python-agent --enable-java-agent-all --enable-jni-interface && make -j"$(nproc)" V=1 && make check && make install && find "$TARGETS/$CUR_TARGET" -name "*.la" -delete'
            }

            // Archive the target
            dir("$TARGETS") {
              sh 'mv "$CUR_TARGET" "ust-2.13"'
              stash name: "ust-2.13", includes: "ust-2.13/**"
              archiveArtifacts artifacts: 'ust-2.13/**', fingerprint: false
            }
          }
        }
      }
    }

    /* First level stage */
    stage('Test tools 2.12 / 2.13 in parallel') {
      parallel {
        // Parallel stage for tools 2.12
        stage('Test tools 2.12') {
          agent { label 'amd64' }

          environment {
            TARGETS = "$WORKSPACE/targets"
            CUR_TARGET = "current"
            CPPFLAGS = "-I$TARGETS/$CUR_TARGET/include"
            LDFLAGS = "-L$TARGETS/$CUR_TARGET/lib"
            PKG_CONFIG_PATH = "$TARGETS/$CUR_TARGET/lib/pkgconfig"
            CLASSPATH = "/usr/share/java/log4j-1.2.jar:$TARGETS/$CUR_TARGET/share/java/*"
            PYTHONPATH="$TARGETS/$CUR_TARGET/lib/python2.7/site-packages"
            LD_LIBRARY_PATH="$TARGETS/$CUR_TARGET/lib"
            PATH="$PATH:$TARGETS/$CUR_TARGET/bin"
          }

          stages {
            stage('Checkout tools 2.12 sources') {
              steps {
                cleanWs()

                dir("src/tools/stable-2.12") {
                  checkout([$class: 'GitSCM', branches: [[name: 'stable-2.12']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://github.com/lttng/lttng-tools']]])
                }
              }
            }

            stage('Unstash targets') {
              steps {
                dir("$TARGETS") {
                  unstash name: "ust-2.12-urcu-0.9"
                  unstash name: "ust-2.12-urcu-0.12"
                }
              }
            }

            stage('Build tools 2.12') {
              steps {
                // Restore the ust-2.12 target with urcu 0.12
                sh 'ln -sf "$TARGETS/ust-2.12-urcu-0.12" "$TARGETS/$CUR_TARGET"'

                // Build tools 2.12
                // --disable-dependency-tracking is important to allow rebuilding only the testapps
                dir("src/tools/stable-2.12") {
                  sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --enable-test-java-agent-all --enable-python-bindings --disable-dependency-tracking && make -j"$(nproc)" V=1'
                }

                // Swap the target to ust 2.12 with urcu 0.9
                sh 'rm -f "$TARGETS/$CUR_TARGET" && ln -sf "$TARGETS/ust-2.12-urcu-0.9" "$TARGETS/$CUR_TARGET"'

                // Rebuild the testapps with ust 2.12 urcu 0.9
                dir("src/tools/stable-2.12/tests") {
                  sh '''
                for dir in utils/testapp regression/tools/filtering regression/ust; do
                	cd $dir
                	make clean
                	make -j"$(nproc)" V=1
                	cd -
                done'''
                }

                // Swap back the target to ust 2.12 with urcu 0.12
                sh 'rm -f "$TARGETS/$CUR_TARGET" && ln -sf "$TARGETS/ust-2.12-urcu-0.12" "$TARGETS/$CUR_TARGET"'

              }
            }

            stage('Run tools 2.12 tests') {
              steps {
                // Run the tests
                dir("src/tools/stable-2.12") {
                  sh 'make --keep-going  check || true'
                  sh 'mkdir -p "$WORKSPACE/tap/ust-2.12"'
                  sh 'rsync -a --exclude "test-suite.log" --include \'*/\' --include \'*.log\' --exclude=\'*\' tests/ "$WORKSPACE/tap/ust-2.12"'
                }

                // Clean target
                sh 'rm -f "$TARGETS/$CUR_TARGET"'
              }
            }
          }

          post {
            always {
              recordIssues skipBlames: true, tools: [gcc(id: "gcc-ust-212")]
              step([$class: 'TapPublisher', testResults: 'tap/**/*.log', verbose: true, failIfNoResults: true, failedTestsMarkBuildAsFailure: true, planRequired: true])
              archiveArtifacts artifacts: 'tap/**', fingerprint: false
            }
            cleanup {
              cleanWs cleanWhenFailure: false
            }
          }
        }

        // Parallel stage for tools 2.13
        stage('Test tools 2.13') {
          agent { label 'amd64' }

          environment {
            TARGETS = "$WORKSPACE/targets"
            CUR_TARGET = "current"
            CPPFLAGS = "-I$TARGETS/$CUR_TARGET/include"
            LDFLAGS = "-L$TARGETS/$CUR_TARGET/lib"
            PKG_CONFIG_PATH = "$TARGETS/$CUR_TARGET/lib/pkgconfig"
            CLASSPATH = "/usr/share/java/log4j-1.2.jar:$TARGETS/$CUR_TARGET/share/java/*"
            PYTHONPATH="$TARGETS/$CUR_TARGET/lib/python2.7/site-packages"
            LD_LIBRARY_PATH="$TARGETS/$CUR_TARGET/lib"
            PATH="$PATH:$TARGETS/$CUR_TARGET/bin"
          }

          stages {
            stage('Checkout tools 2.13 sources') {
              steps {
                cleanWs()

                dir("src/tools/stable-2.13") {
                  checkout([$class: 'GitSCM', branches: [[name: 'stable-2.13']], extensions: [], gitTool: 'Default', userRemoteConfigs: [[url: 'https://git.lttng.org/lttng-tools']]])
                }
              }
            }

            stage('Unstash targets') {
              steps {
                dir("$TARGETS") {
                  unstash name: "ust-2.12-urcu-0.9"
                  unstash name: "ust-2.13"
                }
              }
            }

            stage('Build tools 2.13') {
              steps {
                // Restore the ust-2.13 target
                sh 'ln -sf "$TARGETS/ust-2.13" "$TARGETS/$CUR_TARGET"'

                // Disable regression tests that don't apply to ust 2.12
                dir("src/tools/stable-2.13/tests/regression") {
                  sh '''
                    sed -i '/tools\\/notification\\/test_notification_ust_error/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_ust_capture/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_ust_event_rule_condition_exclusion/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_kernel_error/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_kernel_capture/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_kernel_instrumentation/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_kernel_syscall/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_notifier_discarded_count/d' Makefile.am
                    sed -i '/tools\\/notification\\/test_notification_kernel_userspace_probe/d' Makefile.am
                    sed -i '/tools\\/tracker\\/test_event_tracker/d' Makefile.am
                    sed -i '/tools\\/trigger\\/start-stop\\/test_start_stop/d' Makefile.am
                    sed -i '/tools\\/trigger\\/test_add_trigger_cli/d' Makefile.am
                    sed -i '/tools\\/trigger\\/test_list_triggers_cli/d' Makefile.am
                    sed -i '/tools\\/trigger\\/test_remove_trigger_cli/d' Makefile.am
                    sed -i '/tools\\/trigger\\/name\\/test_trigger_name_backwards_compat/d' Makefile.am
                    sed -i '/tools\\/trigger\\/rate-policy\\/test_ust_rate_policy/d' Makefile.am

                    sed -i 's/\\(tools\\/clear\\/test_kernel\\) \\\\/\\1/' Makefile.am
                    sed -i 's/\\(tools\\/relayd-grouping\\/test_ust\\) \\\\/\\1/' Makefile.am
                  '''
                }

                // Build tools 2.13 with ust 2.13
                // --disable-dependency-tracking is important to allow rebuilding only the testapps with ust 2.12
                dir("src/tools/stable-2.13") {
                  sh './bootstrap && ./configure --prefix="$TARGETS/$CUR_TARGET" --enable-test-java-agent-all --enable-python-bindings --disable-dependency-tracking && make -j"$(nproc)" V=1'
                }

                // Swap the target to ust 2.12
                sh 'rm -f "$TARGETS/$CUR_TARGET" && ln -sf "$TARGETS/ust-2.12-urcu-0.9" "$TARGETS/$CUR_TARGET"'

                // Rebuild the testapps with ust 2.12
                dir("src/tools/stable-2.13/tests") {
                  sh '''
                for dir in utils/testapp regression/tools/filtering regression/ust; do
                	cd $dir
                	find . -name Makefile | xargs sed -i "s/-llttng-ust-common//"
                	make clean
                	make -j"$(nproc)" V=1
                	cd -
                done'''
                }

                // Add the ust 2.13 runtime to the target
                sh 'cp -dp "$TARGETS/ust-2.13/lib/"liblttng-ust-*.so.1* "$TARGETS/$CUR_TARGET/lib/"'
                sh 'cp -dp "$TARGETS/ust-2.13/lib/"liblttng-ust-ctl.so.5* "$TARGETS/$CUR_TARGET/lib/"'
              }
            }

            stage('Run tools 2.13 tests') {
              steps {
                // Run the regression tests
                dir("src/tools/stable-2.13/tests/regression") {
                  sh 'make --keep-going check || true'
                }

                // Archive the tap tests results
                dir("src/tools/stable-2.13") {
                  sh 'mkdir -p "$WORKSPACE/tap/ust-2.13"'
                  sh 'rsync -a --exclude "test-suite.log" --include \'*/\' --include \'*.log\' --exclude=\'*\' tests/ "$WORKSPACE/tap/ust-2.13"'
                }

                // Clean target
                sh 'rm -f "$TARGETS/$CUR_TARGET"'
              }
            }
          }

          post {
            always {
              recordIssues skipBlames: true, tools: [gcc(id: "gcc-ust-213")]
              step([$class: 'TapPublisher', testResults: 'tap/**/*.log', verbose: true, failIfNoResults: true, failedTestsMarkBuildAsFailure: true, planRequired: true])
              archiveArtifacts artifacts: 'tap/**', fingerprint: false
            }
            cleanup {
              cleanWs cleanWhenFailure: false
            }
          }
        }
      }
    }
  }
}
