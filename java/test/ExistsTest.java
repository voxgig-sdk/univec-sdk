package voxgig.univecsdk.sdktest;

import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Test;

import voxgig.univecsdk.core.UnivecSDK;

public class ExistsTest {

  @Test
  public void testMode() {
    UnivecSDK testsdk = UnivecSDK.testSDK();
    assertNotNull(testsdk, "expected non-nil SDK");
  }
}
