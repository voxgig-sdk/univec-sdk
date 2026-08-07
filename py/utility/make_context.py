# Univec SDK utility: make_context

from core.context import UnivecContext


def make_context_util(ctxmap, basectx):
    return UnivecContext(ctxmap, basectx)
