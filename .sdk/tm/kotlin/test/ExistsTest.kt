package KOTLINPACKAGE.sdktest

import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.UnivecSDK

class ExistsTest {

  @Test
  fun testMode() {
    val testsdk = UnivecSDK.testSDK()
    assertNotNull(testsdk, "expected non-nil SDK")
  }
}
