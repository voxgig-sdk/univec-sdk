// Load operation fragment (spliced into the entity class by
// EntityOperation_csharp; only the EJECT region is emitted).

namespace ProjectNameSdk.Entity;

public class EntyClassLoadOpFragment : EntyClass
{
    public EntyClassLoadOpFragment(ProjectNameSDK client) : base(client) { }

// EJECT-START
public override object? Load(Dictionary<string, object?>? reqmatch,
    Dictionary<string, object?>? ctrl = null)
{
    var ctx = utility.MakeContext(new Dictionary<string, object?>
    {
        ["opname"] = "load",
        ["ctrl"] = ctrl,
        ["match"] = match,
        ["data"] = data,
        ["reqmatch"] = reqmatch,
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
