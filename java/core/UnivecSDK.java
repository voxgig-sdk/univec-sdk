package voxgig.univecsdk.core;

import java.util.Map;

/**
 * Univec SDK client. All transport and pipeline behaviour lives in
 * the SdkClient base (core/SdkClient.java); this class binds the
 * API-specific entity accessors and the test-mode constructor.
 */
public class UnivecSDK extends SdkClient {

  public UnivecSDK() {
    this(null);
  }

  public UnivecSDK(Map<String, Object> options) {
    super(options);
  }


  /**
   * Returns a convert entity bound to this client.
   * Idiomatic usage: client.convert(null).list(null, null) or
   * client.convert(null).load(Map.of("id", ...), null).
   */
  public SdkEntity convert(Map<String, Object> entopts) {
    return new voxgig.univecsdk.entity.ConvertEntity(this, entopts);
  }

  /**
   * Returns a embed entity bound to this client.
   * Idiomatic usage: client.embed(null).list(null, null) or
   * client.embed(null).load(Map.of("id", ...), null).
   */
  public SdkEntity embed(Map<String, Object> entopts) {
    return new voxgig.univecsdk.entity.EmbedEntity(this, entopts);
  }

  /**
   * Returns a ephemeral_key entity bound to this client.
   * Idiomatic usage: client.ephemeralKey(null).list(null, null) or
   * client.ephemeralKey(null).load(Map.of("id", ...), null).
   */
  public SdkEntity ephemeralKey(Map<String, Object> entopts) {
    return new voxgig.univecsdk.entity.EphemeralKeyEntity(this, entopts);
  }

  /**
   * Returns a model entity bound to this client.
   * Idiomatic usage: client.model(null).list(null, null) or
   * client.model(null).load(Map.of("id", ...), null).
   */
  public SdkEntity model(Map<String, Object> entopts) {
    return new voxgig.univecsdk.entity.ModelEntity(this, entopts);
  }


  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  public static UnivecSDK testSDK() {
    return testSDK(null, null);
  }

  public static UnivecSDK testSDK(
      Map<String, Object> testopts, Map<String, Object> sdkopts) {
    UnivecSDK sdk = new UnivecSDK(SdkClient.testOptions(testopts, sdkopts));
    sdk.mode = "test";
    return sdk;
  }
}
