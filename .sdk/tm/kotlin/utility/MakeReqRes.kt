package KOTLINPACKAGE.utility

import KOTLINPACKAGE.core.Context
import KOTLINPACKAGE.core.Response
import KOTLINPACKAGE.core.Result
import KOTLINPACKAGE.utility.struct.Struct

@Suppress("UNCHECKED_CAST")
fun makeRequest(ctx: Context): Response {
  val outRequest = ctx.out["request"]
  if (outRequest is Response) {
    return outRequest
  }

  val utility = ctx.utility!!

  var response = Response(linkedMapOf())
  val result = Result(linkedMapOf())
  ctx.result = result

  val spec = ctx.spec
    ?: throw ctx.makeError("request_no_spec", "Expected context spec property to be defined.")

  val fetchdef: MutableMap<String, Any?>
  try {
    fetchdef = utility.makeFetchDef(ctx)
  } catch (err: RuntimeException) {
    response.err = err
    ctx.response = response
    spec.step = "postrequest"
    return response
  }

  if (ctx.ctrl.explain != null) {
    ctx.ctrl.explain!!["fetchdef"] = fetchdef
  }

  spec.step = "prerequest"

  val url = fetchdef["url"]
  var fetched: Any? = null
  var fetchErr: RuntimeException? = null
  try {
    fetched = utility.fetcher(ctx, if (url is String) url else "", fetchdef)
  } catch (err: RuntimeException) {
    fetchErr = err
  }

  if (fetchErr != null) {
    response.err = fetchErr
  } else if (fetched == null) {
    val resmap = linkedMapOf<String, Any?>()
    resmap["err"] = ctx.makeError("request_no_response", "response: undefined")
    response = Response(resmap)
  } else if (fetched is MutableMap<*, *>) {
    response = Response(fetched as MutableMap<String, Any?>)
  } else {
    response.err = ctx.makeError("request_invalid_response", "response: invalid type")
  }

  spec.step = "postrequest"
  ctx.response = response

  return response
}

fun makeResponse(ctx: Context): Response {
  val outResponse = ctx.out["response"]
  if (outResponse is Response) {
    return outResponse
  }

  val utility = ctx.utility!!
  val spec = ctx.spec
  val result = ctx.result
  val response = ctx.response

  if (spec == null) {
    throw ctx.makeError("response_no_spec", "Expected context spec property to be defined.")
  }
  if (response == null) {
    throw ctx.makeError("response_no_response", "Expected context response property to be defined.")
  }
  if (result == null) {
    throw ctx.makeError("response_no_result", "Expected context result property to be defined.")
  }

  spec.step = "response"

  utility.resultBasic(ctx)
  utility.resultHeaders(ctx)
  utility.resultBody(ctx)

  // GraphQL reports failures as a top-level `errors` array under HTTP 200,
  // so resultBasic's status check never sees them. Lift them here, before
  // the response transform tries to unwrap data that is not there.
  utility.graphqlErrors(ctx)

  utility.transformResponse(ctx)

  if (result.err == null) {
    result.ok = true
  }

  if (ctx.ctrl.explain != null) {
    ctx.ctrl.explain!!["result"] = result
  }

  return response
}

@Suppress("UNCHECKED_CAST")
fun makeResult(ctx: Context): Result {
  val outResult = ctx.out["result"]
  if (outResult is Result) {
    return outResult
  }

  val utility = ctx.utility!!
  val op = ctx.op
  val entity = ctx.entity
  val spec = ctx.spec
  val result = ctx.result

  if (spec == null) {
    throw ctx.makeError("result_no_spec", "Expected context spec property to be defined.")
  }
  if (result == null) {
    throw ctx.makeError("result_no_result", "Expected context result property to be defined.")
  }

  spec.step = "result"

  utility.transformResponse(ctx)

  if ("list" == op.name) {
    val resdata = result.resdata
    result.resdata = mutableListOf<Any?>()

    if (resdata is List<*> && resdata.isNotEmpty() && entity != null) {
      val entities = mutableListOf<Any?>()
      for (entry in resdata) {
        val ent = entity.make()
        if (entry is MutableMap<*, *>) {
          ent.data(entry)
        }
        entities.add(ent)
      }
      result.resdata = entities
    }
  }

  if (ctx.ctrl.explain != null) {
    ctx.ctrl.explain!!["result"] = result
  }

  return result
}
