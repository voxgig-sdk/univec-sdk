# Univec Data — frames engine tests.
#
# These cover the runtime that is the same for every API, so they live in the
# template rather than being generated. The generated per-entity accessor
# tests are in test_entity_frames.py.

from __future__ import annotations

import dataclasses

import pandas as pd
import pytest

from univec_data.frames import (
    build_frame,
    to_record,
    to_records,
    apply_dtypes,
    apply_dates,
    order_columns,
    records_df,
    to_series,
)


@dataclasses.dataclass
class Sample:
    name: str
    count: int
    nested: dict


class FakeEntity:
    """Stands in for a generated Univec<X>Entity.

    The private attributes matter: an entity's record is NOT in its public
    __dict__, so anything relying on attribute scraping returns {} here.
    """

    def __init__(self, rec):
        self._name = "thing"
        self._data = rec
        self._client = object()

    def data_get(self):
        return dict(self._data)


class TestToRecords:

    def test_entity_object_is_unwrapped_via_data_get(self):
        # list() yields entity OBJECTS, not dicts. Missing this produced a
        # frame with the right row count and zero columns.
        rec = to_record(FakeEntity({"id": "earth", "name": "Earth"}))
        assert rec == {"id": "earth", "name": "Earth"}

    def test_entities_build_a_populated_frame(self):
        df = build_frame([
            FakeEntity({"id": "earth", "diameter": 12756}),
            FakeEntity({"id": "mars", "diameter": 6792}),
        ])
        assert df.shape == (2, 2)
        assert list(df["id"]) == ["earth", "mars"]

    def test_entity_wins_over_the_dunder_dict_fallback(self):
        rec = to_record(FakeEntity({"id": "x"}))
        assert "_data" not in rec
        assert rec != {}

    def test_dataclass_becomes_dict(self):
        rec = to_record(Sample(name="a", count=1, nested={"x": 2}))
        assert rec == {"name": "a", "count": 1, "nested": {"x": 2}}

    def test_dict_passes_through(self):
        assert to_record({"a": 1}) == {"a": 1}

    def test_none_is_none(self):
        assert to_record(None) is None

    def test_single_record_is_wrapped(self):
        assert to_records({"a": 1}) == [{"a": 1}]

    def test_none_is_empty(self):
        assert to_records(None) == []

    def test_list_of_dataclasses(self):
        out = to_records([Sample("a", 1, {}), Sample("b", 2, {})])
        assert [r["name"] for r in out] == ["a", "b"]


class TestFlatten:

    def test_one_level_by_default(self):
        df = build_frame([{"a": 1, "b": {"c": 2}}])
        assert "b.c" in df.columns
        assert "b" not in df.columns

    def test_flatten_none_keeps_nesting(self):
        df = build_frame([{"a": 1, "b": {"c": 2}}], flatten="none")
        assert "b" in df.columns
        assert df["b"].iloc[0] == {"c": 2}

    def test_deep_nesting_stays_boxed_at_depth_one(self):
        # The point of the depth-1 default: a deep payload must not explode
        # into hundreds of columns.
        df = build_frame([{"a": {"b": {"c": {"d": 1}}}}])
        assert "a.b" in df.columns
        assert isinstance(df["a.b"].iloc[0], dict)

    def test_flatten_full_recurses(self):
        df = build_frame([{"a": {"b": {"c": 1}}}], flatten="full")
        assert "a.b.c" in df.columns


class TestDtypes:

    def test_nullable_integer_survives_nulls(self):
        # The whole reason for Int64 over int64: a null in an integer column
        # must not silently turn the column into float64.
        df = build_frame(
            [{"n": 1}, {"n": None}, {"n": 3}],
            dtypes={"n": "Int64"},
        )
        assert str(df["n"].dtype) == "Int64"
        assert df["n"].iloc[0] == 1
        assert pd.isna(df["n"].iloc[1])

    def test_nullable_boolean_survives_nulls(self):
        df = build_frame(
            [{"b": True}, {"b": None}],
            dtypes={"b": "boolean"},
        )
        assert str(df["b"].dtype) == "boolean"

    def test_string_dtype_applied(self):
        df = build_frame([{"s": "x"}], dtypes={"s": "string"})
        assert str(df["s"].dtype) == "string"

    def test_numeric_strings_are_rescued(self):
        df = build_frame([{"n": "1"}, {"n": "2"}], dtypes={"n": "Int64"})
        assert str(df["n"].dtype) == "Int64"
        assert df["n"].iloc[1] == 2

    def test_unconvertible_column_is_left_alone_not_raised(self):
        # An analyst with a usable frame and one object column is far better
        # served than one holding an exception.
        df = build_frame([{"n": "not-a-number"}], dtypes={"n": "Int64"})
        assert len(df) == 1
        # And the VALUE must survive. to_numeric(errors="coerce") would have
        # turned it into NA — a silent data loss dressed up as a successful
        # conversion. The rescue is only allowed when it is lossless.
        assert df["n"].iloc[0] == "not-a-number"

    def test_partially_numeric_column_is_not_coerced(self):
        # One bad value must not blank out the rest of the column.
        df = build_frame(
            [{"n": "1"}, {"n": "oops"}, {"n": "3"}],
            dtypes={"n": "Int64"},
        )
        assert list(df["n"]) == ["1", "oops", "3"]

    def test_numeric_rescue_still_applies_when_lossless(self):
        # Nulls are not "lost" data, so a column of numeric strings with a
        # None in it still converts.
        df = build_frame(
            [{"n": "1"}, {"n": None}, {"n": "3"}],
            dtypes={"n": "Int64"},
        )
        assert str(df["n"].dtype) == "Int64"
        assert df["n"].iloc[0] == 1
        assert pd.isna(df["n"].iloc[1])

    def test_missing_declared_column_is_ignored(self):
        df = build_frame([{"a": 1}], dtypes={"absent": "Int64"})
        assert "absent" not in df.columns

    def test_dtype_false_skips_coercion(self):
        df = build_frame([{"n": 1}], dtypes={"n": "string"}, dtype=False)
        assert str(df["n"].dtype) != "string"


class TestOrder:

    def test_declared_order_first_extras_appended(self):
        df = build_frame(
            [{"z": 1, "a": 2, "extra": 3}],
            order=["a", "z"],
        )
        assert list(df.columns) == ["a", "z", "extra"]

    def test_absent_declared_columns_are_skipped(self):
        df = order_columns(pd.DataFrame({"a": [1]}), ["missing", "a"])
        assert list(df.columns) == ["a"]


class TestEmpty:

    def test_empty_result_keeps_columns_and_dtypes(self):
        # A bare pd.DataFrame() would KeyError on the first column access;
        # downstream code must behave the same whether or not rows came back.
        df = build_frame([], order=["a", "b"], dtypes={"a": "Int64", "b": "string"})
        assert list(df.columns) == ["a", "b"]
        assert str(df["a"].dtype) == "Int64"
        assert len(df) == 0
        assert df.empty

    def test_empty_without_model_is_still_a_frame(self):
        df = build_frame([])
        assert isinstance(df, pd.DataFrame)
        assert len(df) == 0


class TestDates:

    def test_parse_dates_is_explicit_and_utc(self):
        df = build_frame([{"when": "2026-01-02T03:04:05Z"}], parse_dates=["when"])
        assert str(df["when"].dtype).startswith("datetime64")
        assert df["when"].iloc[0].year == 2026

    def test_unparseable_date_becomes_nat_not_an_error(self):
        df = build_frame([{"when": "nonsense"}], parse_dates=["when"])
        assert pd.isna(df["when"].iloc[0])

    def test_dates_are_never_inferred(self):
        # No $DATE sentinel exists in the model, so a date-looking string must
        # stay a string unless the caller asks for parsing.
        df = build_frame([{"when": "2026-01-02T03:04:05Z"}])
        assert not str(df["when"].dtype).startswith("datetime64")


class TestScalarsAndSeries:

    def test_scalar_list_becomes_value_column(self):
        df = build_frame(["a", "b"])
        assert list(df.columns) == ["value"]
        assert list(df["value"]) == ["a", "b"]

    def test_to_series_from_one_record(self):
        s = to_series({"a": 1, "b": 2})
        assert isinstance(s, pd.Series)
        assert s["a"] == 1

    def test_to_series_empty(self):
        s = to_series(None)
        assert isinstance(s, pd.Series)
        assert len(s) == 0

    def test_records_df_is_the_public_escape_hatch(self):
        df = records_df([{"a": 1}])
        assert list(df.columns) == ["a"]
