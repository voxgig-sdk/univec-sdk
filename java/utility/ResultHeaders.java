package voxgig.univecsdk.utility;

import java.util.LinkedHashMap;
import java.util.Map;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Helpers;
import voxgig.univecsdk.core.Response;
import voxgig.univecsdk.core.Result;

final class ResultHeaders {

  private ResultHeaders() {}

  static Result resultHeaders(Context ctx) {
    Response response = ctx.response;
    Result result = ctx.result;

    if (result != null) {
      if (response != null && response.headers != null) {
        Map<String, Object> hm = Helpers.toMapAny(response.headers);
        if (hm != null) {
          result.headers = hm;
        }
        else {
          result.headers = new LinkedHashMap<>();
        }
      }
      else {
        result.headers = new LinkedHashMap<>();
      }
    }

    return result;
  }
}
