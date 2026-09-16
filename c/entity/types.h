// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types are mapped
// from the canonical type sentinels. Do not edit by hand.
//
// These are DOCUMENTARY: the SDK runtime is dynamic (ops take/return
// `voxgig_value*`), so nothing consumes these structs yet — they mirror the
// entity/op shapes for reference and IDE support. This header is standalone
// and is not #included by any generated .c.

#ifndef UNIVEC_ENTITY_TYPES_H
#define UNIVEC_ENTITY_TYPES_H

#include "sdk.h"

// Convert is the typed data model for the convert entity.
typedef struct {
  voxgig_value*embeddings;
  char*source_model;
  char*target_model;
} Convert;

// ConvertCreateData is the typed request payload for Convert.create.
typedef struct {
  voxgig_value*embeddings;
  char*source_model;
  char*target_model;
} ConvertCreateData;

// Embed is the typed data model for the embed entity.
typedef struct {
  voxgig_value*embeddings;
  char*model;
  voxgig_value*texts;
} Embed;

// EmbedCreateData is the typed request payload for Embed.create.
typedef struct {
  voxgig_value*embeddings;
  char*model;
  voxgig_value*texts;
} EmbedCreateData;

// EphemeralKey is the typed data model for the ephemeral_key entity.
typedef struct {
  int64_t dailylimit;
  int64_t dailyused;
  char*key;
  char*resetsat;
} EphemeralKey;

// EphemeralKeyCreateData is the typed request payload for EphemeralKey.create.
typedef struct {
  int64_t dailylimit;
  int64_t dailyused;
  char*key;
  char*resetsat;
} EphemeralKeyCreateData;

// Model is the typed data model for the model entity.
typedef struct {
  voxgig_value*eval;  // optional
  char*executionprovider;  // optional
  voxgig_value*modelcard;  // optional
  char*modeltype;
  char*name;
  int64_t sequencelen;  // optional
  int64_t sourcedim;  // optional
  char*sourcemodel;  // optional
  int64_t targetdim;
  char*targetmodel;
} Model;

// ModelListMatch is the typed request payload for Model.list.
typedef struct {
  voxgig_value*eval;  // optional
  char*executionprovider;  // optional
  voxgig_value*modelcard;  // optional
  char*modeltype;  // optional
  char*name;  // optional
  int64_t sequencelen;  // optional
  int64_t sourcedim;  // optional
  char*sourcemodel;  // optional
  int64_t targetdim;  // optional
  char*targetmodel;  // optional
} ModelListMatch;

#endif // UNIVEC_ENTITY_TYPES_H
