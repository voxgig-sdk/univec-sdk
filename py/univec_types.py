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
    bridge_model: str
    data: dict
    embedding: list
    source_model: str
    success: bool
    target_model: str
    text: list


class ConvertCreateData(TypedDict):
    bridge_model: str
    data: dict
    embedding: list
    source_model: str
    success: bool
    target_model: str
    text: list


class Embed(TypedDict):
    data: dict
    model: str
    success: bool
    text: list


class EmbedCreateData(TypedDict):
    data: dict
    model: str
    success: bool
    text: list


class EphemeralKey(TypedDict):
    data: dict
    success: bool


class EphemeralKeyCreateData(TypedDict):
    data: dict
    success: bool


class ModelRequired(TypedDict):
    model_type: str
    name: str
    target_dim: int
    target_model: str


class Model(ModelRequired, total=False):
    eval: dict
    execution_provider: str
    model_card: dict
    sequence_len: int
    source_dim: int
    source_model: str


class ModelListMatch(TypedDict, total=False):
    eval: dict
    execution_provider: str
    model_card: dict
    model_type: str
    name: str
    sequence_len: int
    source_dim: int
    source_model: str
    target_dim: int
    target_model: str
