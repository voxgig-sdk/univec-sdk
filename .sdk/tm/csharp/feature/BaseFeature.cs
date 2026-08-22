// Univec SDK - feature base class. Features derive from this and
// override the hooks they need; unimplemented hooks are no-ops.

namespace UnivecSdk.Feature;

public class BaseFeature
{
    public string Version = "0.0.1";
    public string Name = "base";
    public bool Active = true;

    // AddOpts positions this feature when added via the client `extend`
    // option: "__before__", "__after__" or "__replace__" name an
    // already-added feature (mirrors the ts feature `_options`).
    public Dictionary<string, object?>? AddOpts;

    // AddOptions is read by the featureAdd utility to place this feature.
    public virtual Dictionary<string, object?>? AddOptions() => AddOpts;

    public virtual string GetVersion() => Version;
    public virtual string GetName() => Name;
    public virtual bool GetActive() => Active;

    public virtual void Init(Context ctx, Dictionary<string, object?> options) { }

    public virtual void PostConstruct(Context ctx) { }
    public virtual void PostConstructEntity(Context ctx) { }
    public virtual void SetData(Context ctx) { }
    public virtual void GetData(Context ctx) { }
    public virtual void GetMatch(Context ctx) { }
    public virtual void SetMatch(Context ctx) { }
    public virtual void PrePoint(Context ctx) { }
    public virtual void PreSpec(Context ctx) { }
    public virtual void PreRequest(Context ctx) { }
    public virtual void PreResponse(Context ctx) { }
    public virtual void PreResult(Context ctx) { }
    public virtual void PreDone(Context ctx) { }
    public virtual void PreUnexpected(Context ctx) { }
}
