package JAVAPACKAGE.feature;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

import JAVAPACKAGE.core.Context;
import JAVAPACKAGE.core.SdkClient;
import JAVAPACKAGE.core.Utility;

// Response caching for safe (read) requests. Wraps the active transport and
// serves a fresh cached snapshot instead of hitting the network when the
// same method+URL was fetched within `ttl` ms (default: 5000). Only
// successful (2xx) responses to cacheable methods (default: GET) are
// stored, keyed by method+URL. The cache is bounded (`max` entries, default
// 256, oldest evicted first) and every hit/miss/bypass is counted. Bodies
// are snapshotted on capture so both the current caller and later hits can
// re-read the JSON body repeatedly.
@SuppressWarnings({"unchecked"})
public class CacheFeature extends BaseFeature {

  private SdkClient client;
  private Map<String, Object> options;
  private Map<String, CacheEntry> store;
  private List<String> order;

  // Activity tracking (mirrors the ts client._cache record).
  public int hit = 0;
  public int miss = 0;
  public int bypass = 0;

  private static final class CacheEntry {
    long expiry;
    CacheSnapshot snapshot;
  }

  private static final class CacheSnapshot {
    int status;
    String statusText = "";
    Object data;
    Map<String, Object> headers = new LinkedHashMap<>();
  }

  public CacheFeature() {
    super("cache", "0.0.1", true);
  }

  @Override
  public void init(Context ctx, Map<String, Object> options) {
    this.client = ctx.client;
    this.options = options;
    this.active = FeatureOptions.foptBool(options, "active", false);

    if (!this.active) {
      return;
    }

    this.store = new LinkedHashMap<>();
    this.order = new ArrayList<>();

    final Utility.FetcherFn inner = ctx.utility.fetcher;

    ctx.utility.fetcher = (ctx2, url, fetchdef) ->
        through(ctx2, url, fetchdef, inner);
  }

  private Object through(Context ctx, String url, Map<String, Object> fetchdef,
      Utility.FetcherFn inner) {

    String method = "GET";
    Object m = fetchdef.get("method");
    if (m instanceof String && !"".equals(m)) {
      method = ((String) m).toUpperCase();
    }

    List<String> methods = FeatureOptions.foptStrList(this.options, "methods");
    if (methods == null) {
      methods = List.of("GET");
    }
    boolean cacheable = false;
    for (String cm : methods) {
      if (cm.toUpperCase().equals(method)) {
        cacheable = true;
        break;
      }
    }
    if (!cacheable) {
      return inner.fetch(ctx, url, fetchdef);
    }

    String key = method + " " + url;
    long now = FeatureOptions.foptNow(this.options).getAsLong();

    CacheEntry hitEntry = this.store.get(key);
    if (hitEntry != null && hitEntry.expiry > now) {
      this.hit++;
      return replay(hitEntry.snapshot);
    }

    Object res;
    try {
      res = inner.fetch(ctx, url, fetchdef);
    }
    catch (RuntimeException err) {
      this.bypass++;
      throw err;
    }

    if (storable(res)) {
      CacheSnapshot snapshot = snapshot(res);
      int ttl = FeatureOptions.foptInt(this.options, "ttl", 5000);
      evict();
      CacheEntry entry = new CacheEntry();
      entry.expiry = now + ttl;
      entry.snapshot = snapshot;
      this.store.put(key, entry);
      this.order.add(key);
      this.miss++;
      return replay(snapshot);
    }

    this.bypass++;
    return res;
  }

  private boolean storable(Object res) {
    int status = FeatureOptions.fresStatus(res);
    return status >= 200 && status < 300;
  }

  private CacheSnapshot snapshot(Object res) {
    Map<String, Object> rm = res instanceof Map ? (Map<String, Object>) res : null;

    CacheSnapshot snap = new CacheSnapshot();

    int status = FeatureOptions.fresStatus(res);
    if (status >= 0) {
      snap.status = status;
    }
    if (rm != null) {
      Object st = rm.get("statusText");
      if (st instanceof String) {
        snap.statusText = (String) st;
      }
      Object jf = rm.get("json");
      if (jf instanceof Supplier) {
        snap.data = ((Supplier<Object>) jf).get();
      }
      Object headers = rm.get("headers");
      if (headers instanceof Map) {
        for (Map.Entry<String, Object> h : ((Map<String, Object>) headers).entrySet()) {
          snap.headers.put(h.getKey().toLowerCase(), h.getValue());
        }
      }
    }

    return snap;
  }

  // replay builds a fresh transport-shaped response so the body stays
  // re-readable for every consumer.
  private Map<String, Object> replay(CacheSnapshot snap) {
    final Object data = snap.data;
    Map<String, Object> headers = new LinkedHashMap<>(snap.headers);
    Map<String, Object> out = new LinkedHashMap<>();
    out.put("status", snap.status);
    out.put("statusText", snap.statusText);
    out.put("body", "not-used");
    out.put("json", (Supplier<Object>) () -> data);
    out.put("headers", headers);
    return out;
  }

  // evict drops oldest entries (FIFO) until the store is under `max`.
  private void evict() {
    int max = FeatureOptions.foptInt(this.options, "max", 256);
    while (this.store.size() >= max && !this.order.isEmpty()) {
      String oldest = this.order.remove(0);
      this.store.remove(oldest);
    }
  }
}
