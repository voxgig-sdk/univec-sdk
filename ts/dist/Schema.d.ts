declare const OPTSPEC: {
    allow: {
        method: string;
        op: string;
    };
    apikey: string;
    auth: {
        basic: boolean;
        in: string;
        name: string;
        prefix: string;
    };
    base: string;
    clean: {
        keys: string;
    };
    entity: {
        "`$CHILD`": {
            "`$OPEN`": boolean;
            active: boolean;
            alias: {};
        };
    };
    extend: string;
    headers: {
        "`$CHILD`": string;
    };
    prefix: string;
    secret: string;
    server: {
        "`$CHILD`": string;
    };
    suffix: string;
    system: {
        fetch: string;
    };
    test: {
        active: boolean;
        entity: {
            "`$OPEN`": boolean;
        };
    };
    utility: {};
    feature: {
        "`$CHILD`": {
            "`$OPEN`": boolean;
            active: boolean;
        };
        audit: (string | {
            "`$OPEN`": boolean;
            active: string[];
            actor: (string | string[])[];
            max: string[];
            now: string[];
            sink: string[];
        })[];
        cache: (string | {
            "`$OPEN`": boolean;
            active: string[];
            max: string[];
            methods: string[];
            ttl: string[];
            now: string[];
        })[];
        clienttrack: (string | {
            "`$OPEN`": boolean;
            active: string[];
            clientVersion: string[];
            clientName: string[];
            headers: string[];
            idgen: string[];
            sessionId: string[];
        })[];
        cost: (string | {
            "`$OPEN`": boolean;
            active: string[];
            budget: string[];
            currency: (string | string[])[];
            header: (string | string[])[];
            onBudget: (string | string[])[];
            path: (string | string[])[];
            perUnit: string[];
            rates: string[];
            unit: string[];
            actor: string[];
            sink: string[];
        })[];
        debug: (string | {
            "`$OPEN`": boolean;
            active: string[];
            max: string[];
            redact: string[];
            now: string[];
            onEntry: string[];
        })[];
        idempotency: (string | {
            "`$OPEN`": boolean;
            active: string[];
            header: (string | string[])[];
            methods: string[];
            ops: string[];
            keygen: string[];
        })[];
        log: (string | {
            "`$OPEN`": boolean;
            active: string[];
            level: string[];
            logger: string;
        })[];
        metrics: (string | {
            "`$OPEN`": boolean;
            active: string[];
            now: string[];
        })[];
        netsim: (string | {
            "`$OPEN`": boolean;
            active: string[];
            errorTimes: string[];
            failEvery: string[];
            failRate: string[];
            failStatus: string[];
            failTimes: string[];
            latency: string[];
            offline: string[];
            rateLimitTimes: string[];
            retryAfter: string[];
            seed: string[];
            sleep: string[];
        })[];
        paging: (string | {
            "`$OPEN`": boolean;
            active: string[];
            afterVar: (string | string[])[];
            cursorParam: (string | string[])[];
            firstVar: (string | string[])[];
            limitParam: (string | string[])[];
            pageParam: (string | string[])[];
            startPage: string[];
            limit: string[];
            ops: string[];
        })[];
        proxy: (string | {
            "`$OPEN`": boolean;
            active: string[];
            fromEnv: string[];
            noProxy: string[];
            url: (string | string[])[];
            agent: string[];
        })[];
        ratelimit: (string | {
            "`$OPEN`": boolean;
            active: string[];
            burst: string[];
            rate: string[];
            now: string[];
            sleep: string[];
        })[];
        rbac: (string | {
            "`$OPEN`": boolean;
            active: string[];
            deny: string[];
            permissions: string[];
            rules: string[];
        })[];
        retry: (string | {
            "`$OPEN`": boolean;
            active: string[];
            factor: string[];
            maxDelay: string[];
            minDelay: string[];
            retries: string[];
            statuses: string[];
            jitter: string[];
            sleep: string[];
        })[];
        secrets: (string | {
            "`$OPEN`": boolean;
            active: string[];
            cache: string[];
            exchange: string[];
            name: (string | string[])[];
            providers: string[];
        })[];
        streaming: (string | {
            "`$OPEN`": boolean;
            active: string[];
            chunkDelay: string[];
            chunkSize: string[];
            ops: string[];
            sleep: string[];
        })[];
        telemetry: (string | {
            "`$OPEN`": boolean;
            active: string[];
            exporter: string[];
            headers: string[];
            idgen: string[];
            now: string[];
        })[];
        test: (string | {
            "`$OPEN`": boolean;
            active: string[];
            entity: string[];
            net: string[];
        })[];
        timeout: (string | {
            "`$OPEN`": boolean;
            active: string[];
            ms: string[];
            clearTimer: string[];
            setTimer: string[];
        })[];
    };
};
declare const ENTITYSPEC: {};
export { OPTSPEC, ENTITYSPEC, };
