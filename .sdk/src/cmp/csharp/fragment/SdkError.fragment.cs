// ProjectNameError - the SDK error type. Carries the pipeline error code,
// the originating context and cleaned result/spec snapshots.

namespace ProjectNameSdk;

public class ProjectNameError : Exception
{
    public bool IsProjectNameError = true;
    public string Sdk = "ProjectName";
    public string Code;
    public Context? Ctx;
    public object? ResultVal;
    public object? SpecVal;

    public ProjectNameError(string code, string msg, Context? ctx)
        : base(msg)
    {
        Code = code;
        Ctx = ctx;
    }
}
