import { BaseFeature } from './feature/base/BaseFeature';
declare class Config {
    makeFeature(this: any, fn: string): BaseFeature;
    main: {
        name: string;
    };
    feature: {
        test: {
            options: {
                active: boolean;
            };
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
                active: boolean;
                name: string;
                req: boolean;
                type: string;
                index$: number;
            }[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: {
                        active: boolean;
                        args: {};
                        method: string;
                        orig: string;
                        parts: string[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        index$: number;
                    }[];
                    key$: string;
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        embed: {
            fields: {
                active: boolean;
                name: string;
                req: boolean;
                type: string;
                index$: number;
            }[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: {
                        active: boolean;
                        args: {};
                        method: string;
                        orig: string;
                        parts: string[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        index$: number;
                    }[];
                    key$: string;
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        ephemeral_key: {
            fields: {
                active: boolean;
                name: string;
                req: boolean;
                type: string;
                index$: number;
            }[];
            name: string;
            op: {
                create: {
                    input: string;
                    name: string;
                    points: {
                        active: boolean;
                        args: {};
                        method: string;
                        orig: string;
                        parts: string[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        index$: number;
                    }[];
                    key$: string;
                };
            };
            relations: {
                ancestors: never[];
            };
        };
        model: {
            fields: {
                active: boolean;
                name: string;
                req: boolean;
                type: string;
                index$: number;
            }[];
            name: string;
            op: {
                list: {
                    input: string;
                    name: string;
                    points: {
                        active: boolean;
                        args: {};
                        method: string;
                        orig: string;
                        parts: string[];
                        select: {};
                        transform: {
                            req: string;
                            res: string;
                        };
                        index$: number;
                    }[];
                    key$: string;
                };
            };
            relations: {
                ancestors: never[];
            };
        };
    };
}
declare const config: Config;
export { config };
