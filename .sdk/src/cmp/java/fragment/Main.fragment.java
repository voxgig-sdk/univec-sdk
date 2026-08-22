package JAVAPACKAGE.core;

import java.util.Map;

/**
 * ProjectName SDK client. All transport and pipeline behaviour lives in
 * the SdkClient base (core/SdkClient.java); this class binds the
 * API-specific entity accessors and the test-mode constructor.
 */
public class ProjectNameSDK extends SdkClient {

  public ProjectNameSDK() {
    this(null);
  }

  public ProjectNameSDK(Map<String, Object> options) {
    super(options);
  }

  // <[SLOT]>

  // testSDK builds a client in test mode: the test feature is activated,
  // installing the in-memory mock transport (no network activity).
  public static ProjectNameSDK testSDK() {
    return testSDK(null, null);
  }

  public static ProjectNameSDK testSDK(
      Map<String, Object> testopts, Map<String, Object> sdkopts) {
    ProjectNameSDK sdk = new ProjectNameSDK(SdkClient.testOptions(testopts, sdkopts));
    sdk.mode = "test";
    return sdk;
  }
}
