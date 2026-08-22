package voxgig.univecsdk.core

import java.util.{Map => JMap}

// Univec SDK client. All transport and pipeline behaviour lives in the
// SdkClient base (core/SdkClient.scala); this class binds the API-specific
// entity accessors and the test-mode constructor.
class UnivecSDK(options: JMap[String, Object]) extends SdkClient(options) {

  def this() = this(null)


  /**
   * Returns a convert entity bound to this client.
   * Idiomatic usage: client.convert(null).list(null, null) or
   * client.convert(null).load(java.util.Map.of("id", ...), null).
   */
  def convert(entopts: java.util.Map[String, Object]): SdkEntity =
    new voxgig.univecsdk.entity.ConvertEntity(this, entopts)

  /**
   * Returns a embed entity bound to this client.
   * Idiomatic usage: client.embed(null).list(null, null) or
   * client.embed(null).load(java.util.Map.of("id", ...), null).
   */
  def embed(entopts: java.util.Map[String, Object]): SdkEntity =
    new voxgig.univecsdk.entity.EmbedEntity(this, entopts)

  /**
   * Returns a ephemeral_key entity bound to this client.
   * Idiomatic usage: client.ephemeralKey(null).list(null, null) or
   * client.ephemeralKey(null).load(java.util.Map.of("id", ...), null).
   */
  def ephemeralKey(entopts: java.util.Map[String, Object]): SdkEntity =
    new voxgig.univecsdk.entity.EphemeralKeyEntity(this, entopts)

  /**
   * Returns a model entity bound to this client.
   * Idiomatic usage: client.model(null).list(null, null) or
   * client.model(null).load(java.util.Map.of("id", ...), null).
   */
  def model(entopts: java.util.Map[String, Object]): SdkEntity =
    new voxgig.univecsdk.entity.ModelEntity(this, entopts)


}

object UnivecSDK {

  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  def testSDK(): UnivecSDK = testSDK(null, null)

  def testSDK(testopts: JMap[String, Object], sdkopts: JMap[String, Object]): UnivecSDK = {
    val sdk = new UnivecSDK(SdkClient.testOptions(testopts, sdkopts))
    sdk.mode = "test"
    sdk
  }
}
