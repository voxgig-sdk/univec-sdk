package voxgig.univecsdk.core

/**
 * Univec SDK client. All transport and pipeline behaviour lives in the
 * SdkClient base (core/SdkClient.kt); this class binds the API-specific
 * entity accessors and the test-mode constructor.
 */
class UnivecSDK(options: MutableMap<String, Any?>?) : SdkClient(options) {

  constructor() : this(null)


  /**
   * Returns a convert entity bound to this client.
   * Idiomatic usage: client.convert(null).list(null, null) or
   * client.convert(null).load(mutableMapOf("id" to ...), null).
   */
  fun convert(entopts: MutableMap<String, Any?>?): SdkEntity {
    return voxgig.univecsdk.entity.ConvertEntity(this, entopts)
  }

  /**
   * Returns a embed entity bound to this client.
   * Idiomatic usage: client.embed(null).list(null, null) or
   * client.embed(null).load(mutableMapOf("id" to ...), null).
   */
  fun embed(entopts: MutableMap<String, Any?>?): SdkEntity {
    return voxgig.univecsdk.entity.EmbedEntity(this, entopts)
  }

  /**
   * Returns a ephemeral_key entity bound to this client.
   * Idiomatic usage: client.ephemeralKey(null).list(null, null) or
   * client.ephemeralKey(null).load(mutableMapOf("id" to ...), null).
   */
  fun ephemeralKey(entopts: MutableMap<String, Any?>?): SdkEntity {
    return voxgig.univecsdk.entity.EphemeralKeyEntity(this, entopts)
  }

  /**
   * Returns a model entity bound to this client.
   * Idiomatic usage: client.model(null).list(null, null) or
   * client.model(null).load(mutableMapOf("id" to ...), null).
   */
  fun model(entopts: MutableMap<String, Any?>?): SdkEntity {
    return voxgig.univecsdk.entity.ModelEntity(this, entopts)
  }


  companion object {
    // testSDK builds a client in test mode: the test feature is activated,
    // installing the in-memory mock transport (no network activity).
    fun testSDK(): UnivecSDK = testSDK(null, null)

    fun testSDK(
      testopts: MutableMap<String, Any?>?,
      sdkopts: MutableMap<String, Any?>?,
    ): UnivecSDK {
      val sdk = UnivecSDK(testOptions(testopts, sdkopts))
      sdk.mode = "test"
      return sdk
    }
  }
}
