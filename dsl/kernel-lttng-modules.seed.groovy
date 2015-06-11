enum KernelVersioning {
    MAJOR,MINOR,REVISION,BUILD
}

class BasicVersion implements Comparable<BasicVersion> {
    int major = -1
    int minor = -1
    int revision = -1
    int build = -1
    int rc = -1
    String gitRefs

    // Default Constructor
    BasicVersion() {}

    // Parse a version string of format X.Y.Z.W-A
    BasicVersion(String version, String ref) {
        gitRefs = ref
        def tokenVersion
        def token
        if (version.contains('-')) {
            // Release canditate
            token = version.tokenize('-')
            tokenVersion = token[0]
            if (token[1]?.isInteger()) {
                rc = token[1].toInteger()
            }
        } else {
            tokenVersion = version
        }

        tokenVersion = tokenVersion.tokenize('.')

        def tagEnum = KernelVersioning.MAJOR
        tokenVersion.each {
            if (it?.isInteger()) {
                switch (tagEnum) {
                    case KernelVersioning.MAJOR:
                        major = it.toInteger()
                        tagEnum = KernelVersioning.MINOR
                        break
                    case KernelVersioning.MINOR:
                        minor = it.toInteger()
                        tagEnum = KernelVersioning.REVISION
                        break
                    case KernelVersioning.REVISION:
                        revision = it.toInteger()
                        tagEnum = KernelVersioning.BUILD
                        break
                    case KernelVersioning.BUILD:
                        build = it.toInteger()
                        tagEnum = -1
                        break
                    default:
                        println("Unsupported version extension")
                        println("Trying to parse: ${version}")
                        println("Invalid sub version value: ${it}")
                //TODO: throw exception for jenkins
                }
            }
        }
    }

    String print() {
        String ret = ""
        if (major != -1) {
            ret += major
            if (minor != -1) {
                ret += "." + minor
                if (revision != -1) {
                    ret += "." + revision
                    if (build != -1) {
                        ret += "." + build
                    }
                }
            }
            if (rc != -1) {
                ret += "-rc" + rc
            }
        }
        return ret
    }

    @Override
    int compareTo(BasicVersion kernelVersion) {
        return major <=> kernelVersion.major ?: minor <=> kernelVersion.minor ?: revision <=> kernelVersion.revision ?: build <=> kernelVersion.build ?: rc <=> kernelVersion.rc
    }
}

def kernelTagCutOff = new BasicVersion("4.3", "")
def modulesBranches = ["master","stable-2.5","stable-2.6", "stable-2.4"]


def linuxURL = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
def modulesURL = "git://git.lttng.org/lttng-modules.git"

// Linux specific variable
String linuxCheckoutTo = "linux-source"
String recipeCheckoutTo = "recipe"
String modulesCheckoutTo = "lttng-modules"

def linuxGitReference = "/home/jenkins/gitcache/linux-stable.git"

// Check if we are on jenkins
// Useful for outside jenkins devellopment related to groovy only scripting
def isJenkinsInstance = binding.variables.containsKey('JENKINS_HOME')

// Fetch tags and format
// Split the string into sections based on |
// And pipe the results together
String process = "git ls-remote -t $linuxURL | cut -c42- | sort -V"
def out = new StringBuilder()
def err = new StringBuilder()
Process result = process.tokenize( '|' ).inject( null ) { p, c ->
    if( p )
        p | c.execute()
    else
        c.execute()
}

result.waitForProcessOutput(out,err)

if ( result.exitValue() == 0 ) {
    def branches = out.readLines().collect {
        // Scrap special string tag
        it.replaceAll("\\^\\{\\}", '')
    }

    branches = branches.unique()

    List versions = []
    branches.each { branch ->
        def stripBranch = branch.replaceAll("rc", '').replaceAll(/refs\/tags\/v/,'')
        BasicVersion kVersion = new BasicVersion(stripBranch, branch)
        versions.add(kVersion)
    }

    // Sort the version via Comparable implementation of KernelVersion
    versions = versions.sort()

    // Find the version cutoff
    def cutoffPos = versions.findIndexOf{(it.major >= kernelTagCutOff.major) && (it.minor >= kernelTagCutOff.minor) && (it.revision >= kernelTagCutOff.revision) && (it.build >= kernelTagCutOff.build) && (it.rc >= kernelTagCutOff.rc)}

    // Get last version and include only last rc
    def last
    def lastNoRcPos
    last = versions.last()
    if (last.rc != -1) {
        int i = versions.size()-1
        while (i > -1 && versions[i].rc != -1 ) {
            i--
        }
        lastNoRcPos = i + 1
    } else {
        lastNoRcPos = versions.size()
    }

    String modulesPrefix = "lttng-modules"
    String kernelPrefix = "dsl-kernel"
    String separator = "-"
    // Actual job creation
    for (int i = cutoffPos; i < versions.size() ; i++) {

        // Only create for valid build
        if ( (i < lastNoRcPos && versions[i].rc == -1) || (i >= lastNoRcPos)) {
            println ("Preparing job for")

            String jobName = kernelPrefix + separator + versions[i].print()

            // Generate modules job based on supported modules jobs
            def modulesJob = [:]
            modulesBranches.each { branch ->
                modulesJob[branch] = modulesPrefix + separator + branch + separator + jobName
            }

            // Jenkins only dsl
            println(jobName)
            if (isJenkinsInstance) {
                matrixJob("${jobName}") {
                    using("linux-master")
                    scm {
                        git {
                            remote {
                                url("${linuxURL}")
                            }
                            branch(versions[i].gitRefs)
                            shallowClone(true)
                            relativeTargetDir(linuxCheckoutTo)
                            reference(linuxGitReference)
                        }
                    }
                    publishers {
                        modulesJob.each {
                            downstream(it.value, 'SUCCESS')
                        }
                    }
                }
            }
            // Corresponding Module job
            modulesJob.each { job ->
                println("\t" + job.key + " " + job.value)
                if (isJenkinsInstance) {
                    matrixJob(job.value) {
                        using("modules")
                        multiscm {
                            git {
                                remote {
                                    name(kernelPrefix)
                                    url("${linuxURL}")
                                }
                                branch(versions[i].gitRefs)
                                shallowClone(true)
                                relativeTargetDir(linuxCheckoutTo)
                                reference(linuxGitReference)
                            }
                            git {
                                remote {
                                    name(modulesPrefix)
                                    url(modulesURL)
                                }
                                branch(job.key)
                                relativeTargetDir(modulesCheckoutTo)
                            }
                        }
                        steps {
                            copyArtifacts("${jobName}/arch=\$arch", "linux-artifact/**", '', false, false) {
                                latestSuccessful(true) // Latest successful build
                            }
                            shell(readFileFromWorkspace('lttng-modules/lttng-modules-dsl-master.sh'))
                        }
                    }
                }
            }
        }
    }

    // Trigger generations
    def dslTriggerKernel = """\

import hudson.model.*
import hudson.AbortException
import hudson.console.HyperlinkNote
import java.util.concurrent.CancellationException


def jobs = hudson.model.Hudson.instance.items
def fail = false
def jobStartWith = "${kernelPrefix}"

def anotherBuild
jobs.each { job ->
  def jobName = job.getName()
  if (jobName.startsWith(jobStartWith)) {
    def lastBuild = job.getLastBuild()
    if (lastBuild == null) {
      try {
        def future = job.scheduleBuild2(0, new Cause.UpstreamCause(build))
        println "\\tWaiting for the completion of " + HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)
        anotherBuild = future.get()
      } catch (CancellationException x) {
        throw new AbortException("\${job.fullDisplayName} aborted.")
      }
      println HyperlinkNote.encodeTo('/' + anotherBuild.url, anotherBuild.fullDisplayName) + " completed. Result was " + anotherBuild.result

      build.result = anotherBuild.result
      if (anotherBuild.result != Result.SUCCESS && anotherBuild.result != Result.UNSTABLE) {
        // We abort this build right here and now.
        fail = true
        println("Build Failed")
      }
    } else {
      println("\\tAlready built")
    }
  }
}

if (fail){
  throw new AbortException("Some job failed")
}
"""
	def dslTriggerModule = """\
import hudson.model.*
import hudson.AbortException
import hudson.console.HyperlinkNote
import java.util.concurrent.CancellationException


def jobs = hudson.model.Hudson.instance.items
def fail = false
def jobStartWith = "JOBPREFIX"

def anotherBuild
jobs.each { job ->
  def jobName = job.getName()
  if (jobName.startsWith(jobStartWith)) {
    def lastBuild = job.getLastBuild()
    if (lastBuild == null) {
      try {
        def future = job.scheduleBuild2(0, new Cause.UpstreamCause(build))
        println "\\tWaiting for the completion of " + HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)
        anotherBuild = future.get()
      } catch (CancellationException x) {
        throw new AbortException("\${job.fullDisplayName} aborted.")
      }
      println HyperlinkNote.encodeTo('/' + anotherBuild.url, anotherBuild.fullDisplayName) + " completed. Result was " + anotherBuild.result

      build.result = anotherBuild.result
      if (anotherBuild.result != Result.SUCCESS && anotherBuild.result != Result.UNSTABLE) {
        // We abort this build right here and now.
        fail = true
        println("Build Failed")
      }
    } else {
      println("\\tAlready built")
    }
  }
}

if (fail){
  throw new AbortException("Some job failed")
}
"""
    if (isJenkinsInstance) {
        freeStyleJob("dsl-trigger-kernel") {
            steps {
                systemGroovyCommand(dslTriggerKernel)
            }
			triggers {
				cron("H 0 * * *")
			}
		}

		modulesBranches.each { branch ->
			freeStyleJob("dsl-trigger-module-${branch}") {
				steps {
					systemGroovyCommand(dslTriggerModule.replaceAll("JOBPREFIX",modulesPrefix + separator + branch + separator))
				}
				triggers {
					scm('@daily')
				}
			}
		}
    }
}
