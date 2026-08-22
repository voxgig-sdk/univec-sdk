// List operation fragment (spliced into the entity class by
// EntityOperation_csharp; only the EJECT region is emitted).

namespace ProjectNameSdk.Entity;

public class EntyClassListOpFragment : EntyClass
{
    public EntyClassListOpFragment(ProjectNameSDK client) : base(client) { }

// EJECT-START
public override object? List(Dictionary<string, object?>? reqmatch,
    Dictionary<string, object?>? ctrl = null)
{
    var ctx = utility.MakeContext(new Dictionary<string, object?>
    {
        ["opname"] = "list",
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
        }
    });
}
// EJECT-END
}
