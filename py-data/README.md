# Univec Data

UniVec as **pandas DataFrames**, for data analysts working in
notebooks. Built on the sibling [Python SDK](../py) in this repo.

```python
# Not yet on PyPI — install both packages from this repo:
!pip install "git+https://github.com/voxgig-sdk/univec-sdk#subdirectory=py" \
             "git+https://github.com/voxgig-sdk/univec-sdk#subdirectory=py-data"

from univec_data import data

ad = data()
df = ad.models()          # every page, flattened, typed -> DataFrame
df.groupby("modelType").size()
```

No client to construct, no pagination loop to write, no `json_normalize`
boilerplate. Credentials are found automatically (see below).

## Install

This package is not on PyPI yet. Install it and the SDK it wraps straight
from the repo — in a notebook, prefix with `!`:

```sh
pip install "git+https://github.com/voxgig-sdk/univec-sdk#subdirectory=py" \
            "git+https://github.com/voxgig-sdk/univec-sdk#subdirectory=py-data"
```

Released versions are tagged at https://github.com/voxgig-sdk/univec-sdk/releases.

## Credentials

`data()` looks in three places, in order, and stops at the first hit:

1. the `token=` / `base_url=` arguments
2. **Colab secrets** — `UNIVEC_APIKEY`
3. **environment variables** — the same names

In Colab, open the key panel in the left sidebar, add `UNIVEC_APIKEY`, and
switch on notebook access for it. Elsewhere:

```python
import os
os.environ["UNIVEC_APIKEY"] = "your-api-key"
```

## Accessors

| Call | Entity | Returns | Columns |
|---|---|---|---|
| `models()` | `model` | DataFrame | 10 |

Every frame accessor takes the same keyword arguments:

| Argument | Default | Meaning |
|---|---|---|
| `limit` | `None` (all rows) | Stop after this many rows |
| `flatten` | `1` | Nesting depth to expand into dotted columns; `"none"` or `"full"` |
| `dtype` | `True` | Apply the model's dtypes; `False` leaves pandas to infer |
| `parse_dates` | `None` | Column names to parse as UTC datetimes |
| `max_pages` | `1000` | Safety backstop for a server that always reports more |
| `quiet` | `False` | Suppress the progress line |
| `**match` | — | Anything else is passed to the API as a filter |

## Columns

### model

| Column | dtype | Required |
|---|---|---|
| `eval` | `object` |  |
| `executionProvider` | `string` |  |
| `modelCard` | `object` |  |
| `modelType` | `string` | yes |
| `name` | `string` | yes |
| `sequenceLen` | `Int64` |  |
| `sourceDim` | `Int64` |  |
| `sourceModel` | `string` |  |
| `targetDim` | `Int64` | yes |
| `targetModel` | `string` | yes |


## How it works

- **Every page, eagerly.** Analysts want the whole table, not an iterator. The
  SDK's paging feature already normalises `Link: rel="next"`, `X-Next-Page`
  and body-level `cursor`/`hasMore` signals; this package just drives them to
  exhaustion. `limit=` stops early; `max_pages` is a backstop against a
  server that never stops offering more.
- **Nullable dtypes.** Columns use pandas' nullable types (`Int64`, not
  `int64`). Optional fields are omitted freely by APIs, and NumPy's `int64`
  cannot hold a null — it would silently upcast to `float64` partway through a
  fetch, making a column's type depend on which rows came back.
- **One level of flattening.** `{"a": {"b": 1}}` becomes column `a.b`. Full
  recursive flattening turns a deep payload into an unusable 400-column frame,
  so deeper structures stay boxed in object columns.
- **Dates are never guessed.** The API model carries no date formats, so a
  date-looking string stays a string until you ask: `parse_dates=["created"]`.
- **Your data wins.** If a column will not convert to its declared dtype it is
  left as-is rather than raising. A usable frame with one object column beats
  an exception.

## What this package does not do

- **Writes.** Create, update and delete are not exposed. Use `ad.sdk` for
  those — a generated bulk-write path against a live API is a liability, not a
  convenience.
- **Endpoints without a list or load op.** Use `ad.sdk` and shape the result
  with `ad.frame(result)`.

```python
result = ad.sdk.SomeEntity().create({"name": "x"})   # full SDK, unchanged
df = ad.frame(result)                                # shape anything
```

## Generated code

This package is generated from the API model by
[@voxgig/sdkgen](https://github.com/voxgig/sdkgen). Edits to these files are
overwritten on the next regeneration — change the model, not the output.

MIT licensed. Unofficial: not
affiliated with or endorsed by the upstream API provider.
