package SCALAPACKAGE.utility

import java.util.{LinkedHashMap, Map => JMap}
import SCALAPACKAGE.core._

object ResultBasic {
  def resultBasic(ctx: Context): Result = {
    val response = ctx.response
    val result = ctx.result

    if (result != null && response != null) {
      result.status = response.status
      result.statusText = response.statusText

      if (result.status >= 400) {
        val msg = "request: " + result.status + ": " + result.statusText
        if (result.err != null) {
          val prevmsg = result.err.getMessage
          result.err = ctx.makeError("request_status", prevmsg + ": " + msg)
        } else {
          result.err = ctx.makeError("request_status", msg)
        }
      } else if (response.err != null) {
        result.err = response.err
      }
    }

    result
  }
}

object ResultBody {
  def resultBody(ctx: Context): Result = {
    val response = ctx.response
    val result = ctx.result

    if (result != null) {
      if (response != null && response.jsonFunc != null && response.body != null) {
        result.body = response.jsonFunc.get()
      }
    }

    result
  }
}

object ResultHeaders {
  def resultHeaders(ctx: Context): Result = {
    val response = ctx.response
    val result = ctx.result

    if (result != null) {
      if (response != null && response.headers != null) {
        val hm = Helpers.toMapAny(response.headers)
        result.headers = if (hm != null) hm else new LinkedHashMap[String, Object]()
      } else {
        result.headers = new LinkedHashMap[String, Object]()
      }
    }

    result
  }
}
