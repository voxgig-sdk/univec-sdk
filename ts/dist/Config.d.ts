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
            transport: string;
        };
        cache: {
            options: {
                active: boolean;
                max: number;
                methods: string[];
                ttl: number;
            };
            transport: string;
        };
        clienttrack: {
            options: {
                active: boolean;
                clientVersion: string;
            };
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
            transport: string;
        };
        debug: {
            options: {
                active: boolean;
                max: number;
                redact: string[];
            };
            transport: string;
        };
        idempotency: {
            options: {
                active: boolean;
                header: string;
                methods: string[];
                ops: string[];
            };
            transport: string;
        };
        log: {
            options: {
                active: boolean;
            };
            transport: string;
        };
        metrics: {
            options: {
                active: boolean;
            };
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
            transport: string;
        };
        proxy: {
            options: {
                active: boolean;
                fromEnv: boolean;
                noProxy: never[];
                url: string;
            };
            transport: string;
        };
        ratelimit: {
            options: {
                active: boolean;
                burst: number;
                rate: number;
            };
            transport: string;
        };
        rbac: {
            options: {
                active: boolean;
                deny: boolean;
                permissions: never[];
                rules: {};
            };
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
            transport: string;
        };
        streaming: {
            options: {
                active: boolean;
                chunkDelay: number;
                chunkSize: number;
            };
            transport: string;
        };
        telemetry: {
            options: {
                active: boolean;
            };
            transport: string;
        };
        test: {
            options: {
                active: boolean;
            };
            transport: string;
        };
        timeout: {
            options: {
                active: boolean;
                ms: number;
            };
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
                    points: {
                        args: {};
                        kind: string;
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
                    points: {
                        args: {};
                        kind: string;
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
