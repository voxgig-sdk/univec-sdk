package voxgig.univecsdk.core;

// Typed reference models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON). Do
// not edit by hand.
//
// These records are documentation/DX reference shapes ONLY. The SDK ops take
// and return the loose object model (Map<String, Object> / Object) at runtime,
// so these types are not wired into the op signatures — use them to describe a
// payload before converting it to a map. Every component is a boxed (nullable)
// type, so an optional (req:false) key needs no distinct rendering.

import java.util.List;
import java.util.Map;

public final class UnivecTypes {

  private UnivecTypes() {}

  public record Convert(String bridge_model, List<Object> embeddings, String source_model, String target_model, List<Object> texts) {}

  public record ConvertCreateData(String bridge_model, List<Object> embeddings, String source_model, String target_model, List<Object> texts) {}

  public record Embed(List<Object> embeddings, String model, List<Object> texts) {}

  public record EmbedCreateData(List<Object> embeddings, String model, List<Object> texts) {}

  public record EphemeralKey(Long dailyLimit, Long dailyUsed, String key, String resetsAt) {}

  public record EphemeralKeyCreateData(Long dailyLimit, Long dailyUsed, String key, String resetsAt) {}

  public record Model(Map<String, Object> eval, String executionProvider, Map<String, Object> modelCard, String modelType, String name, Long sequenceLen, Long sourceDim, String sourceModel, Long targetDim, String targetModel) {}

  public record ModelListMatch(Map<String, Object> eval, String executionProvider, Map<String, Object> modelCard, String modelType, String name, Long sequenceLen, Long sourceDim, String sourceModel, Long targetDim, String targetModel) {}

}
