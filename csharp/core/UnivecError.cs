// UnivecError - the SDK error type. Carries the pipeline error code,
// the originating context and cleaned result/spec snapshots.

using System.Text.Json.Serialization;

using Voxgig.Struct;

namespace UnivecSdk;

public class UnivecError : Exception
{
    public bool IsUnivecError = true;
    public string Sdk = "Univec";
    public string Code;

    // Reachable for a debugger, out of every serialiser: the context holds
    // the live spec and options, and an error is what gets logged.
    [JsonIgnore]
    public Context? Ctx;

    // The HTTP status, -1 when there was no response.
    public int Status = -1;

    public object? ResultVal;
    public object? SpecVal;

    private string _message;

    public UnivecError(string code, string msg, Context? ctx)
        : base(msg)
    {
        Code = code;
        Ctx = ctx;
        _message = msg;
    }

    public override string Message => _message;

    public bool NotFound => 404 == Status;

    // Clean rewrites the message in place, since the error is about to be
    // thrown; Exception's own is read-only.
    internal void SetMessage(string msg)
    {
        _message = msg;
    }

    // What MakeError attached is already cleaned; the context is not part of
    // the record.
    public Dictionary<string, object?> ToRecord()
    {
        return new Dictionary<string, object?>
        {
            ["sdk"] = Sdk,
            ["code"] = Code,
            ["message"] = Message,
            ["status"] = Status,
            ["result"] = ResultVal,
            ["spec"] = SpecVal,
        };
    }

    public override string ToString()
    {
        var text = GetType().FullName + ": [" + Code + "] " + Message +
            " (status " + Status + ") spec=" + StructUtils.Jsonify(SpecVal, 0);
        var stack = StackTrace;
        return null == stack ? text : text + "\n" + stack;
    }
}
