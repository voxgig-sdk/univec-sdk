package voxgig.univecsdk.utility;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Response;
import voxgig.univecsdk.core.Result;

final class ResultBody {

  private ResultBody() {}

  static Result resultBody(Context ctx) {
    Response response = ctx.response;
    Result result = ctx.result;

    if (result != null) {
      if (response != null && response.jsonFunc != null && response.body != null) {
        result.body = response.jsonFunc.get();
      }
    }

    return result;
  }
}
