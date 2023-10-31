#!groovy

def OS = '{{OS}}'
def RELEASES = {{RELEASES}}
def ARCHES = {{ARCHES}}
def IMAGE_TYPES = {{IMAGE_TYPES}}
def PROFILES = {{PROFILES}}
def c = [RELEASES,
         ARCHES,
         IMAGE_TYPES].combinations()
c.removeAll({
    (params.ARCH_FILTER != 'all' && it[1] != params.ARCH_FILTER) ||
        (params.IMAGE_TYPE_FILTER != 'all' && it[2] != params.IMAGE_TYPE_FILTER) ||
        (params.RELEASE_FILTER != 'all' && it[0] != params.RELEASE_FILTER)
})

// Skip i386 Vms
c.removeAll({
    it[1] == 'i386' && it[2] == 'vm'
})

def base_image_tasks = [:]
def profile_image_tasks = [:]
for(int index = 0; index < c.size(); index++) {
    def envMap = [
        RELEASE: c[index][0],
        ARCH: c[index][1],
        IMAGE_TYPE: c[index][2]
    ]
    def image_name = "${OS}/${envMap.RELEASE}/${envMap.ARCH}/${envMap.IMAGE_TYPE}"
    base_image_tasks[image_name] = { ->
        def job_ids = []
        stage("base:${image_name}") {
            print(envMap)
            build(
                job: 'images_distrobuilder',
                parameters: [
                    string(name: 'OS', value: OS),
                    string(name: 'RELEASE', value: envMap.RELEASE),
                    string(name: 'ARCH', value: envMap.ARCH),
                    string(name: 'IMAGE_TYPE', value: envMap.IMAGE_TYPE),
                    string(name: 'GIT_URL', value: params.GIT_URL),
                    string(name: 'GIT_BRANCH', value: params.GIT_BRANCH)
                ]
            )
        }
    }
    for (int profile_index = 0; profile_index < PROFILES.size(); profile_index++) {
        // Using a second map gets around some weirdness with the closures finding
        // PROFILES[profile_index] where most jobs would have a null value for the
        // profile
        def envMap2 = envMap.clone()
        envMap2.PROFILE = PROFILES[profile_index]
        if (env.PROFILE_FILTER == 'all' || env.PROFILE_FILTER == PROFILES[profile_index]) {
            profile_image_tasks["${PROFILES[profile_index]}:${image_name}"] = { ->
                print(envMap2)
                build(
                    job: 'images_imagebuilder',
                    parameters: [
                        string(name: 'OS', value: OS),
                        string(name: 'RELEASE', value: envMap2.RELEASE),
                        string(name: 'ARCH', value: envMap2.ARCH),
                        string(name: 'IMAGE_TYPE', value: envMap2.IMAGE_TYPE),
                        string(name: 'PROFILE', value:  envMap2.PROFILE),
                        string(name: 'GIT_URL', value: params.GIT_URL),
                        string(name: 'GIT_BRANCH', value: params.GIT_BRANCH)
                    ]
                )
            }
        }
    }
}

if (!params.SKIP_BASE_IMAGES) {
    stage("base images") {
        parallel(base_image_tasks)
    }
}

if (!params.SKIP_PROFILE_IMAGES) {
    // While it's possible to have the tasks in "base images" start
    // their respective profile images_imagebuilder steps, it ends
    // up creating a pipeline overview and log that is difficult to
    // read in the Jenkins interface.
    stage("profile images") {
        parallel(profile_image_tasks)
    }
}
