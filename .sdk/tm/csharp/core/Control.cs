// Univec SDK - per-call control block.

namespace UnivecSdk;

public class Control
{
    public bool? Throw;
    public Exception? Err;
    public Dictionary<string, object?>? Explain;
    public string Actor = "";
    public Dictionary<string, object?>? Paging;

    // Outbound streaming marker: the entity `stream` method sets this to the
    // caller-supplied async payload so the request builder / transport can
    // stream it as the request body.
    public object? Stream_out;
}
