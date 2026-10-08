package JAVAPACKAGE.feature;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Outbound HTTP(S) proxy support. Wraps the active transport and annotates
// each request's fetch definition with the proxy target (`fetchdef.proxy`).
// The default HttpClient transport honours the annotation by routing the
// request through a proxied client (see utility/Fetcher.java); custom
// transports can do the same. The proxy target comes from options (`url`)
// or, when `fromEnv` is set, the standard HTTPS_PROXY / HTTP_PROXY /
// NO_PROXY environment variables. Hosts matching `noProxy` bypass the proxy.
@SuppressWarnings({"unchecked"})
public class ProxyFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private List<String> noProxy = new ArrayList<>();

  // The proxy the transport is told to route through, raw: it may carry
  // credentials as userinfo.
  private String target = "";

  // Activity tracking (mirrors the ts client._proxy record). `url` is the
  // cleaned form of the target, since the record is what a caller prints.
  public int routed = 0;
  public String url = "";

  private static final Pattern HOST_RE =
      Pattern.compile("^[a-z]+://([^/:]+)", Pattern.CASE_INSENSITIVE);

  public ProxyFeature() {
    super("proxy", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    if (!this.active) {
      return;
    }

    this.target = FeatureOptions.foptStr(this.options, "url", "");
    List<String> noProxyRaw = FeatureOptions.foptStrList(this.options, "noProxy");

    if (FeatureOptions.foptBool(this.options, "fromEnv", false)) {
      if ("".equals(this.target)) {
        this.target = firstEnv("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy");
      }
      if (noProxyRaw == null) {
        String np = firstEnv("NO_PROXY", "no_proxy");
        if (!"".equals(np)) {
          noProxyRaw = new ArrayList<>(List.of(np.split(",")));
        }
      }
    }

    this.noProxy = new ArrayList<>();
    if (noProxyRaw != null) {
      for (String np : noProxyRaw) {
        np = np.trim();
        if (!"".equals(np)) {
          this.noProxy.add(np);
        }
      }
    }

    // A proxy URL may carry credentials as userinfo, from the option or the
    // environment, and neither is under a sensitive key name.
    if (!"".equals(this.target) && ctx.utility != null && ctx.utility.cleanAdd != null) {
      try {
        String userinfo = new URI(this.target).getRawUserInfo();
        if (userinfo != null) {
          int colon = userinfo.indexOf(':');
          String[] parts = colon < 0
              ? new String[] {userinfo}
              : new String[] {userinfo.substring(0, colon), userinfo.substring(colon + 1)};
          for (String part : parts) {
            if (!"".equals(part)) {
              ctx.utility.cleanAdd.apply(ctx, part);
              ctx.utility.cleanAdd.apply(ctx, URLDecoder.decode(part, StandardCharsets.UTF_8));
            }
          }
        }
      }
      catch (URISyntaxException | RuntimeException e) {
        // An unparseable target routes nothing (see route), so there is
        // nothing to register.
      }
    }
    this.url = ctx.utility != null && ctx.utility.clean != null
        ? String.valueOf(ctx.utility.clean.apply(ctx, this.target)) : this.target;

    final Utility.FetcherFn inner = ctx.utility.fetcher;

    ctx.utility.fetcher = (ctx2, u, fetchdef) ->
        inner.fetch(ctx2, u, route(u, fetchdef));
  }

  private Map<String, Object> route(String u, Map<String, Object> fetchdef) {
    if ("".equals(this.target) || bypass(u)) {
      return fetchdef;
    }

    Map<String, Object> out = new LinkedHashMap<>(fetchdef);
    out.put("proxy", this.target);

    this.routed++;
    return out;
  }

  private boolean bypass(String u) {
    if (this.noProxy.isEmpty()) {
      return false;
    }
    String host = u;
    Matcher m = HOST_RE.matcher(u);
    if (m.find()) {
      host = m.group(1);
    }
    for (String np : this.noProxy) {
      if ("*".equals(np)) {
        return true;
      }
      String suffix = np.startsWith(".") ? np.substring(1) : np;
      if (host.equals(np) || host.endsWith("." + suffix)) {
        return true;
      }
    }
    return false;
  }

  private static String firstEnv(String... names) {
    for (String name : names) {
      String v = System.getenv(name);
      if (v != null && !"".equals(v)) {
        return v;
      }
    }
    return "";
  }
}
