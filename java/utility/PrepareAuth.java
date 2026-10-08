package voxgig.univecsdk.utility;

import java.util.List;
import java.util.Map;

import voxgig.univecsdk.core.Context;
import voxgig.univecsdk.core.Spec;
import voxgig.univecsdk.utility.struct.Struct;

final class PrepareAuth {

  private PrepareAuth() {}

  static final String CRED_NAME = "authorization";
  static final String OPTION_APIKEY = "apikey";
  static final String NOT_FOUND = "__NOTFOUND__";

  // The client's auth.name option, when set, replaces the name the API declares.
  static String authName(Map<String, Object> options) {
    Object name = Struct.getpath(options, List.of("auth", "name"));
    return name instanceof String && !"".equals(name)
        ? ((String) name).toLowerCase(java.util.Locale.ROOT) : CRED_NAME;
  }

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
      headers.remove(CRED_NAME);
      return spec;
    }

    String name = authName(options);

    // A credential left under the declared name would travel beside the renamed one.
    if (!name.equals(CRED_NAME)) {
      headers.remove(CRED_NAME);
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
      headers.remove(name);
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
        headers.put(name, apikeyVal);
      }
      else {
        headers.put(name, authPrefix + " " + apikeyVal);
      }
    }

    return spec;
  }
}
