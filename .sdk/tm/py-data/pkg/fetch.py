# Univec Data — eager paging drain.
#
# Analysts want the whole table now. Lazy iterators are application
# ergonomics: correct for a service processing a stream, wrong for someone
# who typed `df = ad.things()` and wants to run a groupby on the next line.
#
# This module owns NO pagination knowledge. The sibling SDK's `paging`
# feature already normalises every server dialect it understands — a
# `Link: rel="next"` header, X-Page / X-Next-Page / X-Total-Count, or body
# `next` / `cursor` / `nextCursor` / `hasMore` — onto `result.paging`, and
# records the last one on the client. All we do is drive it to exhaustion by
# feeding the cursor/page back in through the per-call `ctrl.paging` hook,
# which exists for exactly this purpose.

from __future__ import annotations

import sys
from typing import Any, Callable


# Safety backstop. A server that always reports "more" (or a cursor that
# never advances) would otherwise loop forever inside a notebook cell with
# no output. Hitting this is always reported, never silent.
MAX_PAGES_DEFAULT = 1000


def in_notebook() -> bool:
    """True when running under IPython/Jupyter/Colab with a display."""
    try:
        from IPython import get_ipython  # type: ignore
    except Exception:
        return False
    ip = get_ipython()
    if ip is None:
        return False
    return hasattr(ip, "kernel")


def _progress(count: int, pages: int, quiet: bool) -> None:
    if quiet:
        return
    # Deliberately not tqdm: an extra hard dependency for a progress bar is a
    # bad trade in an environment that reinstalls every dependency on every
    # session start. A rewritten stderr line costs nothing and works in both
    # notebooks and plain terminals.
    sys.stderr.write(f"\r  fetched {count} rows ({pages} pages)…")
    sys.stderr.flush()


def _progress_done(count: int, pages: int, quiet: bool) -> None:
    if quiet:
        return
    sys.stderr.write(f"\r  fetched {count} rows ({pages} pages)   \n")
    sys.stderr.flush()


def drain(
    call: Callable[[dict], Any],
    client: Any,
    *,
    limit: int | None = None,
    max_pages: int = MAX_PAGES_DEFAULT,
    quiet: bool = False,
    progress_after: int = 1,
) -> list:
    """Call `call(ctrl)` until the server stops offering more.

    call        — invoked with a ctrl dict; returns one page of records
    client      — the SDK client, read for `_paging` (set by the paging feature)
    limit       — stop once this many rows are collected (None = all)
    max_pages   — backstop; a warning is emitted if it is reached
    quiet       — suppress progress output
    progress_after — only show progress once this many pages have been fetched,
                  so the common single-page case prints nothing at all

    Returns the accumulated records.

    When the SDK's paging feature is INACTIVE there is no `_paging` state, so
    this makes exactly one call and returns it — the correct degradation, not
    an error. An SDK without paging configured genuinely has one page.
    """
    rows: list = []
    ctrl: dict = {}
    pages = 0
    seen_cursors: set = set()
    hit_max = False

    while True:
        page = call(ctrl)
        pages += 1

        if page is None:
            batch = []
        elif isinstance(page, (list, tuple)):
            batch = list(page)
        else:
            batch = [page]

        rows.extend(batch)

        if pages >= progress_after + 1:
            _progress(len(rows), pages, quiet)

        if limit is not None and len(rows) >= limit:
            rows = rows[:limit]
            break

        paging = _last_paging(client)
        if not paging or not paging.get("hasMore"):
            break

        # An empty page that still claims more would spin forever.
        if len(batch) == 0:
            break

        nxt = _next_ctrl(paging)
        if nxt is None:
            break

        # A cursor that repeats means the server is not advancing. Stopping
        # beats looping: the analyst gets the rows fetched so far, plus a
        # warning, instead of a hung cell.
        token = repr(sorted(nxt.get("paging", {}).items()))
        if token in seen_cursors:
            _warn("pagination stopped advancing (repeated cursor) — "
                  f"returning the {len(rows)} rows fetched so far")
            break
        seen_cursors.add(token)

        if pages >= max_pages:
            hit_max = True
            break

        ctrl = nxt

    if pages >= progress_after + 1:
        _progress_done(len(rows), pages, quiet)

    if hit_max:
        _warn(f"stopped at max_pages={max_pages} with {len(rows)} rows; the "
              "server still reported more. Pass max_pages= to raise the cap, "
              "or limit= to take a defined slice.")

    return rows


def _last_paging(client: Any) -> dict | None:
    """The paging state the SDK's paging feature recorded on the client."""
    state = getattr(client, "_paging", None)
    if not isinstance(state, dict):
        return None
    last = state.get("last")
    return last if isinstance(last, dict) else None


def _next_ctrl(paging: dict) -> dict | None:
    """Build the ctrl for the next page from the recorded paging state.

    Cursor wins over page number: when a server offers both, the cursor is
    the one with consistency guarantees.
    """
    cursor = paging.get("cursor")
    if cursor is not None:
        return {"paging": {"cursor": cursor}}

    next_page = paging.get("nextPage")
    if next_page is not None:
        return {"paging": {"page": next_page}}

    # A `Link: rel="next"` URL with no cursor/page extracted is not something
    # we can turn into a ctrl — the SDK builds its own request URLs. Rather
    # than guess at query parsing, stop and keep what we have.
    return None


def _warn(msg: str) -> None:
    import warnings
    warnings.warn(f"Univec data: {msg}", stacklevel=3)
