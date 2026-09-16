# Typed models for the Univec SDK.
#
# GENERATED from the API model: main.kit.entity.<e>.fields[] and per-op
# params (op.<name>.points[].args.params[]). Member types come from the
# canonical type sentinels. The SDK carries data as string-keyed struct value
# nodes, so each alias is an open string-keyed map; the @typedoc member lists
# document the concrete shapes. Do not edit by hand.

defmodule Univec.Types do
  @moduledoc """
  Documented shapes for the Univec SDK entities and operation payloads.

  Every alias resolves to an open string-keyed map because the SDK carries
  data as string-keyed struct value nodes; consult each type's member list for
  the concrete field/param types.
  """

  @typedoc """
  Convert entity data model.

  Members:
    * `"embeddings"` — list() (required)
    * `"source_model"` — String.t() (required)
    * `"target_model"` — String.t() (required)
  """
  @type convert :: %{optional(String.t()) => any()}

  @typedoc """
  Request payload for Convert create.

  Members:
    * `"embeddings"` — list() (required)
    * `"source_model"` — String.t() (required)
    * `"target_model"` — String.t() (required)
  """
  @type convert_create_data :: %{optional(String.t()) => any()}

  @typedoc """
  Embed entity data model.

  Members:
    * `"embeddings"` — list() (required)
    * `"model"` — String.t() (required)
    * `"texts"` — list() (required)
  """
  @type embed :: %{optional(String.t()) => any()}

  @typedoc """
  Request payload for Embed create.

  Members:
    * `"embeddings"` — list() (required)
    * `"model"` — String.t() (required)
    * `"texts"` — list() (required)
  """
  @type embed_create_data :: %{optional(String.t()) => any()}

  @typedoc """
  EphemeralKey entity data model.

  Members:
    * `"dailyLimit"` — integer() (required)
    * `"dailyUsed"` — integer() (required)
    * `"key"` — String.t() (required)
    * `"resetsAt"` — String.t() (required)
  """
  @type ephemeral_key :: %{optional(String.t()) => any()}

  @typedoc """
  Request payload for EphemeralKey create.

  Members:
    * `"dailyLimit"` — integer() (required)
    * `"dailyUsed"` — integer() (required)
    * `"key"` — String.t() (required)
    * `"resetsAt"` — String.t() (required)
  """
  @type ephemeral_key_create_data :: %{optional(String.t()) => any()}

  @typedoc """
  Model entity data model.

  Members:
    * `"eval"` — map() (optional)
    * `"executionProvider"` — String.t() (optional)
    * `"modelCard"` — map() (optional)
    * `"modelType"` — String.t() (required)
    * `"name"` — String.t() (required)
    * `"sequenceLen"` — integer() (optional)
    * `"sourceDim"` — integer() (optional)
    * `"sourceModel"` — String.t() (optional)
    * `"targetDim"` — integer() (required)
    * `"targetModel"` — String.t() (required)
  """
  @type model :: %{optional(String.t()) => any()}

  @typedoc """
  Request payload for Model list.

  Members:
    * `"eval"` — map() (optional)
    * `"executionProvider"` — String.t() (optional)
    * `"modelCard"` — map() (optional)
    * `"modelType"` — String.t() (optional)
    * `"name"` — String.t() (optional)
    * `"sequenceLen"` — integer() (optional)
    * `"sourceDim"` — integer() (optional)
    * `"sourceModel"` — String.t() (optional)
    * `"targetDim"` — integer() (optional)
    * `"targetModel"` — String.t() (optional)
  """
  @type model_list_match :: %{optional(String.t()) => any()}

end
