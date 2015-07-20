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

def kernelTagCutOff = new BasicVersion("2.6.36", "")
def modulesBranches = ["master", "stable-2.5", "stable-2.6"]

//def modulesBranches = ["master","stable-2.5","stable-2.6", "stable-2.4"]

def linuxURL = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
def modulesURL = "https://github.com/lttng/lttng-modules.git"

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

	// If error set cutoff on last so no job are created
	if (cutoffPos == -1) {
		cutoffPos = versions.size()
	}
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


	println("CutOff index")
	println(cutoffPos)


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
                            copyArtifacts("${jobName}/arch=\$arch,label=kernel", "linux-artifact/**", '', false, false) {
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
import jenkins.model.*
import hudson.AbortException
import hudson.console.HyperlinkNote
import java.util.concurrent.CancellationException
import java.util.Random


Random random = new Random()
def jobs = hudson.model.Hudson.instance.items
def fail = false
def jobStartWithKernel = "KERNELPREFIX"
def jobStartWithModule = "MODULEPREFIX"
def toBuild = []
def counter = 0
def limitQueue = 4

def anotherBuild
jobs.each { job ->
  def jobName = job.getName()
  if (jobName.startsWith(jobStartWithKernel)) {
    counter = counter + 1
    def lastBuild = job.getLastBuild()
    if (lastBuild == null || lastBuild.result != Result.SUCCESS) {
      toBuild.push(job)
    } else {
      println("\tAlready built")
    }
  }
}

println "Kernel total "+ counter
println "Kernel to build "+ toBuild.size()


def kernelEnabledNode = 0
hudson.model.Hudson.instance.nodes.each { node ->
  if (node.getLabelString().contains("kernel")){
    kernelEnabledNode++
  }
}
println "Nb of live kernel enabled build node "+ kernelEnabledNode

def ongoingBuild = []
def q = jenkins.model.Jenkins.getInstance().getQueue() 

def queuedTaskKernel = 0
def queuedTaskModule = 0

while (toBuild.size() != 0) {
  // Throttle the build with both the number of current parent task and queued
  // task.Look for both kernel and downstream module from previous kernel.
  queuedTaskKernel = q.getItems().findAll {
    it.task.getParent().name.startsWith(jobStartWithKernel)
  }.size()

  queuedTaskModule = q.getItems().findAll {
	  it.task.getParent().name.startsWith(jobStartWithModule)
  }.size()

  it.task.getParent().name.startsWith(jobStartWithModule)
  if ((ongoingBuild.size() <= kernelEnabledNode.intdiv(2)) && (queuedTaskKernel + queuedTaskModule < limitQueue)) {
		def job = toBuild.pop()
		ongoingBuild.push(job.scheduleBuild2(0))
		println "\t trigering " + HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)
  } else {
    println "Currently " + ongoingBuild.size() + " build currently on execution. Limit: " + kernelEnabledNode.intdiv(2)
    println "Currently " + queuedTask.findAll{it.task.getParent().name.startsWith(jobStartWithModule)}.size() + " module jobs are queued. Limit: " + limitQueue
    println "Currently " + queuedTask.findAll{it.task.getParent().name.startsWith(jobStartWithKernel)}.size() + " kernel jobs are queued. Limit: " + limitQueue
    Thread.sleep(random.nextInt(60000))
    ongoingBuild.removeAll{ it.isCancelled() || it.isDone() }
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
import java.util.Random


Random random = new Random()
def jobs = hudson.model.Hudson.instance.items
def fail = false
def modulePrefix = "MODULEPREFIX"
def branchName = "BRANCHNAME"
def kernelPrefix = "KERNELPREFIX"
def nodeLabels=["kernel"]
def validNodeDivider = 2

def fullModulePrefix = modulesPrefix + branchName

def toBuild = []
def counter = 0
def limitQueue = 4

jobs.each { job ->
	def jobName = job.getName()
	if (jobName.startsWith(fullModulePrefix)) {
		counter = counter + 1
		toBuild.push(job)
	}
}

// Get valid labeled node node
def validNodeCount = 0
hudson.model.Hudson.instance.nodes.each { node ->
	def valid = true
	nodeLabels.each { label ->
		if (!node.getLabelString().contains(nodeLabel)){
			valid = false
			break;
		}
	}
	if (valid){
		validNodeCount++
	}
}

// Divide the valid node by validNodeDivider based on user defined label slave descriminant ex arck type
def finalValidNodeCount = validNodeCount.intdiv(validNodeDivider

// Scheduling

def ongoingBuild = []
def q = jenkins.model.Jenkins.getInstance().getQueue()
def queuedTaskKernel = 0
def queuedTaskModule = 0
def sleep = 0

while (toBuild.size() != 0) {
	// Throttle the build with both the number of current parent task and queued
	// task.Look for both kernel and downstream module from previous kernel.
	queuedTaskKernel = q.getItems().findAll {it.task.getParent().getDisplayName().startsWith(jobStartWithKernel)}.size()
	queuedTaskModule = q.getItems().findAll {it.task.getParent().getDisplayName().startsWith(jobStartWithModule)}.size()
	if ((ongoingBuild.size() <= finalValidNodeCount) && (queuedTaskKernel + queuedTaskModule < limitQueue)) {
		def job = toBuild.pop()
		ongoingBuild.push(job.scheduleBuild2(0))
		println "\t trigering " + HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)
	} else {
        println "Holding trigger"
        println "Currently " + ongoingBuild.size() + "  build ongoing. Max = " + validNodeCount
        println "Currently " + queuedTaskKernel + " Kernel build ongoing."
        println "Currently " + queuedTaskModule + " LTTng-modules build ongoing."
        println "Limit for combination of both:" + limitQueue
    
        sleep = random.nextInt(60000)
        println "Sleeping for " + sleep.intdiv(1000) + " seconds"
		Thread.sleep(sleep)
		ongoingBuild.removeAll{ it.isCancelled() || it.isDone() }
	}
}
if (fail){
	throw new AbortException("Some job failed")
}
"""

	dslTriggerKernel = dslTriggerKernel.replaceAll("KERNELPREFIX", kernelPrefix)
	dslTriggerKernel = dslTriggerKernel.replaceAll("MODULEPREFIX", modulesPrefix)
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
			dslTriggerModule = dslTriggerModule.replaceAll("MODULEPREFIX",modulesPrefix + separator + branch + separator)
			dslTriggerModule = dslTriggerModule.replaceAll("BRANCHNAME",separator + branch + separator)
			freeStyleJob("dsl-trigger-module-${branch}") {
				steps {
					systemGroovyCommand(dslTriggerModule)
				}
				triggers {
					scm('@daily')
				}
			}
		}
    }
}
