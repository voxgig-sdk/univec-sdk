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
    public string $bridge_model;
    public array $data;
    public array $embedding;
    public string $source_model;
    public bool $success;
    public string $target_model;
    public array $text;
}

/** Request payload for Convert#create. */
class ConvertCreateData
{
    public string $bridge_model;
    public array $data;
    public array $embedding;
    public string $source_model;
    public bool $success;
    public string $target_model;
    public array $text;
}

/** Embed entity data model. */
class Embed
{
    public array $data;
    public string $model;
    public bool $success;
    public array $text;
}

/** Request payload for Embed#create. */
class EmbedCreateData
{
    public array $data;
    public string $model;
    public bool $success;
    public array $text;
}

/** EphemeralKey entity data model. */
class EphemeralKey
{
    public array $data;
    public bool $success;
}

/** Request payload for EphemeralKey#create. */
class EphemeralKeyCreateData
{
    public array $data;
    public bool $success;
}

/** Model entity data model. */
class Model
{
    public ?array $eval = null;
    public ?string $execution_provider = null;
    public ?array $model_card = null;
    public string $model_type;
    public string $name;
    public ?int $sequence_len = null;
    public ?int $source_dim = null;
    public ?string $source_model = null;
    public int $target_dim;
    public string $target_model;
}

/** Request payload for Model#list. */
class ModelListMatch
{
    public ?array $eval = null;
    public ?string $execution_provider = null;
    public ?array $model_card = null;
    public ?string $model_type = null;
    public ?string $name = null;
    public ?int $sequence_len = null;
    public ?int $source_dim = null;
    public ?string $source_model = null;
    public ?int $target_dim = null;
    public ?string $target_model = null;
}

