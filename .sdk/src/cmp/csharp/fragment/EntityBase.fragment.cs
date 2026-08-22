// ProjectNameEntityBase - shared entity behaviour: construction, data/match
// state (with feature hooks), the operation pipeline (RunOp) and default
// unsupported-op implementations of every CRUD method. Generated entity
// classes derive from this and override the operations their API defines.

using System.Runtime.CompilerServices;

using Voxgig.Struct;

namespace ProjectNameSdk;

public abstract class ProjectNameEntityBase : IEntity
{
    protected string name;
    protected ProjectNameSDK client;
    protected Utility utility;
    protected Dictionary<string, object?> entopts;
    protected Dictionary<string, object?> data = new();
    protected Dictionary<string, object?> match = new();
    protected Context entctx;

    // Every operation resolves to the entity; `remove` additionally marks
    // it. The instance KEEPS the data it held — a caller can still read what
    // was deleted — but it is no longer a live record. See AGENTS.md.
    private bool _deleted = false;

    public void MarkDeleted()
    {
        this._deleted = true;
    }

    public bool Deleted()
    {
        return this._deleted;
    }


    protected ProjectNameEntityBase(ProjectNameSDK client,
        Dictionary<string, object?>? entopts, string name)
    {
        entopts ??= new Dictionary<string, object?>();
        if (!entopts.ContainsKey("active"))
        {
            entopts["active"] = true;
        }
        else if (!Equals(entopts["active"], false))
        {
            entopts["active"] = true;
        }

        this.name = name;
        this.client = client;
        this.utility = client.GetUtility();
        this.entopts = entopts;

        this.entctx = utility.MakeContext(new Dictionary<string, object?>
        {
            ["entity"] = this,
            ["entopts"] = entopts,
        }, client.GetRootCtx());

        utility.FeatureHook(this.entctx, "PostConstructEntity");
    }

    public string GetName() => name;

    public abstract IEntity Make();

    protected Dictionary<string, object?> CloneOpts()
    {
        return new Dictionary<string, object?>(entopts);
    }

    public object? Data(object? newdata = null)
    {
        if (newdata != null)
        {
            data = Helpers.ToMapAny(StructUtils.Clone(newdata))
                ?? new Dictionary<string, object?>();
            utility.FeatureHook(entctx, "SetData");
        }

        utility.FeatureHook(entctx, "GetData");
        return StructUtils.Clone(data);
    }

    public object? Match(object? newmatch = null)
    {
        if (newmatch != null)
        {
            match = Helpers.ToMapAny(StructUtils.Clone(newmatch))
                ?? new Dictionary<string, object?>();
            utility.FeatureHook(entctx, "SetMatch");
        }

        utility.FeatureHook(entctx, "GetMatch");
        return StructUtils.Clone(match);
    }

    public virtual object? Load(Dictionary<string, object?>? reqmatch,
        Dictionary<string, object?>? ctrl = null)
        => throw Helpers.UnsupportedOp("load", name);

    public virtual object? List(Dictionary<string, object?>? reqmatch,
        Dictionary<string, object?>? ctrl = null)
        => throw Helpers.UnsupportedOp("list", name);

    public virtual object? Create(Dictionary<string, object?>? reqdata,
        Dictionary<string, object?>? ctrl = null)
        => throw Helpers.UnsupportedOp("create", name);

    public virtual object? Update(Dictionary<string, object?>? reqdata,
        Dictionary<string, object?>? ctrl = null)
        => throw Helpers.UnsupportedOp("update", name);

    public virtual object? Remove(Dictionary<string, object?>? reqmatch,
        Dictionary<string, object?>? ctrl = null)
        => throw Helpers.UnsupportedOp("remove", name);

    protected object? RunOp(Context ctx, Action postDone)
    {
        // #PrePoint-Hook

        try
        {
            var point = utility.MakePoint(ctx);
            ctx.Out["point"] = point;
        }
        catch (Exception err)
        {
            return utility.MakeError(ctx, err);
        }

        // #PreSpec-Hook

        try
        {
            var spec = utility.MakeSpec(ctx);
            ctx.Out["spec"] = spec;
        }
        catch (Exception err)
        {
            return utility.MakeError(ctx, err);
        }

        // #PreRequest-Hook

        try
        {
            var resp = utility.MakeRequest(ctx);
            ctx.Out["request"] = resp;
        }
        catch (Exception err)
        {
            return utility.MakeError(ctx, err);
        }

        // #PreResponse-Hook

        try
        {
            var resp2 = utility.MakeResponse(ctx);
            ctx.Out["response"] = resp2;
        }
        catch (Exception err)
        {
            return utility.MakeError(ctx, err);
        }

        // #PreResult-Hook

        try
        {
            var result = utility.MakeResult(ctx);
            ctx.Out["result"] = result;
        }
        catch (Exception err)
        {
            return utility.MakeError(ctx, err);
        }

        // #PreDone-Hook

        postDone();

        var outv = utility.Done(ctx);

        // An operation resolves to the ENTITY, not the raw data. Entities are
        // stateful: postDone has just absorbed Resdata/Resmatch into this
        // instance, and the caller reaches the record through Data(). Two
        // structural exceptions: `list` resolves to the ARRAY of entity
        // instances MakeResult built, and a failed op with throwing disabled
        // hands back the error payload unchanged. `remove` additionally marks
        // the entity deleted; it KEEPS its data, so a caller can still read
        // what was removed. See AGENTS.md "Entity operations return ENTITIES".
        var opname = ctx.Op?.Name;

        if (ctx.Result != null && ctx.Result.Ok && "list" != opname)
        {
            if ("remove" == opname)
            {
                this.MarkDeleted();
            }
            return this;
        }

        return outv;
    }

    // Streaming operations. Runs `action` through the full pipeline and returns
    // an async iterator over result items, so the `streaming` feature's
    // incremental output is reachable from a generated entity (a normal op call
    // materialises the whole result). `callopts` parameterises the call:
    //   - inbound (download): iterate the yielded items/chunks (from the
    //     streaming feature when active, else the materialised items);
    //   - outbound (upload): pass a streamable payload as callopts["body"] - it
    //     is attached to the request so the transport can send it;
    //   - callopts["ctrl"] threads pipeline control and callopts["signal"] (a
    //     CancellationToken) is honoured between yields.
    public async IAsyncEnumerable<object?> Stream(
        string action,
        Dictionary<string, object?>? args = null,
        Dictionary<string, object?>? callopts = null,
        [EnumeratorCancellation] CancellationToken cancel = default)
    {
        callopts ??= new Dictionary<string, object?>();

        var signal =
            StructUtils.GetProp(callopts, "signal") is CancellationToken sigTok
                ? sigTok
                : CancellationToken.None;

        var ctrl = Helpers.ToMapAny(StructUtils.GetProp(callopts, "ctrl"))
            ?? new Dictionary<string, object?>();
        ctrl["stream"] = callopts;

        var ctxmap = new Dictionary<string, object?>
        {
            ["opname"] = action,
            ["ctrl"] = ctrl,
            ["match"] = match,
            ["data"] = data,
        };
        if (args != null)
        {
            foreach (var kv in args)
            {
                ctxmap[kv.Key] = kv.Value;
            }
        }

        var ctx = utility.MakeContext(ctxmap, entctx);

        // Outbound: expose the caller's streamable payload so the request
        // builder / transport can stream it as the request body.
        var body = StructUtils.GetProp(callopts, "body");
        if (body != null)
        {
            ctx.Reqdata["body$"] = body;
            ctx.Ctrl.Stream_out = body;
        }

        // Run the same pipeline the op methods run.
        var materialised = RunOp(ctx, () =>
        {
            if (ctx.Result?.Resmatch != null)
            {
                match = ctx.Result.Resmatch;
            }
        });

        await Task.CompletedTask;

        // Inbound: prefer the streaming feature's incremental iterator; else
        // fall back to the materialised items so `stream` always yields.
        var stream = ctx.Result?.Stream;
        if (stream != null)
        {
            foreach (var item in stream())
            {
                if (cancel.IsCancellationRequested || signal.IsCancellationRequested)
                {
                    yield break;
                }
                yield return item;
            }
        }
        else
        {
            var items = materialised is List<object?> list
                ? list
                : (materialised == null
                    ? new List<object?>()
                    : new List<object?> { materialised });
            foreach (var item in items)
            {
                if (cancel.IsCancellationRequested || signal.IsCancellationRequested)
                {
                    yield break;
                }
                yield return item;
            }
        }
    }
}
