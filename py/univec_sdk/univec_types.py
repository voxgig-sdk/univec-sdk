# Typed models for the Univec SDK.
#
# GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
# params (op.<name>.points[].args.params[]). Field/param types come from the
# canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
# @voxgig/apidef VALID_CANON). Do not edit by hand.
#
# These are TypedDicts, not dataclasses: the SDK ops return/accept plain dicts
# at runtime, and a TypedDict IS a dict shape, so the types match the runtime.
# Optional (req:false) keys are modelled as TypedDict key-optionality
# (total=False), split into a required base + total=False subclass when a type
# has both required and optional keys.

from __future__ import annotations

from typing import TypedDict, Any


class Convert(TypedDict):
    embeddings: list
    source_model: str
    target_model: str


class ConvertCreateData(TypedDict):
    embeddings: list
    source_model: str
    target_model: str


class Embed(TypedDict):
    embeddings: list
    model: str
    texts: list


class EmbedCreateData(TypedDict):
    embeddings: list
    model: str
    texts: list


class EphemeralKey(TypedDict):
    dailyLimit: int
    dailyUsed: int
    key: str
    resetsAt: str


class EphemeralKeyCreateData(TypedDict):
    dailyLimit: int
    dailyUsed: int
    key: str
    resetsAt: str


class ModelRequired(TypedDict):
    modelType: str
    name: str
    targetDim: int
    targetModel: str


class Model(ModelRequired, total=False):
    eval: dict
    executionProvider: str
    modelCard: dict
    sequenceLen: int
    sourceDim: int
    sourceModel: str


class ModelListMatch(TypedDict, total=False):
    eval: dict
    executionProvider: str
    modelCard: dict
    modelType: str
    name: str
    sequenceLen: int
    sourceDim: int
    sourceModel: str
    targetDim: int
    targetModel: str
