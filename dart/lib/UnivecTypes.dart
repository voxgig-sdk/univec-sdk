// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels (source of truth: @voxgig/apidef VALID_CANON).
// Do not edit by hand.
//
// The operation pipeline passes plain maps; these classes are the typed,
// convertible view: `Univec.fromMap(ent.data())` / `model.toMap()`.

class Convert {
  /// ARRAY (required at the API)
  List<dynamic>? embeddings;
  /// STRING (required at the API)
  String? source_model;
  /// STRING (required at the API)
  String? target_model;

  Convert({
    this.embeddings,
    this.source_model,
    this.target_model,
  });

  factory Convert.fromMap(Map<String, dynamic> m) => Convert(
        embeddings: m['embeddings'] is List<dynamic> ? m['embeddings'] : null,
        source_model: m['source_model'] is String ? m['source_model'] : null,
        target_model: m['target_model'] is String ? m['target_model'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != embeddings) {
      m['embeddings'] = embeddings;
    }
    if (null != source_model) {
      m['source_model'] = source_model;
    }
    if (null != target_model) {
      m['target_model'] = target_model;
    }
    return m;
  }
}

class ConvertCreateData {
  /// ARRAY (required at the API)
  List<dynamic>? embeddings;
  /// STRING (required at the API)
  String? source_model;
  /// STRING (required at the API)
  String? target_model;

  ConvertCreateData({
    this.embeddings,
    this.source_model,
    this.target_model,
  });

  factory ConvertCreateData.fromMap(Map<String, dynamic> m) => ConvertCreateData(
        embeddings: m['embeddings'] is List<dynamic> ? m['embeddings'] : null,
        source_model: m['source_model'] is String ? m['source_model'] : null,
        target_model: m['target_model'] is String ? m['target_model'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != embeddings) {
      m['embeddings'] = embeddings;
    }
    if (null != source_model) {
      m['source_model'] = source_model;
    }
    if (null != target_model) {
      m['target_model'] = target_model;
    }
    return m;
  }
}

class Embed {
  /// ARRAY (required at the API)
  List<dynamic>? embeddings;
  /// STRING (required at the API)
  String? model;
  /// ARRAY (required at the API)
  List<dynamic>? texts;

  Embed({
    this.embeddings,
    this.model,
    this.texts,
  });

  factory Embed.fromMap(Map<String, dynamic> m) => Embed(
        embeddings: m['embeddings'] is List<dynamic> ? m['embeddings'] : null,
        model: m['model'] is String ? m['model'] : null,
        texts: m['texts'] is List<dynamic> ? m['texts'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != embeddings) {
      m['embeddings'] = embeddings;
    }
    if (null != model) {
      m['model'] = model;
    }
    if (null != texts) {
      m['texts'] = texts;
    }
    return m;
  }
}

class EmbedCreateData {
  /// ARRAY (required at the API)
  List<dynamic>? embeddings;
  /// STRING (required at the API)
  String? model;
  /// ARRAY (required at the API)
  List<dynamic>? texts;

  EmbedCreateData({
    this.embeddings,
    this.model,
    this.texts,
  });

  factory EmbedCreateData.fromMap(Map<String, dynamic> m) => EmbedCreateData(
        embeddings: m['embeddings'] is List<dynamic> ? m['embeddings'] : null,
        model: m['model'] is String ? m['model'] : null,
        texts: m['texts'] is List<dynamic> ? m['texts'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != embeddings) {
      m['embeddings'] = embeddings;
    }
    if (null != model) {
      m['model'] = model;
    }
    if (null != texts) {
      m['texts'] = texts;
    }
    return m;
  }
}

class EphemeralKey {
  /// INTEGER (required at the API)
  int? dailyLimit;
  /// INTEGER (required at the API)
  int? dailyUsed;
  /// STRING (required at the API)
  String? key;
  /// STRING (required at the API)
  String? resetsAt;

  EphemeralKey({
    this.dailyLimit,
    this.dailyUsed,
    this.key,
    this.resetsAt,
  });

  factory EphemeralKey.fromMap(Map<String, dynamic> m) => EphemeralKey(
        dailyLimit: m['dailyLimit'] is int ? m['dailyLimit'] : null,
        dailyUsed: m['dailyUsed'] is int ? m['dailyUsed'] : null,
        key: m['key'] is String ? m['key'] : null,
        resetsAt: m['resetsAt'] is String ? m['resetsAt'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != dailyLimit) {
      m['dailyLimit'] = dailyLimit;
    }
    if (null != dailyUsed) {
      m['dailyUsed'] = dailyUsed;
    }
    if (null != key) {
      m['key'] = key;
    }
    if (null != resetsAt) {
      m['resetsAt'] = resetsAt;
    }
    return m;
  }
}

class EphemeralKeyCreateData {
  /// INTEGER (required at the API)
  int? dailyLimit;
  /// INTEGER (required at the API)
  int? dailyUsed;
  /// STRING (required at the API)
  String? key;
  /// STRING (required at the API)
  String? resetsAt;

  EphemeralKeyCreateData({
    this.dailyLimit,
    this.dailyUsed,
    this.key,
    this.resetsAt,
  });

  factory EphemeralKeyCreateData.fromMap(Map<String, dynamic> m) => EphemeralKeyCreateData(
        dailyLimit: m['dailyLimit'] is int ? m['dailyLimit'] : null,
        dailyUsed: m['dailyUsed'] is int ? m['dailyUsed'] : null,
        key: m['key'] is String ? m['key'] : null,
        resetsAt: m['resetsAt'] is String ? m['resetsAt'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != dailyLimit) {
      m['dailyLimit'] = dailyLimit;
    }
    if (null != dailyUsed) {
      m['dailyUsed'] = dailyUsed;
    }
    if (null != key) {
      m['key'] = key;
    }
    if (null != resetsAt) {
      m['resetsAt'] = resetsAt;
    }
    return m;
  }
}

class Model {
  /// OBJECT
  Map<String, dynamic>? eval;
  /// STRING
  String? executionProvider;
  /// OBJECT
  Map<String, dynamic>? modelCard;
  /// STRING (required at the API)
  String? modelType;
  /// STRING (required at the API)
  String? name;
  /// INTEGER
  int? sequenceLen;
  /// INTEGER
  int? sourceDim;
  /// STRING
  String? sourceModel;
  /// INTEGER (required at the API)
  int? targetDim;
  /// STRING (required at the API)
  String? targetModel;

  Model({
    this.eval,
    this.executionProvider,
    this.modelCard,
    this.modelType,
    this.name,
    this.sequenceLen,
    this.sourceDim,
    this.sourceModel,
    this.targetDim,
    this.targetModel,
  });

  factory Model.fromMap(Map<String, dynamic> m) => Model(
        eval: m['eval'] is Map<String, dynamic> ? m['eval'] : null,
        executionProvider: m['executionProvider'] is String ? m['executionProvider'] : null,
        modelCard: m['modelCard'] is Map<String, dynamic> ? m['modelCard'] : null,
        modelType: m['modelType'] is String ? m['modelType'] : null,
        name: m['name'] is String ? m['name'] : null,
        sequenceLen: m['sequenceLen'] is int ? m['sequenceLen'] : null,
        sourceDim: m['sourceDim'] is int ? m['sourceDim'] : null,
        sourceModel: m['sourceModel'] is String ? m['sourceModel'] : null,
        targetDim: m['targetDim'] is int ? m['targetDim'] : null,
        targetModel: m['targetModel'] is String ? m['targetModel'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != eval) {
      m['eval'] = eval;
    }
    if (null != executionProvider) {
      m['executionProvider'] = executionProvider;
    }
    if (null != modelCard) {
      m['modelCard'] = modelCard;
    }
    if (null != modelType) {
      m['modelType'] = modelType;
    }
    if (null != name) {
      m['name'] = name;
    }
    if (null != sequenceLen) {
      m['sequenceLen'] = sequenceLen;
    }
    if (null != sourceDim) {
      m['sourceDim'] = sourceDim;
    }
    if (null != sourceModel) {
      m['sourceModel'] = sourceModel;
    }
    if (null != targetDim) {
      m['targetDim'] = targetDim;
    }
    if (null != targetModel) {
      m['targetModel'] = targetModel;
    }
    return m;
  }
}

class ModelListMatch {
  /// OBJECT
  Map<String, dynamic>? eval;
  /// STRING
  String? executionProvider;
  /// OBJECT
  Map<String, dynamic>? modelCard;
  /// STRING
  String? modelType;
  /// STRING
  String? name;
  /// INTEGER
  int? sequenceLen;
  /// INTEGER
  int? sourceDim;
  /// STRING
  String? sourceModel;
  /// INTEGER
  int? targetDim;
  /// STRING
  String? targetModel;

  ModelListMatch({
    this.eval,
    this.executionProvider,
    this.modelCard,
    this.modelType,
    this.name,
    this.sequenceLen,
    this.sourceDim,
    this.sourceModel,
    this.targetDim,
    this.targetModel,
  });

  factory ModelListMatch.fromMap(Map<String, dynamic> m) => ModelListMatch(
        eval: m['eval'] is Map<String, dynamic> ? m['eval'] : null,
        executionProvider: m['executionProvider'] is String ? m['executionProvider'] : null,
        modelCard: m['modelCard'] is Map<String, dynamic> ? m['modelCard'] : null,
        modelType: m['modelType'] is String ? m['modelType'] : null,
        name: m['name'] is String ? m['name'] : null,
        sequenceLen: m['sequenceLen'] is int ? m['sequenceLen'] : null,
        sourceDim: m['sourceDim'] is int ? m['sourceDim'] : null,
        sourceModel: m['sourceModel'] is String ? m['sourceModel'] : null,
        targetDim: m['targetDim'] is int ? m['targetDim'] : null,
        targetModel: m['targetModel'] is String ? m['targetModel'] : null,
      );

  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (null != eval) {
      m['eval'] = eval;
    }
    if (null != executionProvider) {
      m['executionProvider'] = executionProvider;
    }
    if (null != modelCard) {
      m['modelCard'] = modelCard;
    }
    if (null != modelType) {
      m['modelType'] = modelType;
    }
    if (null != name) {
      m['name'] = name;
    }
    if (null != sequenceLen) {
      m['sequenceLen'] = sequenceLen;
    }
    if (null != sourceDim) {
      m['sourceDim'] = sourceDim;
    }
    if (null != sourceModel) {
      m['sourceModel'] = sourceModel;
    }
    if (null != targetDim) {
      m['targetDim'] = targetDim;
    }
    if (null != targetModel) {
      m['targetModel'] = targetModel;
    }
    return m;
  }
}

