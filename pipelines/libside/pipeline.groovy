#!groovy
// SPDX-License-Identifier: GPL-2.0-only
// SPDX-FileCopyrightText: 2025 Kienan Stewart <kstewart@efficios.com>

@NonCPS
def get_cxx(cc) {
  result = ''
  switch(cc) {
    case 'gcc':
      result = 'g++'
      break
    case 'clang':
      result = 'clang++'
      break
    case ~/clang-\d+/:
      result = 'clang++-' + cc.split('-')[1]
      break
    case ~/gcc-\d+/:
      result = 'g++-' + cc.split('-')[1]
      break
  }
  return "${result}"
}

@NonCPS
def get_build_path(platform, conf, build, cc, rseq_version) {
  return "platform=${platform}/conf=${conf}/build=${build}/cc=${cc}/rseq=${rseq_version}"
}

pipeline {
  agent none

  options {
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '2'))
    skipDefaultCheckout()
    preserveStashes()
    timestamps()
  }

  parameters {
    string(name: 'email_to', defaultValue: '{{email_to}}',
           description: 'Email(s) to notify on build completion')
    string(name: 'LIBSIDE_GIT_URL', defaultValue: "{{libside_git_url}}",
           description: "Git URL to clone from")
    string(name: 'LIBSIDE_GIT_BRANCH', defaultValue: "{{versions}}",
           description: "Git branch to checkout")
    string(name: 'LIBRSEQ_GIT_URL', defaultValue: "{{librseq_git_url}}",
           description: "Git URL to clone librseq from")
    booleanParam(name: 'LIBRSEQ_TEST', defaultValue: true,
           description: "Should librseq be tested after building from source")
  }

  triggers {
    pollSCM('@hourly')
  }

  stages {
    stage('Checkout') {
      agent {
        label 'deb12-amd64'
      }

      steps {
        dir('src/libside') {
          checkout([$class: 'GitSCM', branches: [[name: "${params.LIBSIDE_GIT_BRANCH}"]], userRemoteConfigs: [[url: "${params.LIBSIDE_GIT_URL}"]], poll: true, changelog: true])

        }
        stash name: 'libside-source', includes: 'src/libside/**'

        dir('src/librseq') {
          checkout([$class: 'GitSCM', branches: [[name: {{librseq_versions|to_groovy()}}]], userRemoteConfigs: [[url: "${params.LIBRSEQ_GIT_URL}"]]])
        }
        stash name: "librseq-source-{{librseq_versions}}", includes: 'src/librseq/**'
      }
    }

    stage('matrix') {
      matrix {
        axes {
          axis {
            name 'platform'
            values {{platforms|to_groovy(skip_list_wrap=true)}}
          }
          axis {
            name 'conf'
            values {{confs|to_groovy(skip_list_wrap=true)}}
          }
          axis {
            name 'build'
            values {{builds|to_groovy(skip_list_wrap=true)}}
          }
          axis {
            // Note: using lower-case 'cc' will prevent setting the environment variable 'CC'
            name 'CC'
            values {{ccs|to_groovy(skip_list_wrap=true)}}
          }
          axis {
            name 'rseq_version'
            values {{librseq_versions|to_groovy(skip_list_wrap=true)}}
          }
        }

        environment {
          CXX = "${ -> get_cxx(CC) }"
          BUILD_PATH = "${ -> get_build_path(platform, conf, build, CC, rseq_version) }"
          PATH = "${env.WORKSPACE}/${ -> get_build_path(platform, conf, build, CC, rseq_version)}/build/deps/build/bin:${env.PATH}"
          LD_LIBRARY_PATH = "${env.WORKSPACE}/${ -> get_build_path(platform, conf, build, CC, rseq_version)}/build/deps/build/lib"
          PKG_CONFIG_PATH = "${env.WORKSPACE}/${ -> get_build_path(platform, conf, build, CC, rseq_version)}/build/deps/build/lib/pkgconfig"
          CPPFLAGS="-I${env.WORKSPACE}/${ -> get_build_path(platform, conf, build, CC, rseq_version)}/build/deps/build/include"
          LD_FLAGS="-L${env.WORKSPACE}/${ -> get_build_path(platform, conf, build, CC, rseq_version)}/build/deps/build/lib"
        }

        {% if filter != '' %}
        when {
          beforeAgent true
          expression {
            {{filter}}
          }
        }
        {% endif %}

        agent {
          label platform
        }

        stages {
          stage('Pre-build') {
            steps {
              cleanWs()
              sh('env')
              script {
                sh(
                  label: 'mkdirs',
                  script: "mkdir -p \"\$WORKSPACE/\$BUILD_PATH/{build,deps,log,tap}\""
                )
              }
            }
          }

          stage('Dependencies') {
            stages {
              stage('librseq') {
                stages {
                  stage('configure and build') {
                    steps {
                      unstash "librseq-source-${rseq_version}"
                      dir('src/librseq') {
                        sh('./bootstrap')
                        sh('./configure --prefix=/build')
                        sh('make -j$(nproc)')
                      }
                    }
                  }
                  stage('test') {
                    when { expression { params.LIBRSEQ_TEST } }
                    steps {
                      dir('src/librseq') {
                        sh('make check')
                      }
                    }
                  }
                  stage('install') {
                    steps {
                      dir('src/librseq') {
                        sh(
                          label: "install",
                          script: "DESTDIR=\"\$WORKSPACE/\$BUILD_PATH/build/deps/\" make install"
                        )
                      }
                    }
                  }
                }
              }
            }
          }

          stage('Configure') {
            steps {
              unstash('libside-source')
              dir('src/libside') {
                sh('tree $WORKSPACE/$BUILD_PATH/build/deps')
                sh('./bootstrap')
                sh('./configure --prefix=/build')
              }
            }
          }

          stage('Build') {
            steps {
              dir('src/libside') {
                sh('make -j$(nproc)')
              }
            }
          }

          stage('Install') {
            steps {
              dir('src/libside') {
                sh('DESTDIR="$WORKSPACE/$BUILD_PATH/" make install')
              }

              // Clean-up rpaths and .la files
              sh("find \$WORKSPACE/\$BUILD_PATH/build/ -type f -name '*.so' -exec chrpath --delete {} \\;")
              sh("find \$WORKSPACE/\$BUILD_PATH/build/ -name '*.la' -delete")
            }
          }

          stage('Test') {
            options {
              timeout(time: 30, unit: 'MINUTES')
            }

            steps {
              dir('src/libside') {
                sh('make check')
              }
            }

            post {
              always {
                sh("rsync -ra --prune-empty-dirs --include='*/' --include='*.trs' --include='*.log' --exclude='*' src/libside/ \$WORKSPACE/\$BUILD_PATH/log/")
                sh("rsync -ra --prune-empty-dirs --include='*/' --exclude=test-suite.log --include='*.log' --exclude='*' src/libside/tests/ \$WORKSPACE/\$BUILD_PATH/tap/")

                dir('src/libside') {
                  sh('make clean')
                }

                archiveArtifacts(
                  artifacts: 'platform*/**,build/**,tap/**,log/**,core.tar.xz',
                  allowEmptyArchive: true,
                  fingerprint: true,
                  onlyIfSuccessful: false
                )

                step($class: 'TapPublisher',
                     testResults: "${env.BUILD_PATH}/tap/**/*.log",
                     failIfNoResults: true,
                     failedTestsMarkBuildAsFailure: true,
                     outputTapToConsole: true,
                     todoIsFailure: false,
                     includeCommentDiagnostics: true,
                     removeYamlIfCorrupted: true
                )
              }
              cleanup {
                cleanWs(cleanWhenFailure: false)
              }
            }
          }

       } // End stages
      } // End matrix
    } // End stage('matrix')
  } // End stages

  post {
    failure {
      emailext(
        subject: "${currentBuild.displayName} #${currentBuild.number} ${currentBuild.result} in ${currentBuild.durationString}",
        to: params.email_to,
        body: """
${currentBuild.result} in ${currentBuild.durationString}
description: ${currentBuild.description}

See job logs at ${currentBuild.absoluteUrl}/pipeline-console
See pipeline overview at ${currentBuild.absoluteUrl}/pipeline-graph

-- scm --
${env.CHANGE_URL} commit ${env.CHANGE_ID} branch ${env.CHANGE_BRANCH}
"""
      )
    }
  }
} // End pipeline
