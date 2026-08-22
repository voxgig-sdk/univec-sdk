# Univec Data — records to DataFrame.
#
# The one genuinely new runtime component in this package. Everything else
# either delegates to the sibling Univec SDK or is generated.
#
# Pipeline, per accessor call:
#   1. normalise  — SDK dataclasses / dicts / scalars -> plain dicts
#   2. flatten    — one level of nesting -> dotted columns (json_normalize)
#   3. dtype      — model-declared nullable pandas dtypes, coerced safely
#   4. order      — model field order first, extras appended
#
# Step 3 uses NULLABLE dtypes ('Int64', not 'int64') throughout. See the
# PANDAS_DTYPE note in sdkgen's canonType.ts: API payloads omit optional
# fields freely, so a column that looks integral in one page can arrive with
# nulls in the next. NumPy's int64/bool cannot hold NA and would silently
# upcast to float64/object mid-fetch, making a column's dtype depend on which
# rows happened to come back.

from __future__ import annotations

import dataclasses
from typing import Any, Iterable

import pandas as pd


# Flatten depth accepted by the accessors: 1 (default, one level), 0/"none"
# (no flattening), or "full" (recursive).
FLATTEN_DEFAULT = 1


def to_record(item: Any) -> Any:
    """One SDK result item -> a plain dict (or the value itself if scalar).

    The ops are NOT symmetric, and this is the load-bearing detail:

      * `list()` yields ENTITY OBJECTS (UnivecXEntity), whose record is
        held privately and read through the public `data_get()`.
      * `load()` / `create()` yield a plain dict.

    So an entity is unwrapped via `data_get()` before anything else. An
    earlier version fell through to the `__dict__` branch, which filters
    underscore-prefixed attributes and therefore returned `{}` for every
    row — a frame with the right number of rows and NO columns.
    """
    if item is None:
        return None

    # SDK entity object: read the record through its public accessor rather
    # than reaching into `_data`, so feature hooks (GetData) still fire.
    getter = getattr(item, "data_get", None)
    if callable(getter):
        try:
            rec = getter()
            if isinstance(rec, dict):
                return rec
        except Exception:
            pass

    if dataclasses.is_dataclass(item) and not isinstance(item, type):
        # asdict() recurses into nested dataclasses, which is what we want:
        # flattening below then decides how deep to expose them as columns.
        return dataclasses.asdict(item)
    if isinstance(item, dict):
        return item
    # Objects with a __dict__ (defensive: a hand-written entity, a namespace).
    d = getattr(item, "__dict__", None)
    if isinstance(d, dict):
        return {k: v for k, v in d.items() if not k.startswith("_")}
    return item


def to_records(items: Any) -> list:
    """An op result -> a list of plain records.

    A `list` op yields a list; a `load`/`create` op yields one record. Both
    are accepted so the same engine serves frame and series accessors.
    """
    if items is None:
        return []
    if isinstance(items, dict):
        return [to_record(items)]
    if isinstance(items, (list, tuple)):
        return [to_record(i) for i in items]
    if isinstance(items, Iterable) and not isinstance(items, (str, bytes)):
        return [to_record(i) for i in items]
    return [to_record(items)]


def _max_level(flatten: Any) -> Any:
    """Accessor `flatten=` kwarg -> json_normalize max_level.

    1 (default) is deliberate. Full recursive flattening turns a deeply
    nested payload into an unusable 400-column frame; one level gives the
    dotted columns people actually group by ('model_card.author') and leaves
    genuinely deep structures boxed in object columns, still reachable with
    normal pandas.
    """
    if flatten is None or flatten is False or flatten == 0 or flatten == "none":
        return 0
    if flatten is True or flatten == "full":
        return None  # json_normalize: no limit
    if isinstance(flatten, int):
        return flatten
    return FLATTEN_DEFAULT


def build_frame(
    items: Any,
    *,
    dtypes: dict | None = None,
    order: list | None = None,
    flatten: Any = FLATTEN_DEFAULT,
    dtype: bool = True,
    parse_dates: Any = None,
) -> pd.DataFrame:
    """Records -> DataFrame, typed and ordered from the entity model.

    dtypes / order are supplied by the generated accessor from the model's
    field list; callers passing raw records (records_df) get neither, which
    is fine — pandas' own inference then applies.
    """
    records = to_records(items)

    if len(records) == 0:
        # An empty result still returns the RIGHT columns with the RIGHT
        # dtypes, so downstream code (df.empty checks, concat, groupby on a
        # known column) behaves identically to a populated frame. A bare
        # pd.DataFrame() would raise KeyError on the first column access.
        cols = list(order or [])
        empty = pd.DataFrame({c: pd.Series(dtype=(dtypes or {}).get(c, "object"))
                              for c in cols})
        return empty

    # Scalars (a list op returning bare strings) -> a single 'value' column.
    if not isinstance(records[0], dict):
        return pd.DataFrame({"value": records})

    max_level = _max_level(flatten)
    if max_level == 0:
        df = pd.DataFrame(records)
    else:
        df = pd.json_normalize(records, sep=".", max_level=max_level)

    if dtype and dtypes:
        df = apply_dtypes(df, dtypes)

    if parse_dates:
        df = apply_dates(df, parse_dates)

    if order:
        df = order_columns(df, order)

    return df


def apply_dtypes(df: pd.DataFrame, dtypes: dict) -> pd.DataFrame:
    """Coerce declared columns to their model dtype, one column at a time.

    Per-column rather than a single df.astype(): one unconvertible column
    must not fail the whole frame. A column that will not convert is LEFT AS
    IS — an analyst with a usable frame and one object column is far better
    served than one holding an exception. The API is the authority on its own
    data; our model is a hint.
    """
    for col, want in dtypes.items():
        if col not in df.columns:
            continue
        if str(df[col].dtype) == want:
            continue
        try:
            df[col] = df[col].astype(want)
        except (TypeError, ValueError):
            # Numeric rescue: an API that sends "42" for an integer field is
            # common enough to be worth handling.
            #
            # But to_numeric(errors="coerce") turns anything it cannot parse
            # into NA, which would DESTROY a genuinely non-numeric column
            # while appearing to succeed. So the rescue is only accepted when
            # it is lossless: every value that was non-null before must still
            # be non-null after. Otherwise the column is left exactly as it
            # came from the API.
            if want in ("Int64", "Float64"):
                coerced = pd.to_numeric(df[col], errors="coerce")
                lost = coerced.isna() & df[col].notna()
                if not lost.any():
                    try:
                        df[col] = coerced.astype(want)
                    except (TypeError, ValueError):
                        pass
    return df


def apply_dates(df: pd.DataFrame, parse_dates: Any) -> pd.DataFrame:
    """Parse the named columns as UTC datetimes.

    EXPLICIT opt-in, never inferred. The model carries no string formats —
    apidef has no $DATE sentinel — so guessing which string columns are dates
    would be a heuristic on column names, and a wrong guess mangles data
    silently. `errors="coerce"` turns unparseable values into NaT rather than
    raising, keeping the frame usable.
    """
    cols = [parse_dates] if isinstance(parse_dates, str) else list(parse_dates)
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col], errors="coerce", utc=True)
    return df


def order_columns(df: pd.DataFrame, order: list) -> pd.DataFrame:
    """Model-declared column order first, everything else appended as-is.

    Stable column order across calls beats alphabetical: an analyst's
    df.iloc[:, :5] should mean the same thing on Monday and Tuesday, and the
    model lists required fields first.
    """
    known = [c for c in order if c in df.columns]
    extra = [c for c in df.columns if c not in known]
    return df[known + extra]


def records_df(items: Any, **kwargs) -> pd.DataFrame:
    """Shape ANY op result into a DataFrame.

    The public escape hatch for endpoints without a generated accessor —
    action ops, non-entity endpoints, or a raw call made through `.sdk`.
    """
    return build_frame(items, **kwargs)


def to_series(item: Any, **kwargs) -> pd.Series:
    """One record -> a Series (the natural shape for a single `load`)."""
    df = build_frame(item, **kwargs)
    if len(df) == 0:
        return pd.Series(dtype="object")
    return df.iloc[0]
