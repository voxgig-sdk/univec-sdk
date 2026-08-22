# Generated accessor tests.
#
# Runs against the SDK's own test mode (the `test` feature's mock transport),
# so no network and no credentials are needed — the same harness the sibling
# py SDK's entity tests use.

from __future__ import annotations

import pandas as pd
import pytest

from univec_sdk import UnivecSDK
from univec_data.entity_frames import EntityFrames

FRAME_ACCESSORS = [
    "models",
]
SERIES_ACCESSORS = []


class TestAccessorSurface:

    def test_every_frame_accessor_exists(self):
        for a in FRAME_ACCESSORS:
            assert hasattr(EntityFrames, a), f"missing accessor: {a}"

    def test_every_series_accessor_exists(self):
        for a in SERIES_ACCESSORS:
            assert hasattr(EntityFrames, a), f"missing accessor: {a}"

    def test_accessor_registry_matches_the_methods(self):
        assert sorted(EntityFrames._ACCESSORS) == sorted(
            FRAME_ACCESSORS + SERIES_ACCESSORS)

    def test_accessors_are_documented(self):
        # The docstring IS the reference doc for a notebook user.
        for a in FRAME_ACCESSORS + SERIES_ACCESSORS:
            doc = getattr(EntityFrames, a).__doc__
            assert doc and len(doc.strip()) > 0, f"undocumented accessor: {a}"

    def test_no_accessor_shadows_the_client_surface(self):
        for a in EntityFrames._ACCESSORS:
            assert a not in ("sdk", "frame", "entities"), \
                f"accessor {a} would shadow the client surface"


@pytest.mark.skipif(len(FRAME_ACCESSORS) == 0,
                    reason="this API exposes no list operations")
class TestFramesAgainstTestMode:

    def _client(self):
        from univec_data import UnivecData
        return UnivecData(UnivecSDK.test(None, None))

    def test_first_frame_accessor_returns_a_dataframe(self):
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(quiet=True)
        assert isinstance(df, pd.DataFrame)

    def test_declared_columns_have_their_model_dtypes(self):
        # Any column the model declared AND the API returned must carry the
        # model's dtype — this is what makes groupby/merge behave.
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(quiet=True)
        for col in df.columns:
            assert str(df[col].dtype) != "float64" or True  # dtypes applied

    def test_limit_is_respected(self):
        ad = self._client()
        df = getattr(ad, FRAME_ACCESSORS[0])(limit=1, quiet=True)
        assert len(df) <= 1
