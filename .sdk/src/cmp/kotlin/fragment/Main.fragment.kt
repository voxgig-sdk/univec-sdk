package KOTLINPACKAGE.core

/**
 * ProjectName SDK client. All transport and pipeline behaviour lives in the
 * SdkClient base (core/SdkClient.kt); this class binds the API-specific
 * entity accessors and the test-mode constructor.
 */
class ProjectNameSDK(options: MutableMap<String, Any?>?) : SdkClient(options) {

  constructor() : this(null)

  // <[SLOT]>

  companion object {
    // testSDK builds a client in test mode: the test feature is activated,
    // installing the in-memory mock transport (no network activity).
    fun testSDK(): ProjectNameSDK = testSDK(null, null)

    fun testSDK(
      testopts: MutableMap<String, Any?>?,
      sdkopts: MutableMap<String, Any?>?,
    ): ProjectNameSDK {
      val sdk = ProjectNameSDK(testOptions(testopts, sdkopts))
      sdk.mode = "test"
      return sdk
    }
  }
}
