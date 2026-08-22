// UnivecError - the SDK error type. Carries the pipeline error code,
// the originating context and cleaned result/spec snapshots.

namespace UnivecSdk;

public class UnivecError : Exception
{
    public bool IsUnivecError = true;
    public string Sdk = "Univec";
    public string Code;
    public Context? Ctx;
    public object? ResultVal;
    public object? SpecVal;

    public UnivecError(string code, string msg, Context? ctx)
        : base(msg)
    {
        Code = code;
        Ctx = ctx;
    }
}
