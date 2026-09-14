<?php
declare(strict_types=1);

// Univec SDK feature factory

require_once __DIR__ . '/feature/BaseFeature.php';
require_once __DIR__ . '/feature/AuditFeature.php';
require_once __DIR__ . '/feature/CacheFeature.php';
require_once __DIR__ . '/feature/ClienttrackFeature.php';
require_once __DIR__ . '/feature/CostFeature.php';
require_once __DIR__ . '/feature/DebugFeature.php';
require_once __DIR__ . '/feature/IdempotencyFeature.php';
require_once __DIR__ . '/feature/LogFeature.php';
require_once __DIR__ . '/feature/MetricsFeature.php';
require_once __DIR__ . '/feature/NetsimFeature.php';
require_once __DIR__ . '/feature/PagingFeature.php';
require_once __DIR__ . '/feature/ProxyFeature.php';
require_once __DIR__ . '/feature/RatelimitFeature.php';
require_once __DIR__ . '/feature/RbacFeature.php';
require_once __DIR__ . '/feature/RetryFeature.php';
require_once __DIR__ . '/feature/SecretsFeature.php';
require_once __DIR__ . '/feature/StreamingFeature.php';
require_once __DIR__ . '/feature/TelemetryFeature.php';
require_once __DIR__ . '/feature/TestFeature.php';
require_once __DIR__ . '/feature/TimeoutFeature.php';


class UnivecFeatures
{
    public static function make_feature(string $name)
    {
        switch ($name) {
            case "base":
                return new UnivecBaseFeature();
            case "audit":
                return new UnivecAuditFeature();
            case "cache":
                return new UnivecCacheFeature();
            case "clienttrack":
                return new UnivecClienttrackFeature();
            case "cost":
                return new UnivecCostFeature();
            case "debug":
                return new UnivecDebugFeature();
            case "idempotency":
                return new UnivecIdempotencyFeature();
            case "log":
                return new UnivecLogFeature();
            case "metrics":
                return new UnivecMetricsFeature();
            case "netsim":
                return new UnivecNetsimFeature();
            case "paging":
                return new UnivecPagingFeature();
            case "proxy":
                return new UnivecProxyFeature();
            case "ratelimit":
                return new UnivecRatelimitFeature();
            case "rbac":
                return new UnivecRbacFeature();
            case "retry":
                return new UnivecRetryFeature();
            case "secrets":
                return new UnivecSecretsFeature();
            case "streaming":
                return new UnivecStreamingFeature();
            case "telemetry":
                return new UnivecTelemetryFeature();
            case "test":
                return new UnivecTestFeature();
            case "timeout":
                return new UnivecTimeoutFeature();
            default:
                return new UnivecBaseFeature();
        }
    }

    /**
     * Does a generated feature class back this name? False for a name only
     * an options extend instance can supply (the station adopt path) - the
     * constructor uses this to skip make_feature for such names instead of
     * adding a stray BaseFeature.
     */
    public static function has_feature(string $name): bool
    {
        switch ($name) {
            case "base":
            case "audit":
            case "cache":
            case "clienttrack":
            case "cost":
            case "debug":
            case "idempotency":
            case "log":
            case "metrics":
            case "netsim":
            case "paging":
            case "proxy":
            case "ratelimit":
            case "rbac":
            case "retry":
            case "secrets":
            case "streaming":
            case "telemetry":
            case "test":
            case "timeout":
                return true;
            default:
                return false;
        }
    }
}
