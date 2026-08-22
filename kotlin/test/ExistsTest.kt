package voxgig.univecsdk.sdktest

import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Test

import voxgig.univecsdk.core.UnivecSDK

class ExistsTest {

  @Test
  fun testMode() {
    val testsdk = UnivecSDK.testSDK()
    assertNotNull(testsdk, "expected non-nil SDK")
  }
}
