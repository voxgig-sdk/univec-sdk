package JAVAPACKAGE.utility;

import java.util.List;
import java.util.Map;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.Spec;
import JAVAPACKAGE.utility.struct.Struct;

final class PrepareAuth {

  private PrepareAuth() {}

  static final String HEADER_AUTH = "authorization";
  static final String OPTION_APIKEY = "apikey";
  static final String NOT_FOUND = "__NOTFOUND__";

  static Spec prepareAuth(Context ctx) {
    Spec spec = ctx.spec;
    if (spec == null) {
      throw ctx.makeError("auth_no_spec",
          "Expected context spec property to be defined.");
    }

    Map<String, Object> headers = spec.headers;
    Map<String, Object> options = ctx.client.optionsMap();

    // Public APIs that need no auth omit the options.auth block entirely.
    if (options.get("auth") == null) {
      headers.remove(HEADER_AUTH);
      return spec;
    }

    Object apikey = Struct.getprop(options, OPTION_APIKEY, NOT_FOUND);

    boolean skip = false;
    if (apikey == null) {
      skip = true;
    }
    else if (apikey instanceof String
        && (NOT_FOUND.equals(apikey) || "".equals(apikey))) {
      skip = true;
    }

    if (skip) {
      headers.remove(HEADER_AUTH);
    }
    else {
      String authPrefix = "";
      Object ap = Struct.getpath(options, List.of("auth", "prefix"));
      if (ap instanceof String) {
        authPrefix = (String) ap;
      }
      String apikeyVal = apikey instanceof String ? (String) apikey : "";
      // Empty prefix (raw apiKey credential) must not add a leading space.
      if ("".equals(authPrefix)) {
        headers.put(HEADER_AUTH, apikeyVal);
      }
      else {
        headers.put(HEADER_AUTH, authPrefix + " " + apikeyVal);
      }
    }

    return spec;
  }
}
