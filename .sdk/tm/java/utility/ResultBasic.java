package JAVAPACKAGE.utility;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Response;
import JAVAPACKAGE.core.Result;

final class ResultBasic {

  private ResultBasic() {}

  static Result resultBasic(Context ctx) {
    Response response = ctx.response;
    Result result = ctx.result;

    if (result != null && response != null) {
      result.status = response.status;
      result.statusText = response.statusText;

      if (result.status >= 400) {
        String msg = "request: " + result.status + ": " + result.statusText;
        if (result.err != null) {
          String prevmsg = result.err.getMessage();
          result.err = ctx.makeError("request_status", prevmsg + ": " + msg);
        }
        else {
          result.err = ctx.makeError("request_status", msg);
        }
      }
      else if (response.err != null) {
        result.err = response.err;
      }
    }

    return result;
  }
}
