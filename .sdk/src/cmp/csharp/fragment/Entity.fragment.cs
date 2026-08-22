// EntityName entity client for the ProjectName SDK.

using Voxgig.Struct;

namespace ProjectNameSdk.Entity;

public class EntyClass : ProjectNameEntityBase
{
    public EntyClass(ProjectNameSDK client, Dictionary<string, object?>? entopts = null)
        : base(client, entopts, "entityname")
    {
    }

    public override IEntity Make()
    {
        return new EntyClass(client, CloneOpts());
    }

    // #LoadOp

    // #ListOp

    // #CreateOp

    // #UpdateOp

    // #RemoveOp
}
