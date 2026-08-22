// Univec SDK - operation context.

using Voxgig.Struct;

namespace UnivecSdk;

public class Context
{
    public string Id = "";
    public Dictionary<string, object?> Out = new();
    public Control Ctrl = new();
    public Dictionary<string, object?> Meta = new();
    public UnivecSDK? Client;
    public Utility? Utility;
    public Operation? Op;
    public Dictionary<string, object?>? Point;
    public Dictionary<string, object?>? Config;
    public Dictionary<string, object?>? Entopts;
    public Dictionary<string, object?>? Options;
    public Dictionary<string, Operation> Opmap = new();
    public Response? Response;
    public Result? Result;
    public Spec? Spec;
    public Dictionary<string, object?> Data = new();
    public Dictionary<string, object?> Reqdata = new();
    public Dictionary<string, object?> Match = new();
    public Dictionary<string, object?> Reqmatch = new();
    public IEntity? Entity;
    public Dictionary<string, object?>? Shared;

    public Context(Dictionary<string, object?>? ctxmap, Context? basectx)
    {
        Id = "C" + (Random.Shared.Next(90000000) + 10000000);

        // Client
        if (Helpers.GetCtxProp(ctxmap, "client") is UnivecSDK sdk)
        {
            Client = sdk;
        }
        if (Client == null && basectx != null)
        {
            Client = basectx.Client;
        }

        // Utility
        if (Helpers.GetCtxProp(ctxmap, "utility") is Utility util)
        {
            Utility = util;
        }
        if (Utility == null && basectx != null)
        {
            Utility = basectx.Utility;
        }

        // Ctrl
        Ctrl = new Control();
        var rawctrl = Helpers.GetCtxProp(ctxmap, "ctrl");
        if (rawctrl is Dictionary<string, object?> cm)
        {
            if (cm.TryGetValue("throw", out var t) && t is bool tb)
            {
                Ctrl.Throw = tb;
            }
            if (cm.TryGetValue("explain", out var e) && e is Dictionary<string, object?> em)
            {
                Ctrl.Explain = em;
            }
            if (cm.TryGetValue("actor", out var a) && a is string actor)
            {
                Ctrl.Actor = actor;
            }
            if (cm.TryGetValue("paging", out var p) && p is Dictionary<string, object?> pm)
            {
                Ctrl.Paging = pm;
            }
        }
        else if (rawctrl is Control ctrl)
        {
            Ctrl = ctrl;
        }
        else if (basectx?.Ctrl != null)
        {
            Ctrl = basectx.Ctrl;
        }

        // Meta
        Meta = new Dictionary<string, object?>();
        if (Helpers.GetCtxProp(ctxmap, "meta") is Dictionary<string, object?> mm)
        {
            Meta = mm;
        }
        else if (basectx?.Meta != null)
        {
            Meta = basectx.Meta;
        }

        // Config
        if (Helpers.GetCtxProp(ctxmap, "config") is Dictionary<string, object?> cfg)
        {
            Config = cfg;
        }
        if (Config == null && basectx != null)
        {
            Config = basectx.Config;
        }

        // Entopts
        if (Helpers.GetCtxProp(ctxmap, "entopts") is Dictionary<string, object?> eo)
        {
            Entopts = eo;
        }
        if (Entopts == null && basectx != null)
        {
            Entopts = basectx.Entopts;
        }

        // Options
        if (Helpers.GetCtxProp(ctxmap, "options") is Dictionary<string, object?> om)
        {
            Options = om;
        }
        if (Options == null && basectx != null)
        {
            Options = basectx.Options;
        }

        // Entity
        if (Helpers.GetCtxProp(ctxmap, "entity") is IEntity ent)
        {
            Entity = ent;
        }
        if (Entity == null && basectx != null)
        {
            Entity = basectx.Entity;
        }

        // Shared
        if (Helpers.GetCtxProp(ctxmap, "shared") is Dictionary<string, object?> sh)
        {
            Shared = sh;
        }
        if (Shared == null && basectx != null)
        {
            Shared = basectx.Shared;
        }

        // Opmap
        if (Helpers.GetCtxProp(ctxmap, "opmap") is Dictionary<string, Operation> opm)
        {
            Opmap = opm;
        }
        else if (basectx?.Opmap != null)
        {
            Opmap = basectx.Opmap;
        }
        Opmap ??= new Dictionary<string, Operation>();

        // Data maps
        Data = Helpers.ToMapAny(Helpers.GetCtxProp(ctxmap, "data")) ?? new Dictionary<string, object?>();
        Reqdata = Helpers.ToMapAny(Helpers.GetCtxProp(ctxmap, "reqdata")) ?? new Dictionary<string, object?>();
        Match = Helpers.ToMapAny(Helpers.GetCtxProp(ctxmap, "match")) ?? new Dictionary<string, object?>();
        Reqmatch = Helpers.ToMapAny(Helpers.GetCtxProp(ctxmap, "reqmatch")) ?? new Dictionary<string, object?>();

        // Point
        if (Helpers.GetCtxProp(ctxmap, "point") is Dictionary<string, object?> tm)
        {
            Point = tm;
        }
        if (Point == null && basectx != null)
        {
            Point = basectx.Point;
        }

        // Spec
        if (Helpers.GetCtxProp(ctxmap, "spec") is Spec sp)
        {
            Spec = sp;
        }
        if (Spec == null && basectx != null)
        {
            Spec = basectx.Spec;
        }

        // Result
        if (Helpers.GetCtxProp(ctxmap, "result") is Result res)
        {
            Result = res;
        }
        if (Result == null && basectx != null)
        {
            Result = basectx.Result;
        }

        // Response
        if (Helpers.GetCtxProp(ctxmap, "response") is Response resp)
        {
            Response = resp;
        }
        if (Response == null && basectx != null)
        {
            Response = basectx.Response;
        }

        // Resolve operation
        var opname = Helpers.GetCtxProp(ctxmap, "opname") as string ?? "";
        Op = ResolveOp(opname);
    }

    private Operation ResolveOp(string opname)
    {
        // Cache key is `<entity>:<opname>` so two entities with the same op
        // (e.g. both have a "list") get distinct cached Operations.
        var entname = Entity?.GetName() ?? "";
        var cacheKey = entname + ":" + opname;

        if (Opmap.TryGetValue(cacheKey, out var cached) && cached != null)
        {
            return cached;
        }

        if (opname == "")
        {
            return new Operation(new Dictionary<string, object?>());
        }

        var opcfg = StructUtils.GetPath(Config,
            StructUtils.Jt("entity", entname, "op", opname));

        var input = (opname == "update" || opname == "create") ? "data" : "match";

        List<object?>? points = null;
        if (opcfg is Dictionary<string, object?> ocm)
        {
            if (StructUtils.GetProp(ocm, "points") is List<object?> tl)
            {
                points = tl;
            }
        }
        points ??= new List<object?>();

        var op = new Operation(new Dictionary<string, object?>
        {
            ["entity"] = entname,
            ["name"] = opname,
            ["input"] = input,
            ["points"] = points,
        });

        Opmap[cacheKey] = op;
        return op;
    }

    public UnivecError MakeError(string code, string msg)
    {
        return new UnivecError(code, msg, this);
    }
}
