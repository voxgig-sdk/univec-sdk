# Univec SDK feature factory

from univec_sdk.feature.base_feature import UnivecBaseFeature
from univec_sdk.feature.audit_feature import UnivecAuditFeature
from univec_sdk.feature.cache_feature import UnivecCacheFeature
from univec_sdk.feature.clienttrack_feature import UnivecClienttrackFeature
from univec_sdk.feature.cost_feature import UnivecCostFeature
from univec_sdk.feature.debug_feature import UnivecDebugFeature
from univec_sdk.feature.idempotency_feature import UnivecIdempotencyFeature
from univec_sdk.feature.log_feature import UnivecLogFeature
from univec_sdk.feature.metrics_feature import UnivecMetricsFeature
from univec_sdk.feature.netsim_feature import UnivecNetsimFeature
from univec_sdk.feature.paging_feature import UnivecPagingFeature
from univec_sdk.feature.proxy_feature import UnivecProxyFeature
from univec_sdk.feature.ratelimit_feature import UnivecRatelimitFeature
from univec_sdk.feature.rbac_feature import UnivecRbacFeature
from univec_sdk.feature.retry_feature import UnivecRetryFeature
from univec_sdk.feature.secrets_feature import UnivecSecretsFeature
from univec_sdk.feature.streaming_feature import UnivecStreamingFeature
from univec_sdk.feature.telemetry_feature import UnivecTelemetryFeature
from univec_sdk.feature.test_feature import UnivecTestFeature
from univec_sdk.feature.timeout_feature import UnivecTimeoutFeature


_FEATURES = {
    "base": lambda: UnivecBaseFeature(),
    "audit": lambda: UnivecAuditFeature(),
    "cache": lambda: UnivecCacheFeature(),
    "clienttrack": lambda: UnivecClienttrackFeature(),
    "cost": lambda: UnivecCostFeature(),
    "debug": lambda: UnivecDebugFeature(),
    "idempotency": lambda: UnivecIdempotencyFeature(),
    "log": lambda: UnivecLogFeature(),
    "metrics": lambda: UnivecMetricsFeature(),
    "netsim": lambda: UnivecNetsimFeature(),
    "paging": lambda: UnivecPagingFeature(),
    "proxy": lambda: UnivecProxyFeature(),
    "ratelimit": lambda: UnivecRatelimitFeature(),
    "rbac": lambda: UnivecRbacFeature(),
    "retry": lambda: UnivecRetryFeature(),
    "secrets": lambda: UnivecSecretsFeature(),
    "streaming": lambda: UnivecStreamingFeature(),
    "telemetry": lambda: UnivecTelemetryFeature(),
    "test": lambda: UnivecTestFeature(),
    "timeout": lambda: UnivecTimeoutFeature(),
}


def _make_feature(name):
    factory = _FEATURES.get(name)
    if factory is not None:
        return factory()
    return _FEATURES["base"]()


# True when this SDK was generated with the named feature class - the
# constructor's tolerance for extend-carried features reads this (an
# active name with no generated class must not become a BaseFeature
# stray when an extend instance carries it).
def _has_feature(name):
    return name in _FEATURES
