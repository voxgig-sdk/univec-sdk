import { BaseFeature } from './feature/base/BaseFeature';
declare const FEATURE_PLUGINS: Record<string, any[]>;
declare class Config {
    makeFeature(this: any, fn: string): BaseFeature;
    hasFeature(this: any, fn: string): boolean;
    main: {
        name: string;
        slug: string;
        version: string;
        target: string;
    };
    feature: {
        audit: {
            options: {
                active: boolean;
                actor: string;
                max: number;
            };
            optspec: {
                now: string;
                sink: string;
            };
            strict: boolean;
            transport: string;
        };
        cache: {
            options: {
                active: boolean;
                max: number;
                methods: string[];
                ttl: number;
            };
            optspec: {
                now: string;
            };
            strict: boolean;
            transport: string;
        };
        clienttrack: {
            options: {
                active: boolean;
                clientVersion: string;
            };
            optspec: {
                clientName: string;
                clientVersion: string;
                headers: string;
                idgen: string;
                sessionId: string;
            };
            strict: boolean;
            transport: string;
        };
        cost: {
            options: {
                active: boolean;
                budget: number;
                currency: string;
                header: string;
                onBudget: string;
                path: string;
                perUnit: number;
                rates: {};
                unit: number;
            };
            optspec: {
                actor: string;
                sink: string;
            };
            strict: boolean;
            transport: string;
        };
        debug: {
            options: {
                active: boolean;
                max: number;
                redact: string[];
            };
            optspec: {
                now: string;
                onEntry: string;
            };
            strict: boolean;
            transport: string;
        };
        idempotency: {
            options: {
                active: boolean;
                header: string;
                methods: string[];
                ops: string[];
            };
            optspec: {
                keygen: string;
            };
            strict: boolean;
            transport: string;
        };
        log: {
            options: {
                active: boolean;
            };
            optspec: {
                level: string;
                logger: string;
            };
            strict: boolean;
            transport: string;
        };
        metrics: {
            options: {
                active: boolean;
            };
            optspec: {
                now: string;
            };
            strict: boolean;
            transport: string;
        };
        netsim: {
            options: {
                active: boolean;
                errorTimes: number;
                failEvery: number;
                failRate: number;
                failStatus: number;
                failTimes: number;
                latency: number;
                offline: boolean;
                rateLimitTimes: number;
                retryAfter: number;
                seed: number;
            };
            optspec: {
                latency: string[];
                sleep: string;
            };
            strict: boolean;
            transport: string;
        };
        paging: {
            options: {
                active: boolean;
                afterVar: string;
                cursorParam: string;
                firstVar: string;
                limitParam: string;
                pageParam: string;
                startPage: number;
            };
            optspec: {
                limit: string;
                ops: string;
            };
            strict: boolean;
            transport: string;
        };
        proxy: {
            options: {
                active: boolean;
                fromEnv: boolean;
                noProxy: never[];
                url: string;
            };
            optspec: {
                agent: string;
            };
            strict: boolean;
            transport: string;
        };
        ratelimit: {
            options: {
                active: boolean;
                burst: number;
                rate: number;
            };
            optspec: {
                now: string;
                sleep: string;
            };
            strict: boolean;
            transport: string;
        };
        rbac: {
            options: {
                active: boolean;
                deny: boolean;
                permissions: never[];
                rules: {};
            };
            optspec: {};
            strict: boolean;
            transport: string;
        };
        retry: {
            options: {
                active: boolean;
                factor: number;
                maxDelay: number;
                minDelay: number;
                retries: number;
                statuses: number[];
            };
            optspec: {
                jitter: string;
                sleep: string;
            };
            strict: boolean;
            transport: string;
        };
        secrets: {
            options: {
                active: boolean;
                cache: boolean;
                exchange: {
                    active: boolean;
                    method: string;
                    path: string;
                    refresh: string;
                    request: string;
                    response: string;
                    retries: number;
                    statuses: number[];
                };
                name: string;
                providers: {
                    kind: string;
                    namespace: string;
                }[];
            };
            optspec: {};
            strict: boolean;
            transport: string;
        };
        streaming: {
            options: {
                active: boolean;
                chunkDelay: number;
                chunkSize: number;
            };
            optspec: {
                ops: string;
                sleep: string;
            };
            strict: boolean;
            transport: string;
        };
        telemetry: {
            options: {
                active: boolean;
            };
            optspec: {
                exporter: string;
                headers: string;
                idgen: string;
                now: string;
            };
            strict: boolean;
            transport: string;
        };
        test: {
            options: {
                active: boolean;
            };
            optspec: {
                entity: string;
                net: string;
            };
            strict: boolean;
            transport: string;
        };
        timeout: {
            options: {
                active: boolean;
                ms: number;
            };
            optspec: {
                clearTimer: string;
                setTimer: string;
            };
            strict: boolean;
            transport: string;
        };
    };
    options: {
        base: string;
        auth: {
            prefix: string;
        };
        headers: {
            "content-type": string;
        };
        entity: {
            convert: {};
            embed: {};
            ephemeral_key: {};
            model: {};
        };
    };
    entity: {
        convert: {
            fields: {
                name: string;
                req: boolean;
                short: string;
                type: string;
            }[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: ({
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    source_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    target_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    bridge_model?: undefined;
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            id: string;
                            input: {
                                embeddings: {
                                    from: string;
                                    path: string;
                                };
                                source_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                target_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                bridge_model?: undefined;
                                texts?: undefined;
                            };
                            credential?: undefined;
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action?: undefined;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    } | {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    bridge_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    target_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    source_model?: undefined;
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            id: string;
                            input: {
                                bridge_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                target_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                texts: string[];
                                embeddings?: undefined;
                                source_model?: undefined;
                            };
                            credential?: undefined;
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action: string;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    } | {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    source_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    target_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    bridge_model?: undefined;
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            credential: {
                                from: string;
                                path: string;
                            };
                            id: string;
                            input: {
                                embeddings: {
                                    from: string;
                                    path: string;
                                };
                                source_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                target_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                bridge_model?: undefined;
                                texts?: undefined;
                            };
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action: string;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    } | {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    bridge_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    target_model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    source_model?: undefined;
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            credential: {
                                from: string;
                                path: string;
                            };
                            id: string;
                            input: {
                                bridge_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                target_model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                texts: string[];
                                embeddings?: undefined;
                                source_model?: undefined;
                            };
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action: string;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    })[];
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        embed: {
            fields: {
                name: string;
                req: boolean;
                short: string;
                type: string;
            }[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: ({
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            id: string;
                            input: {
                                model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                texts: string[];
                            };
                            credential?: undefined;
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action?: undefined;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    } | {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                equal: {
                                    model: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                };
                                vectors: {
                                    count: number;
                                    dimension: {
                                        from: string;
                                        path: string;
                                        related: {
                                            foreign: string;
                                            from: string;
                                            local: string;
                                            where: {
                                                modelType: string;
                                            };
                                        };
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    path: string;
                                };
                            };
                            auth: string;
                            credential: {
                                from: string;
                                path: string;
                            };
                            id: string;
                            input: {
                                model: {
                                    from: string;
                                    path: string;
                                    related: {
                                        foreign: string;
                                        from: string;
                                        local: string;
                                        where: {
                                            modelType: string;
                                        };
                                    };
                                    where: {
                                        modelType: string;
                                    };
                                };
                                texts: string[];
                            };
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {
                            $action: string;
                        };
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    })[];
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        ephemeral_key: {
            fields: ({
                name: string;
                req: boolean;
                short: string;
                type: string;
                format?: undefined;
            } | {
                format: string;
                name: string;
                req: boolean;
                short: string;
                type: string;
            })[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                nonempty: string[];
                            };
                            auth: string;
                            id: string;
                            retention: string;
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    }[];
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        model: {
            fields: ({
                name: string;
                short: string;
                type: string;
                req?: undefined;
            } | {
                name: string;
                req: boolean;
                short: string;
                type: string;
            })[];
            name: string;
            op: {
                list: {
                    input: string;
                    name: string;
                    points: {
                        args: {};
                        kind: string;
                        live: {
                            assert: {
                                nonempty: string[];
                            };
                            auth: string;
                            id: string;
                        };
                        method: string;
                        orig: string;
                        segments: {
                            lit: string;
                        }[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        parts: string[];
                    }[];
                };
            };
            relations: {
                ancestors: never[];
            };
        };
    };
}
declare const config: Config;
export { config, FEATURE_PLUGINS, };
