# Univec Data — paging drain tests.
#
# Driven with a fake client rather than the SDK: the drain loop's contract is
# with the paging state the SDK's paging feature publishes on the client
# (`client._paging["last"]`), so a fake that publishes the same shape tests
# the real contract without a network or a generated SDK in the loop.

from __future__ import annotations

import pytest

from univec_data.fetch import drain, _next_ctrl, _last_paging, MAX_PAGES_DEFAULT


class FakeClient:
    """Publishes paging state exactly as the SDK's paging feature does."""

    def __init__(self, pages):
        self.pages = pages
        self.calls = []
        self._paging = None

    def call(self, ctrl):
        self.calls.append(ctrl)
        idx = len(self.calls) - 1
        if idx >= len(self.pages):
            return []
        rows, paging = self.pages[idx]
        self._paging = {"last": paging}
        return rows


def paging(has_more=False, cursor=None, next_page=None):
    return {
        "page": None, "totalCount": None, "nextPage": next_page,
        "next": None, "cursor": cursor, "hasMore": has_more,
    }


class TestDrain:

    def test_single_page_makes_one_call(self):
        c = FakeClient([([{"a": 1}], paging(has_more=False))])
        rows = drain(c.call, c, quiet=True)
        assert rows == [{"a": 1}]
        assert len(c.calls) == 1

    def test_cursor_paging_drains_every_page(self):
        c = FakeClient([
            ([{"a": 1}], paging(has_more=True, cursor="c1")),
            ([{"a": 2}], paging(has_more=True, cursor="c2")),
            ([{"a": 3}], paging(has_more=False)),
        ])
        rows = drain(c.call, c, quiet=True)
        assert [r["a"] for r in rows] == [1, 2, 3]
        assert c.calls[1] == {"paging": {"cursor": "c1"}}
        assert c.calls[2] == {"paging": {"cursor": "c2"}}

    def test_page_number_paging(self):
        c = FakeClient([
            ([{"a": 1}], paging(has_more=True, next_page=2)),
            ([{"a": 2}], paging(has_more=False)),
        ])
        rows = drain(c.call, c, quiet=True)
        assert len(rows) == 2
        assert c.calls[1] == {"paging": {"page": 2}}

    def test_cursor_wins_over_page_number(self):
        # When a server offers both, the cursor is the one with consistency
        # guarantees.
        nxt = _next_ctrl(paging(has_more=True, cursor="c1", next_page=5))
        assert nxt == {"paging": {"cursor": "c1"}}

    def test_limit_truncates_and_stops_early(self):
        c = FakeClient([
            ([{"a": 1}, {"a": 2}], paging(has_more=True, cursor="c1")),
            ([{"a": 3}], paging(has_more=False)),
        ])
        rows = drain(c.call, c, limit=2, quiet=True)
        assert len(rows) == 2
        assert len(c.calls) == 1

    def test_no_paging_state_degrades_to_one_call(self):
        # An SDK with the paging feature inactive genuinely has one page.
        # That is correct degradation, not an error.
        class NoPaging:
            def __init__(self):
                self.n = 0

            def call(self, ctrl):
                self.n += 1
                return [{"a": 1}]

        c = NoPaging()
        rows = drain(c.call, c, quiet=True)
        assert len(rows) == 1
        assert c.n == 1

    def test_empty_page_claiming_more_stops(self):
        c = FakeClient([
            ([], paging(has_more=True, cursor="c1")),
            ([{"a": 1}], paging(has_more=False)),
        ])
        rows = drain(c.call, c, quiet=True)
        assert rows == []
        assert len(c.calls) == 1

    def test_repeated_cursor_stops_and_warns(self):
        # A server that never advances its cursor would otherwise hang the
        # notebook cell forever.
        c = FakeClient([
            ([{"a": 1}], paging(has_more=True, cursor="same")),
            ([{"a": 2}], paging(has_more=True, cursor="same")),
            ([{"a": 3}], paging(has_more=True, cursor="same")),
        ])
        with pytest.warns(UserWarning, match="stopped advancing"):
            rows = drain(c.call, c, quiet=True)
        assert len(rows) == 2

    def test_max_pages_backstop_warns(self):
        pages = [([{"a": i}], paging(has_more=True, cursor=f"c{i}"))
                 for i in range(10)]
        c = FakeClient(pages)
        with pytest.warns(UserWarning, match="max_pages"):
            rows = drain(c.call, c, max_pages=3, quiet=True)
        assert len(rows) == 3

    def test_has_more_without_a_usable_token_stops(self):
        # A Link: rel="next" URL with no cursor/page is not something we can
        # turn into a ctrl; stopping beats guessing at query parsing.
        c = FakeClient([([{"a": 1}], paging(has_more=True))])
        rows = drain(c.call, c, quiet=True)
        assert len(rows) == 1
        assert len(c.calls) == 1


class TestPagingHelpers:

    def test_last_paging_absent(self):
        class Bare:
            pass

        assert _last_paging(Bare()) is None

    def test_last_paging_present(self):
        class C:
            _paging = {"last": {"hasMore": True}}

        assert _last_paging(C()) == {"hasMore": True}

    def test_max_pages_default_is_a_backstop_not_a_limit(self):
        assert MAX_PAGES_DEFAULT >= 1000
