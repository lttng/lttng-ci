enum KernelVersioning {
    MAJOR,MINOR,REVISION,BUILD
}

class KernelVersion implements Comparable<KernelVersion> {
    int major = -1
    int minor = -1
    int revision = -1
    int build = -1
    int rc = -1
    String gitRefs

    // Default Constructor
    KernelVersion() {}

    // Parse a version string of format X,Y,Z,W-A
    KernelVersion(String version, String ref) {
        gitRefs = ref
		def tokenVersion
        def token
        if (version.contains('-')) {
            // Release canditate
            token = version.tokenize('-')
            tokenVersion = token[0]
            if (token[1].isInteger()) {
                rc = token[1].toInteger()
            }
        } else {
            tokenVersion = version
        }

        tokenVersion = tokenVersion.tokenize('.')

        def tagEnum = KernelVersioning.MAJOR
        tokenVersion.each {
            if (it.isInteger()) {
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
    int compareTo(KernelVersion kernelVersion) {
        return major <=> kernelVersion.major ?: minor <=> kernelVersion.minor ?: revision <=> kernelVersion.revision ?: build <=> kernelVersion.build ?: rc <=> kernelVersion.rc
    }
}

def cutoff = [major: 3, minor: 19,revision:-1, build:-1, rc:-1]
def linuxURL = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
def modulesURL = "git://git.lttng.org/lttng-modules.git"

// Linux specific variable
String linuxCheckoutTo = "linux-source"
String recipeCheckoutTo = "recipe"
String modulesCheckoutTo = "lttng-modules"

def linuxGitReference = "/home/jenkins/gitcache/linux-stable.git"
String process = "git ls-remote -t $linuxURL | cut -c42- | sort -V"

// Chekf if we are on jenkins
// Useful for outside jenkins devellopment related to groovy only scripting
def isJenkinsInstance = binding.variables.containsKey('JENKINS_HOME')

// Split the string into sections based on |
// And pipe the results together
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
        KernelVersion kVersion = new KernelVersion(stripBranch, branch)
        versions.add(kVersion)
    }

    // Sort the version via Comparable implementation of KernelVersion
    versions = versions.sort()

    // Find the version cut of
    def cutoffPos = versions.findIndexOf{(it.major >= cutoff.major) && (it.minor >= cutoff.minor) && (it.revision >= cutoff.revision) && (it.build >= cutoff.build) && (it.rc >= cutoff.rc)}

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

	// Actual job creation
    for (int i = cutoffPos; i < versions.size() ; i++) {

		// Only create for valid build
        if ( (i < lastNoRcPos && versions[i].rc == -1) || (i >= lastNoRcPos)) {
            println ("Preparing job for")
            String kernel = versions[i].print()
            String jobName = "kernel-${kernel}"
            String moduleJobName = "lttng-modules-master-kernel-${kernel}"
            println(jobName)
            println(moduleJobName)

			// Jenkins only dsl
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
						downstream(moduleJobName, 'SUCCESS')
					}
				}
				// Corresponding Module job
				matrixJob("${moduleJobName}") {
					using("modules")
						multiscm {
							git {
								remote {
									name("linux")
										url("${linuxURL}")
								}
								branch(versions[i].gitRefs)
									shallowClone(true)
									relativeTargetDir(linuxCheckoutTo)
									reference(linuxGitReference)
							}
							git {
								remote {
									name("lttng-modules")
										url(modulesURL)
								}
								branch("master")
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
