<?php
declare(strict_types=1);

// Typed models for the Univec SDK.
//
// GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
// params (op.<name>.points[].args.params[]). Field/param types come from the
// canonical type sentinels via @voxgig/sdkgen canonToType (source of truth:
// @voxgig/apidef VALID_CANON). Do not edit by hand.
//
// These are documentation-grade value objects (PHP 8 typed properties),
// registered on the composer classmap autoload. The SDK boundary exchanges
// assoc-arrays; these classes name the shapes for tooling and typed callers.

/** Convert entity data model. */
class Convert
{
    public array $embeddings;
    public string $source_model;
    public string $target_model;
}

/** Request payload for Convert#create. */
class ConvertCreateData
{
    public array $embeddings;
    public string $source_model;
    public string $target_model;
}

/** Embed entity data model. */
class Embed
{
    public array $embeddings;
    public string $model;
    public array $texts;
}

/** Request payload for Embed#create. */
class EmbedCreateData
{
    public array $embeddings;
    public string $model;
    public array $texts;
}

/** EphemeralKey entity data model. */
class EphemeralKey
{
    public int $dailyLimit;
    public int $dailyUsed;
    public string $key;
    public string $resetsAt;
}

/** Request payload for EphemeralKey#create. */
class EphemeralKeyCreateData
{
    public int $dailyLimit;
    public int $dailyUsed;
    public string $key;
    public string $resetsAt;
}

/** Model entity data model. */
class Model
{
    public ?array $eval = null;
    public ?string $executionProvider = null;
    public ?array $modelCard = null;
    public string $modelType;
    public string $name;
    public ?int $sequenceLen = null;
    public ?int $sourceDim = null;
    public ?string $sourceModel = null;
    public int $targetDim;
    public string $targetModel;
}

/** Request payload for Model#list. */
class ModelListMatch
{
    public ?array $eval = null;
    public ?string $executionProvider = null;
    public ?array $modelCard = null;
    public ?string $modelType = null;
    public ?string $name = null;
    public ?int $sequenceLen = null;
    public ?int $sourceDim = null;
    public ?string $sourceModel = null;
    public ?int $targetDim = null;
    public ?string $targetModel = null;
}

