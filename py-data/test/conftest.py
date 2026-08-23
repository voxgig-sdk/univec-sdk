# Make the suite runnable with a bare `make test`, the way every other
# target's is.
#
# py-data is the one target that CONSUMES a sibling: its package imports the
# Univec SDK generated into ../py of the same repo. The Makefile's `dev`
# target pip-installs both editable, but `test` does not depend on it, so
# `make test` on a fresh clone died in collection with
# "ModuleNotFoundError: No module named 'univec_sdk'" — before a single
# assertion ran.
#
# Requiring an install step would also make this target the only one that
# cannot be tested from a clean checkout. Putting the two source roots on
# sys.path keeps it self-contained; an installed copy still wins, because
# these entries are appended only when the import is not already satisfiable.
from __future__ import annotations

import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
for _root in (_here.parent, _here.parent.parent / "py"):
    _p = str(_root)
    if _root.is_dir() and _p not in sys.path:
        sys.path.insert(0, _p)
