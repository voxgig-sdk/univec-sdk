package KOTLINPACKAGE.sdktest

// A templated base URL takes each {name} from the `server` option. A missing or
// empty value fails construction; test mode fills in test-<name>.

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assertions.fail
import org.junit.jupiter.api.Test

import KOTLINPACKAGE.core.UnivecSDK
import KOTLINPACKAGE.core.SdkError

class ServerVariableTest {

  // A variable no API declares, so the API's own server defaults cannot fill it.
  private val base = "https://api.example.test/bot{zzvar}"

  private fun build(vararg kv: Pair<String, Any?>): UnivecSDK =
    UnivecSDK(linkedMapOf<String, Any?>("base" to base, *kv))

  @Test
  fun aMissingOrEmptyValueFailsConstruction() {
    for (server in listOf(linkedMapOf<String, Any?>(), linkedMapOf<String, Any?>("zzvar" to ""))) {
      try {
        build("server" to server)
        fail<Unit>("construction should fail without a value for zzvar: $server")
      } catch (e: SdkError) {
        assertEquals("server_var_required", e.code)
        assertTrue(e.message.contains("the server variable 'zzvar' is required"), e.message)
        assertTrue(e.message.contains(base), e.message)
      }
    }
  }

  @Test
  fun aServerValueFillsTheBase() {
    val client = build("server" to linkedMapOf<String, Any?>("zzvar" to "T1"))
    assertEquals("https://api.example.test/botT1", client.optionsMap()["base"])
  }

  @Test
  fun testModeFillsTheBase() {
    val client = build("test" to linkedMapOf<String, Any?>("active" to true))
    assertEquals("https://api.example.test/bottest-zzvar", client.optionsMap()["base"])

    val mock = UnivecSDK.testSDK(null, linkedMapOf<String, Any?>("base" to base))
    assertEquals("https://api.example.test/bottest-zzvar", mock.optionsMap()["base"])
  }
}
