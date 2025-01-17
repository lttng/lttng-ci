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
    string(name: 'LIBSK_GIT_URL', defaultValue: "{{libsk_git_url}}",
           description: "Git URL to clone from")
    string(name: 'LIBSK_GIT_BRANCH', defaultValue: "{{versions}}",
           description: "Git branch to checkout")
    booleanParam(name: 'LIBSK_TESTS_SKIP_TORTURE', defaultValue: true,
            description: 'Skip torture tests')
    booleanParam(name: 'LIBSK_TESTS_SKIP_REGRESSION', defaultValue: false,
            description: 'Skip regression tests')
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
        dir('src/libsk') {
          checkout([$class: 'GitSCM', branches: [[name: "${params.LIBSK_GIT_BRANCH}"]], userRemoteConfigs: [[url: "${params.LIBSK_GIT_URL}", credentialsId: 'a6e08541-e7fd-4da2-b58a-b87ee37736ef']], pool: true, changelog: true])

        }
        stash name: 'libsk-source', includes: 'src/libsk/**'
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
            name 'CC'
            values {{ccs|to_groovy(skip_list_wrap=true)}}
          }
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

        options {
          timeout(time: 10, unit: 'MINUTES')
        }

        environment {
          CXX = "${ -> get_cxx(CC) }"
        }

        stages {
          stage('Pre-build') {
            steps {
              cleanWs()
              sh('env')
            }
          }

          stage('Configure') {
            steps {
              unstash('libsk-source')
              sh("mkdir -p \$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/{build,log}")
              dir('src/libsk') {
                sh('./bootstrap')
                sh("./configure --prefix='/build'")
              }
            }
          }

          stage('Build') {
            steps {
              dir('src/libsk') {
                sh('make -j$(nproc)')
              }
            }
          }

          stage('Install') {
            steps {
              dir('src/libsk') {
                sh("DESTDIR=\"\$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/\" make install")
              }

              // Clean-up rpaths and .la files
              sh("find \$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/build/ -type f -name '*.so' -exec chrpath --delete {} \\;")
              sh("find \$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/build/ -name '*.la' -delete")
            }
          }

          stage('Test') {
            options {
              timeout(time: 30, unit: 'MINUTES')
            }

            environment {
              SK_TESTS_SKIP_REGRESSION = "${ -> params.LIBSK_TESTS_SKIP_REGRESSION ? 'true' : ''}"
              SK_TESTS_SKIP_TORTURE = "${ -> params.LIBSK_TESTS_SKIP_TORTURE ? 'true' : ''}"
            }

            steps {
              dir('src/libsk') {
                sh('make check')
              }
            }

            post {
              always {
                sh("rsync -ra --prune-empty-dirs --include='*/' --include='*.trs' --include='*.log' --exclude='*' src/libsk/ \$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/log/")
                sh("rsync -ra --prune-empty-dirs --include='*/' --exclude=test-suite.log --include='*.log' --exclude='*' src/libsk/tests/ \$WORKSPACE/platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/tap/")

                dir('src/libsk') {
                  sh('make clean')
                }

                archiveArtifacts(
                  artifacts: 'platform*/**,build/**,tap/**,log/**,core.tar.xz',
                  allowEmptyArchive: true,
                  fingerprint: true,
                  onlyIfSuccessful: false
                )

                step($class: 'TapPublisher',
                     testResults: "platform=${platform}/conf=${conf}/build=${build}/cc=${CC}/tap/**/*.log",
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
