// Typed reference models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON). Do
// not edit by hand.
//
// These records are documentation/DX reference shapes ONLY. The SDK ops take
// and return the loose object model (Dictionary<string, object?> / object?) at
// runtime, so these types are not wired into the op signatures — use them to
// describe a payload before converting it to a dictionary. Optional (req:false)
// keys are modelled as nullable properties.

namespace UnivecSdk.Types;

public record Convert
{
    public List<object?> embeddings { get; init; }
    public string source_model { get; init; }
    public string target_model { get; init; }
}

public record ConvertCreateData
{
    public List<object?> embeddings { get; init; }
    public string source_model { get; init; }
    public string target_model { get; init; }
}

public record Embed
{
    public List<object?> embeddings { get; init; }
    public string model { get; init; }
    public List<object?> texts { get; init; }
}

public record EmbedCreateData
{
    public List<object?> embeddings { get; init; }
    public string model { get; init; }
    public List<object?> texts { get; init; }
}

public record EphemeralKey
{
    public long dailyLimit { get; init; }
    public long dailyUsed { get; init; }
    public string key { get; init; }
    public string resetsAt { get; init; }
}

public record EphemeralKeyCreateData
{
    public long dailyLimit { get; init; }
    public long dailyUsed { get; init; }
    public string key { get; init; }
    public string resetsAt { get; init; }
}

public record Model
{
    public Dictionary<string, object?>? eval { get; init; }
    public string? executionProvider { get; init; }
    public Dictionary<string, object?>? modelCard { get; init; }
    public string modelType { get; init; }
    public string name { get; init; }
    public long? sequenceLen { get; init; }
    public long? sourceDim { get; init; }
    public string? sourceModel { get; init; }
    public long targetDim { get; init; }
    public string targetModel { get; init; }
}

public record ModelListMatch
{
    public Dictionary<string, object?>? eval { get; init; }
    public string? executionProvider { get; init; }
    public Dictionary<string, object?>? modelCard { get; init; }
    public string? modelType { get; init; }
    public string? name { get; init; }
    public long? sequenceLen { get; init; }
    public long? sourceDim { get; init; }
    public string? sourceModel { get; init; }
    public long? targetDim { get; init; }
    public string? targetModel { get; init; }
}

