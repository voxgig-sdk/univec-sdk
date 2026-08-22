# py-data features

The py-data target does not generate per-feature source. Features are
applied to the sibling Python SDK by the `py` target; this package
consumes that SDK as a single dependency and reads the state its
features publish (notably `paging`, whose recorded cursor drives the
eager fetch in `fetch.py`). This file exists only to satisfy the
standard `tm/<target>/src/feature/` folder convention.
