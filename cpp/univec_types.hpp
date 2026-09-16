// Typed reference models for the Univec SDK (C++).
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params. The C++ SDK runtime is Value-based, so these structs are
// DOCUMENTATION / convenience types only — the SDK neither includes nor
// requires this header. Array fields surface as std::vector<Value>, object
// fields as std::map<std::string, Value>, and any/null fields as sdk::Value.
// Optional (req:false) members are flagged with a trailing "// optional"
// comment. Do not edit by hand.

#ifndef SDK_UNIVEC_TYPES_HPP
#define SDK_UNIVEC_TYPES_HPP

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "core/types.hpp"

namespace sdk {
namespace types {

struct Convert {
  std::vector<Value> embeddings;
  std::string source_model;
  std::string target_model;
};

struct ConvertCreateData {
  std::vector<Value> embeddings;
  std::string source_model;
  std::string target_model;
};

struct Embed {
  std::vector<Value> embeddings;
  std::string model;
  std::vector<Value> texts;
};

struct EmbedCreateData {
  std::vector<Value> embeddings;
  std::string model;
  std::vector<Value> texts;
};

struct EphemeralKey {
  int64_t dailyLimit;
  int64_t dailyUsed;
  std::string key;
  std::string resetsAt;
};

struct EphemeralKeyCreateData {
  int64_t dailyLimit;
  int64_t dailyUsed;
  std::string key;
  std::string resetsAt;
};

struct Model {
  std::map<std::string, Value> eval;  // optional
  std::string executionProvider;  // optional
  std::map<std::string, Value> modelCard;  // optional
  std::string modelType;
  std::string name;
  int64_t sequenceLen;  // optional
  int64_t sourceDim;  // optional
  std::string sourceModel;  // optional
  int64_t targetDim;
  std::string targetModel;
};

struct ModelListMatch {
  std::map<std::string, Value> eval;  // optional
  std::string executionProvider;  // optional
  std::map<std::string, Value> modelCard;  // optional
  std::string modelType;  // optional
  std::string name;  // optional
  int64_t sequenceLen;  // optional
  int64_t sourceDim;  // optional
  std::string sourceModel;  // optional
  int64_t targetDim;  // optional
  std::string targetModel;  // optional
};

} // namespace types
} // namespace sdk

#endif // SDK_UNIVEC_TYPES_HPP
