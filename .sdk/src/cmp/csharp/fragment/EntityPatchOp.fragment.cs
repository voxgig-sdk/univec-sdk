// Patch operation fragment (spliced into the entity class by
// EntityOperation_csharp; only the EJECT region is emitted).

namespace ProjectNameSdk.Entity;

public class EntyClassPatchOpFragment : EntyClass
{
    public EntyClassPatchOpFragment(ProjectNameSDK client) : base(client) { }

// EJECT-START
public override object? Patch(Dictionary<string, object?>? reqdata,
    Dictionary<string, object?>? ctrl = null)
{
    var ctx = utility.MakeContext(new Dictionary<string, object?>
    {
        ["opname"] = "patch",
        ["ctrl"] = ctrl,
        ["match"] = match,
        ["data"] = data,
        ["reqdata"] = reqdata,
    }, entctx);

    return RunOp(ctx, () =>
    {
        if (ctx.Result != null)
        {
            if (ctx.Result.Resmatch != null)
            {
                match = ctx.Result.Resmatch;
            }
            if (ctx.Result.Resdata != null)
            {
                data = Helpers.ToMapAny(
                    Voxgig.Struct.StructUtils.Clone(ctx.Result.Resdata))
                    ?? new Dictionary<string, object?>();
            }
        }
    });
}
// EJECT-END
}
