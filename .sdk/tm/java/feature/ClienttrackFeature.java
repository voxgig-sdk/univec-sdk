package JAVAPACKAGE.feature;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import java.util.function.Function;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Spec;

// Client tracking. Establishes a stable per-client session id at
// construction and stamps identifying headers on every request: a
// `User-Agent` (`<clientName>/<clientVersion>`), an `X-Client-Id` (session),
// and a fresh per-request `X-Request-Id`. This lets a server correlate all
// traffic from one SDK instance and each individual call. Header names,
// client name/version and the id generator (`idgen`) are configurable;
// caller-provided User-Agent / X-Client-Id values are never clobbered.
@SuppressWarnings({"unchecked"})
public class ClienttrackFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;

  // Activity tracking (mirrors the ts client._clienttrack record).
  public String session = "";
  public int requests = 0;
  public String lastRequestId = "";
  public String clientName = "";

  public ClienttrackFeature() {
    super("clienttrack", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);
    this.requests = 0;
  }

  @Override
  public void postConstruct(Context ctx) {
    if (!this.active) {
      return;
    }
    this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"));
    this.clientName = name();
  }

  @Override
  public void preRequest(Context ctx) {
    if (!this.active) {
      return;
    }

    Spec spec = ctx.spec;
    if (spec == null) {
      return;
    }
    if (spec.headers == null) {
      spec.headers = new LinkedHashMap<>();
    }

    // Lazily establish the session when PostConstruct never fired.
    if ("".equals(this.session)) {
      this.session = FeatureOptions.foptStr(this.options, "sessionId", genid("session"));
    }

    Map<String, Object> h = FeatureOptions.foptMap(this.options, "headers");
    this.requests++;
    String requestId = genid("request");

    FeatureOptions.fheaderSetDefault(spec.headers,
        FeatureOptions.foptStr(h, "agent", "User-Agent"), name());
    FeatureOptions.fheaderSetDefault(spec.headers,
        FeatureOptions.foptStr(h, "client", "X-Client-Id"), this.session);
    spec.headers.put(FeatureOptions.foptStr(h, "request", "X-Request-Id"), requestId);

    this.lastRequestId = requestId;
    this.clientName = name();
  }

  private String name() {
    String name = FeatureOptions.foptStr(this.options, "clientName", "Univec-SDK");
    String version = FeatureOptions.foptStr(this.options, "clientVersion", "0.0.1");
    return name + "/" + version;
  }

  private String genid(String kind) {
    if (this.options.get("idgen") instanceof Function) {
      return ((Function<String, String>) this.options.get("idgen")).apply(kind);
    }
    ThreadLocalRandom r = ThreadLocalRandom.current();
    String id = String.format("%s-%06x%06x%06x", kind.substring(0, 1),
        r.nextInt(0x1000000), r.nextInt(0x1000000), r.nextInt(0x1000000));
    if (id.length() > 20) {
      id = id.substring(0, 20);
    }
    return id;
  }
}
