package SCALAPACKAGE.core

import java.util.{Map => JMap}

// ProjectName SDK client. All transport and pipeline behaviour lives in the
// SdkClient base (core/SdkClient.scala); this class binds the API-specific
// entity accessors and the test-mode constructor.
class ProjectNameSDK(options: JMap[String, Object]) extends SdkClient(options) {

  def this() = this(null)

  // <[SLOT]>

}

object ProjectNameSDK {

  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  def testSDK(): ProjectNameSDK = testSDK(null, null)

  def testSDK(testopts: JMap[String, Object], sdkopts: JMap[String, Object]): ProjectNameSDK = {
    val sdk = new ProjectNameSDK(SdkClient.testOptions(testopts, sdkopts))
    sdk.mode = "test"
    sdk
  }
}
