/**
 * Copyright (C) 2016-2020 Michael Jeanson <mjeanson@efficios.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import hudson.model.*
import hudson.AbortException
import hudson.console.HyperlinkNote
import java.util.concurrent.CancellationException
import org.eclipse.jgit.api.Git
import org.eclipse.jgit.lib.Ref


class InvalidKVersionException extends Exception {
  public InvalidKVersionException(String message) {
    super(message)
  }
}

class EmptyKVersionException extends Exception {
  public EmptyKVersionException(String message) {
    super(message)
  }
}

class VanillaKVersion implements Comparable<VanillaKVersion> {

  Integer major = 0
  Integer majorB = 0
  Integer minor = 0
  Integer patch = 0
  Integer rc = Integer.MAX_VALUE

  VanillaKVersion() {}

  VanillaKVersion(version) {
    this.parse(version)
  }

  static VanillaKVersion minKVersion() {
    return new VanillaKVersion("v0.0.0")
  }

  static VanillaKVersion maxKVersion() {
    return new VanillaKVersion("v" + Integer.MAX_VALUE + ".0.0")
  }

  static VanillaKVersion factory(version) {
    return new VanillaKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.majorB = 0
    this.minor = 0
    this.patch = 0
    this.rc = Integer.MAX_VALUE

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    def match = version =~ /^v(\d+)\.(\d+)(\.(\d+))?(\.(\d+))?(-rc(\d+))?$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    Integer offset = 0;

    // Major
    this.major = Integer.parseInt(match.group(1))
    if (this.major <= 2) {
      offset = 2
      this.majorB = Integer.parseInt(match.group(2))
    }

    // Minor
    if (match.group(2 + offset) != null) {
      this.minor = Integer.parseInt(match.group(2 + offset))
    }

    // Patch level
    if (match.group(4 + offset) != null) {
      this.patch = Integer.parseInt(match.group(4 + offset))
    }

    // RC
    if (match.group(8) != null) {
      this.rc = Integer.parseInt(match.group(8))
    }
  }

  // Return true if this version is a release candidate
  Boolean isRC() {
    return this.rc != Integer.MAX_VALUE
  }

  // Return true if both version are of the same stable branch
  Boolean isSameStable(VanillaKVersion o) {
    if (this.major != o.major) {
      return false
    }
    if (this.majorB != o.majorB) {
      return false
    }
    if (this.minor != o.minor) {
      return false
    }

    return true
  }

  @Override int compareTo(VanillaKVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major)
    }
    if (this.majorB != o.majorB) {
      return Integer.compare(this.majorB, o.majorB)
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor)
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch)
    }
    if (this.rc != o.rc) {
      return Integer.compare(this.rc, o.rc)
    }

    // Same version
    return 0;
  }

  String toString() {
    String vString = "v${this.major}"

    if (this.majorB > 0) {
      vString = vString.concat(".${this.majorB}")
    }

    vString = vString.concat(".${this.minor}")

    if (this.patch > 0) {
      vString = vString.concat(".${this.patch}")
    }

    if (this.rc > 0 && this.rc < Integer.MAX_VALUE) {
      vString = vString.concat("-rc${this.rc}")
    }
    return vString
  }
}

class ElKVersion implements Comparable<ElKVersion> {
  Integer major = 0
  Integer minor = 0
  Integer patch = 0
  Integer elmajor = 0
  Integer elminor = 0
  Integer elpatch = 0
  Integer el_release_major = 0
  Integer el_release_minor = 0
  Boolean append_zero_el_release_minor = false
  String version_prefix = ""

  ElKVersion() {}

  ElKVersion(version) {
    this.parse(version)
  }

  static ElKVersion minKVersion() {
    return new ElKVersion("kernel-0.0.0-0.0.0.el0_0")
  }

  static ElKVersion maxKVersion() {
    return new ElKVersion("kernel-" + Integer.MAX_VALUE + ".0.0-0.0.0.el0_0")
  }

  static ElKVersion factory(version) {
    return new ElKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.minor = 0
    this.patch = 0
    this.elmajor = 0
    this.elminor = 0
    this.elpatch = 0
    this.el_release_major = 0
    this.el_release_minor = 0
    this.append_zero_el_release_minor = false
    this.version_prefix = ""

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    // Eg. imports/r8/kernel-4.18.0-513.18.1.el8_9
    // Eg. imports/r9/kernel-5.14.0-362.13.1.el9_3
    // Eg. imports/r8s/kernel-4.18.0-528.el8
    // Eg. imports/r8/kernel-4.18.0-80.1.2.el8_0
    // Eg. imports/r8/kernel-4.18.0-348.el8
    def match = version =~ /^([\w\d\/]*kernel-)??(\d+)\.(\d+)\.(\d+)-(\d+)(\.(\d+))??(\.(\d+))??\.el(\d+)(_(\d+))??$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    if (match.group(1)) {
      this.version_prefix = match.group(1)
    }
    this.major = Integer.parseInt(match.group(2))
    this.minor = Integer.parseInt(match.group(3))
    this.patch = Integer.parseInt(match.group(4))
    this.elmajor = Integer.parseInt(match.group(5))
    if (match.group(7)) {
      this.elminor = Integer.parseInt(match.group(7))
    }
    if (match.group(9)) {
      this.elpatch = Integer.parseInt(match.group(9))
    }
    if (match.group(10)) {
      this.el_release_major = Integer.parseInt(match.group(10))
    }
    if (match.group(12)) {
      this.el_release_minor = Integer.parseInt(match.group(12))
      this.append_zero_el_release_minor = true
    }
  }

  Boolean isRC() {
    return false
  }

  Boolean isSameStable(ElKVersion o) {
    def properties = ['major', 'minor', 'patch', 'elmajor', 'elminor', 'elpatch', 'el_release_major', 'el_release_minor']
    for (property in properties) {
      if (this."$property" != o."$property") {
        return false
      }
    }
    return true
  }

  @Override int compareTo(ElKVersion o) {
    def properties = ['major', 'minor', 'patch', 'elmajor', 'elminor', 'elpatch', 'el_release_major', 'el_release_minor']
    for (property in properties) {
      if (this."$property" != o."$property") {
        return Integer.compare(this."$property", o."$property")
      }
    }
    return 0
  }

  String toString() {
    String vString = "${this.version_prefix}${this.major}.${this.minor}.${this.patch}-${this.elmajor}"
    // Sometimes a tag can have no elminor, eg. imports/r8/kernel-4.18.0-80.el8
    if (this.elminor != 0) {
      vString = vString.concat(".${this.elminor}")
    }
    if (this.elpatch != 0) {
      vString = vString.concat(".${this.elpatch}")
    }
    vString = vString.concat(".el${this.el_release_major}")
    // Some tags have a trailing el_release_minor that is 0, eg.
    // imports/r8/kernel-4.18.0-80.1.2.el8
    if (this.el_release_minor != 0 || (this.el_release_minor == 0 && this.append_zero_el_release_minor)) {
      vString = vString.concat("_${this.el_release_minor}")
    }
    return vString
  }
}

class SlesKVersion implements Comparable<SlesKVersion> {
  Integer major = 0
  Integer minor = 0
  Integer patch = 0
  Integer slesrelease = 0
  Integer slesmajor = 0
  Integer slesminor = 0

  SlesKVersion() {}

  SlesKVersion(version) {
    this.parse(version)
  }

  static SlesKVersion minKVersion() {
    return new SlesKVersion("rpm-0.0.0-0.0.0")
  }

  static SlesKVersion maxKVersion() {
    return new SlesKVersion("rpm-" + Integer.MAX_VALUE + ".0.0-0.0.0")
  }

  static SlesKVersion factory(version) {
    return new SlesKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.minor = 0
    this.patch = 0
    this.slesrelease = 0
    this.slesmajor = 0
    this.slesminor = 0

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    // Eg. 5.14.21-150400.22
    // Eg. 5.14.21-150400.24.100.2
    // From tag: rpm-5.14.21-150400.24.100 -> 5.14.21-150400.24.100
    def match = version =~ /^(rpm-)??(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)(\.\d+)??$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    this.major = Integer.parseInt(match.group(2))
    this.minor = Integer.parseInt(match.group(3))
    this.patch = Integer.parseInt(match.group(4))
    this.slesrelease = Integer.parseInt(match.group(5))
    this.slesmajor = Integer.parseInt(match.group(6))

    if (match.group(7) != null) {
      this.slesminor = Integer.parseInt(match.group(7).drop(1))
    }
  }

  Boolean isRC() {
    return false
  }

  Boolean isSameStable(SlesKVersion o) {
    if (this.major != o.major) {
      return false
    }
    if (this.minor != o.minor) {
      return false
    }
    if (this.patch != o.patch) {
      return false
    }
    if (this.slesrelease != o.slesrelease) {
      return false
    }
    if (this.slesmajor != o.slesmajor) {
      return false
    }
    if (this.slesminor != o.slesminor) {
      return false
    }
    return true
  }

  @Override int compareTo(SlesKVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major)
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor)
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch)
    }
    if (this.slesrelease != o.slesrelease) {
      return Integer.compare(this.slesrelease, o.slesrelease)
    }
    if (this.slesmajor != o.slesmajor) {
      return Integer.compare(this.slesmajor, o.slesmajor)
    }
    if (this.slesminor != o.slesminor) {
      return Integer.compare(this.slesminor, o.slesminor)
    }
    return 0
  }

  String toString() {
    String vString = "rpm-${this.major}.${this.minor}.${patch}-${this.slesrelease}.${this.slesmajor}"
    if (this.slesminor != 0) {
      vString = vString.concat(".${this.slesminor}")
    }
    return vString
  }
}

class UbuntuKVersion implements Comparable<UbuntuKVersion> {

  Integer major = 0
  Integer minor = 0
  Integer patch = 0
  Integer umajor = 0
  Integer uminor = 0
  String suffix = ""
  String strLTS = ""
  Boolean isLTS = false

  UbuntuKVersion() {}

  UbuntuKVersion(version) {
    this.parse(version)
  }

  static UbuntuKVersion minKVersion() {
    return new UbuntuKVersion("Ubuntu-lts-0.0.0-0.0")
  }

  static UbuntuKVersion maxKVersion() {
    return new UbuntuKVersion("Ubuntu-" + Integer.MAX_VALUE + ".0.0-0.0")
  }

  static UbuntuKVersion factory(version) {
    return new UbuntuKVersion(version)
  }

  def parse(version) {
    this.major = 0
    this.minor = 0
    this.patch = 0
    this.umajor = 0
    this.uminor = 0
    this.suffix = "";
    this.isLTS = false

    if (!version) {
      throw new EmptyKVersionException("Empty kernel version")
    }

    //'Ubuntu-hwe-5.8-5.8.0-19.20_20.04.3',
    //'Ubuntu-lts-4.8.0-27.29_16.04.1',
    //'Ubuntu-4.4.0-70.91',
    def match = version =~ /^Ubuntu-(lts-|hwe-)??(?:\d+\.\d+-)??(\d+)\.(\d+)\.(\d+)-(\d+)\.(\d+)(.*)??$/
    if (!match) {
      throw new InvalidKVersionException("Invalid kernel version: ${version}")
    }

    if (match.group(1) != null) {
        this.isLTS = true
        this.strLTS = match.group(1)
    }

    // Major
    this.major = Integer.parseInt(match.group(2))

    // Minor
    this.minor = Integer.parseInt(match.group(3))

    // Patch level
    this.patch = Integer.parseInt(match.group(4))

    // Ubuntu major
    this.umajor = Integer.parseInt(match.group(5))

    // Ubuntu minor
    this.uminor = Integer.parseInt(match.group(6))

    if (match.group(7) != null) {
      this.suffix = match.group(7)
    }
  }

  // Return true if this version is a release candidate
  Boolean isRC() {
    return false
  }

  // Return true if both version are of the same stable branch
  Boolean isSameStable(UbuntuKVersion o) {
    if (this.isLTS != o.isLTS) {
      return false
    }
    if (this.major != o.major) {
      return false
    }
    if (this.minor != o.minor) {
      return false
    }
    if (this.patch != o.patch) {
      return false
    }

    return true
  }

  @Override int compareTo(UbuntuKVersion o) {
    if (this.major != o.major) {
      return Integer.compare(this.major, o.major)
    }
    if (this.minor != o.minor) {
      return Integer.compare(this.minor, o.minor)
    }
    if (this.patch != o.patch) {
      return Integer.compare(this.patch, o.patch)
    }
    if (this.umajor != o.umajor) {
      return Integer.compare(this.umajor, o.umajor)
    }
    if (this.uminor != o.uminor) {
      return Integer.compare(this.uminor, o.uminor)
    }
    if (this.isLTS != o.isLTS) {
      if (o.isLTS) {
        return 1
      } else {
        return -1
      }
    }

    // Same version
    return 0;
  }

  String toString() {
    String vString = "Ubuntu-"

    if (this.isLTS) {
      vString = vString.concat("${this.strLTS}")
    }

    // The tag pattern changed for HWE kernels >= 5.0
    if (this.isLTS && this.major >= 5) {
      vString = vString.concat("${this.major}.${this.minor}-${this.major}.${this.minor}.${this.patch}-${this.umajor}.${this.uminor}${this.suffix}")
    } else {
      vString = vString.concat("${this.major}.${this.minor}.${this.patch}-${this.umajor}.${this.uminor}${this.suffix}")
    }

    return vString
  }
}


// Retrieve parameters of the current build
def mbranch = build.getEnvironment(listener).get('GIT_BRANCH').minus('origin/')
def maxConcurrentBuild = build.buildVariableResolver.resolve('maxConcurrentBuild')
def kconfig_profile = build.buildVariableResolver.resolve('kconfig_profile')
def kgitrepo = build.buildVariableResolver.resolve('kgitrepo')
def kverfloor_raw = build.buildVariableResolver.resolve('kverfloor')
def kverceil_raw = build.buildVariableResolver.resolve('kverceil')
def kverfilter = build.buildVariableResolver.resolve('kverfilter')
def kverrc = build.buildVariableResolver.resolve('kverrc')
def elversion = build.buildVariableResolver.resolve('elversion')
def slesversion = build.buildVariableResolver.resolve('slesversion')
def uversion = build.buildVariableResolver.resolve('uversion')
def job = Hudson.instance.getJob(build.buildVariableResolver.resolve('kbuildjob'))
def currentJobName = build.project.getFullDisplayName()
def gitmodpath = build.getEnvironment(listener).get('WORKSPACE') + "/src/lttng-modules"

// Get the out variable
def config = new HashMap()
def bindings = getBinding()
config.putAll(bindings.getVariables())
def out = config['out']


// Get the lttng-modules git url
def gitmodrepo = Git.open(new File(gitmodpath))
def mgitrepo = gitmodrepo.getRepository().getConfig().getString("remote", "origin", "url")

// Get tags from git repository
def refs = Git.lsRemoteRepository().setTags(true).setRemote(kgitrepo).call()

// Get kernel versions to build
def kversions = []
def kversionsRC = []
def matchStrs = []
def blacklist = []
def kversionFactory = ""
def distroversion = ""

if (elversion != null) {
  distroversion = elversion
  kversionFactory = new ElKVersion()
  switch (elversion) {
    case 'el8':
      matchStrs = [
        // EL 8 (all)
        // ~/^refs\/tags\/(imports\/r8\/kernel-[\d\.-]+.el8.*)$/,
        // EL 8.4
        ~/^refs\/tags\/(imports\/r8\/kernel-4\.18\.0-305\.[\d\.-]+.el8.*)$/,
        // EL 8.6
        ~/^refs\/tags\/(imports\/r8\/kernel-4\.18\.0-372\.[\d\.-]+.el8.*)$/,
      ]
      blacklist = []
      break
    default:
      println ("Unsupport EL version: ${elversion}")
      throw new InterruptedException()
      break
  }
} else if (slesversion != null) {
  distroversion = slesversion
  kversionFactory = new SlesKVersion()
  switch (slesversion) {
    case 'sles15sp4':
      matchStrs = [
        ~/^refs\/tags\/(rpm-5.14.21-150400\.22(\.\d+)?(\.\d+)?)$/,
        ~/^refs\/tags\/(rpm-5.14.21-150400\.24(\.\d+)?(\.\d+)?)$/,
      ]
      blacklist = [
        // "Retracted", @see https://www.suse.com/support/kb/doc/?id=000019587#SLE15SP4
        'rpm-5.14.21-150400.24.49',
        'rpm-5.14.21-150400.24.84',
      ]
      break

    case 'sles15sp5':
      matchStrs = [
        ~/^refs\/tags\/(rpm-5.14.21-150500\.53(\.\d+)?(\.\d+)?)--SLE-15-SP5-Full-GM$/,
        ~/^refs\/tags\/(rpm-5.14.21-150500\.55(\.\d+)?(\.\d+)?)--sle15-sp5-updates$/,
      ]
      blacklist = [
        // @see https://www.suse.com/support/kb/doc/?id=000019587#SLE15SP5
        'rpm-5.14.21-150500.55.22.1',
      ]
      break

    default:
      println "Unsupported SLES version: ${slesversion}"
      throw new InterruptedException()
      break
  }
} else if (uversion != null) {
  distroversion = uversion
  kversionFactory = new UbuntuKVersion()
  switch (uversion) {
    case 'jammy':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-5\.15\.0-\d{1,3}?\.[\d]+)$/,
        ~/^refs\/tags\/(Ubuntu-hwe-6\.8-6\.8\.0-.*_22\.04\.\d+)$/,
      ]
      break

    case 'focal':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-5\.4\.0-\d{1,3}?\.[\d]+)$/,
        ~/^refs\/tags\/(Ubuntu-hwe-5\.15-5\.15\.0-.*_20\.04\.\d+)$/,
        ~/^refs\/tags\/(Ubuntu-hwe-6\.8-6\.8\.0-.*_20\.04\.\d+)$/,
      ]
      break

    case 'noble':
      matchStrs = [
        ~/^refs\/tags\/(Ubuntu-6\.8\.0-\d{1,3}?\.[\d]+)$/,
      ]
      break

    default:
      println "Unsupported Ubuntu version: ${uversion}"
      throw new InterruptedException()
      break
  }
} else {
  // Vanilla
  kversionFactory = new VanillaKVersion()
  matchStrs = [
    ~/^refs\/tags\/(v[\d\.]+(-rc(\d+))?)$/,
  ]
  blacklist = [
    'v3.2.3',
  ]
}

// Parse kernel versions
def kverfloor = ""
try {
    kverfloor = kversionFactory.factory(kverfloor_raw)
} catch (EmptyKVersionException e) {
    kverfloor = kversionFactory.minKVersion()
}

def kverceil = ""
try {
    kverceil = kversionFactory.factory(kverceil_raw)
} catch (EmptyKVersionException e) {
    kverceil = kversionFactory.maxKVersion()
}

// Build a sorted list of versions to build
for (ref in refs) {
  for (matchStr in matchStrs) {
    def match = ref.getName() =~ matchStr
    if (match && !blacklist.contains(match.group(1))) {
      def v = kversionFactory.factory(match.group(1))

      if ((v >= kverfloor) && (v < kverceil)) {
        if (v.isRC()) {
          kversionsRC.add(v)
        } else {
          kversions.add(v)
        }
      }
    }
  }
}

// The filtering step assumes the version lists are sorted
kversions.sort()
kversionsRC.sort()

switch (kverfilter) {
  case 'stable-head':
    // Keep only the head of each stable branch
    println('Filter kernel versions to keep only the latest point release of each stable branch.')

    for (i = 0; i < kversions.size(); i++) {
      def curr = kversions[i]
      def next = i < kversions.size() - 1 ? kversions[i + 1] : null

      if (next != null) {
        if (curr.isSameStable(next)) {
          kversions.remove(i)
          i--
        }
      }
    }
    break

  case 'lts-head':
    // Keep only the head of each LTS branch and the latest non-RC tag
    println('Filter kernel versions to keep only the latest point release of each lts branch and the current stable.')

    def lts_kversions = []
    // Old LTS entries are kept so that "lts-head" is still meaningful in kernel
    // version ranges that are supported by lttng-modules but no longer supported
    // upstream, eg. lttng-modules stable-2.13 supports >= 3.0
    lts_kversions.add(kversionFactory.factory("v3.0"))  // LTS until October 2013
    lts_kversions.add(kversionFactory.factory("v3.2"))  // LTS until May 2018
    lts_kversions.add(kversionFactory.factory("v3.4"))  // LTS until October 2016
    lts_kversions.add(kversionFactory.factory("v3.10")) // LTS until November 2017
    lts_kversions.add(kversionFactory.factory("v3.12")) // LTS until May 2017
    lts_kversions.add(kversionFactory.factory("v3.14")) // LTS until August 2016
    lts_kversions.add(kversionFactory.factory("v3.16")) // LTS until October 2014
    lts_kversions.add(kversionFactory.factory("v3.18")) // LTS until January 2017
    lts_kversions.add(kversionFactory.factory("v4.1"))  // LTS until May 2018
    lts_kversions.add(kversionFactory.factory("v4.4"))  // SLTS until 2026
    lts_kversions.add(kversionFactory.factory("v4.9"))  // LTS until January 2023
    lts_kversions.add(kversionFactory.factory("v4.14")) // LTS until January 2024
    lts_kversions.add(kversionFactory.factory("v4.19")) // LTS until December 2024
    lts_kversions.add(kversionFactory.factory("v5.4"))  // LTS until December 2025
    lts_kversions.add(kversionFactory.factory("v5.10")) // LTS until December 2026
    lts_kversions.add(kversionFactory.factory("v5.15")) // LTS until December 2026
    lts_kversions.add(kversionFactory.factory("v6.1"))  // LTS until December 2026
    lts_kversions.add(kversionFactory.factory("v6.6"))  // LTS until December 2026

    // First filter the head of each branch
    for (i = 0; i < kversions.size(); i++) {
      def curr = kversions[i]
      def next = i < kversions.size() - 1 ? kversions[i + 1] : null

      if (next != null) {
        if (curr.isSameStable(next)) {
          kversions.remove(i)
          i--
        }
      }
    }

    for (i = 0; i < kversions.size(); i++) {
      def curr = kversions[i]

      // Keep the newest tag
      if (i == kversions.size() - 1) {
        break
      }

      // Prune non-LTS versions
      def keep = false
      for (j = 0; j < lts_kversions.size(); j++) {
        if (curr.isSameStable(lts_kversions[j])) {
          keep = true
          break
        }
      }

      if (!keep) {
        kversions.remove(i)
        i--
      }
    }
    break

  default:
    // No filtering of kernel versions
    println('No kernel versions filtering selected.')
    break
}

if (kverrc == "true") {
  // If the last RC version is newer than the last stable, add it to the build list
  if (kversionsRC.size() > 0 && kversionsRC.last() > kversions.last()) {
    kversions.add(kversionsRC.last())
  }
}

println "Building the following kernel versions:"
for (k in kversions) {
  println k
}

// Debug: Stop build here
//throw new InterruptedException()

def joburl = HyperlinkNote.encodeTo('/' + job.url, job.fullDisplayName)

def allBuilds = []
def ongoingBuild = []
def failedRuns = []
def isFailed = false
def similarJobQueued = 0;

// Loop while we have kernel versions remaining or jobs running
while ( kversions.size() != 0 || ongoingBuild.size() != 0 ) {

  if(ongoingBuild.size() < maxConcurrentBuild.toInteger() && kversions.size() != 0) {
    def kversion = kversions.pop()
    def job_params = [
      new StringParameterValue('mversion', mbranch),
      new StringParameterValue('mgitrepo', mgitrepo),
      new StringParameterValue('ktag', kversion.toString()),
      new StringParameterValue('kgitrepo', kgitrepo),
      new StringParameterValue('kconfig_profile', kconfig_profile),
      new StringParameterValue('distroversion', distroversion),
      new StringParameterValue('getsrc_repo', build.buildVariableResolver.resolve('getsrc_repo')),
      new StringParameterValue('getsrc_version', build.buildVariableResolver.resolve('getsrc_version'))
    ]

    // Launch the parametrized build
    def param_build = job.scheduleBuild2(0, new Cause.UpstreamCause(build), new ParametersAction(job_params))
    println "triggering ${joburl} for the ${mbranch} branch on kernel ${kversion}"

    // Add it to the ongoing build queue
    ongoingBuild.push(param_build)

  } else {

    println "Waiting... Queued: " + kversions.size() + " Running: " + ongoingBuild.size()
    try {
      Thread.sleep(10000)
    } catch(e) {
      if (e in InterruptedException) {
        build.setResult(hudson.model.Result.ABORTED)
        throw new InterruptedException()
      } else {
        throw(e)
      }
    }

    // Abort job if a newer instance is queued
    if (!currentJobName.contains("gerrit")) {
      similarJobQueued = Hudson.instance.queue.items.count{it.task.getFullDisplayName() == currentJobName}
      if (similarJobQueued > 0) {
        println "Abort, a newer instance of the job was queued"
        build.setResult(hudson.model.Result.ABORTED)
        throw new InterruptedException()
      }
    }

    def i = ongoingBuild.iterator()
    while ( i.hasNext() ) {
      currentBuild = i.next()
      if ( currentBuild.isCancelled() || currentBuild.isDone() ) {
        // Remove from queue
        i.remove()

        // Print results
        def matrixParent = currentBuild.get()
        allBuilds.add(matrixParent)
        def kernelStr = matrixParent.buildVariableResolver.resolve("ktag")
        println "${matrixParent.fullDisplayName} (${kernelStr}) completed with status ${matrixParent.result}"

        // Process child runs of matrixBuild
        def childRuns = matrixParent.getRuns()
        for ( childRun in childRuns ) {
          println "\t${childRun.fullDisplayName} (${kernelStr}) completed with status ${childRun.result}"
          if (childRun.result != Result.SUCCESS) {
            failedRuns.add(childRun)
            isFailed = true
          }
        }
      }
    }
  }
}

// Get log of failed runs
for (failedRun in failedRuns) {
  println "---START---"
  failedRun.writeWholeLogTo(out)
  println "---END---"
}

println "---Build report---"
for (b in allBuilds) {
  def kernelStr = b.buildVariableResolver.resolve("ktag")
  println "${b.fullDisplayName} (${kernelStr}) completed with status ${b.result}"
  // Cleanup builds
  try {
    b.delete()
  } catch (all) {}
}

// Mark this build failed if any child build has failed
if (isFailed) {
  build.setResult(hudson.model.Result.FAILURE)
}

// EOF
