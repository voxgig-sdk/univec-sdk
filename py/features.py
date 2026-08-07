# Univec SDK feature factory

from feature.base_feature import UnivecBaseFeature
from feature.test_feature import UnivecTestFeature


def _make_feature(name):
    features = {
        "base": lambda: UnivecBaseFeature(),
        "test": lambda: UnivecTestFeature(),
    }
    factory = features.get(name)
    if factory is not None:
        return factory()
    return features["base"]()
