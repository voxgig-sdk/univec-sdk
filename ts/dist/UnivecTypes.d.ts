export interface Convert {
    bridge_model: string;
    embeddings: any[];
    source_model: string;
    target_model: string;
    texts: any[];
}
export interface ConvertCreateData {
    bridge_model: string;
    embeddings: any[];
    source_model: string;
    target_model: string;
    texts: any[];
}
export interface Embed {
    embeddings: any[];
    model: string;
    texts: any[];
}
export interface EmbedCreateData {
    embeddings: any[];
    model: string;
    texts: any[];
}
export interface EphemeralKey {
    dailyLimit: number;
    dailyUsed: number;
    key: string;
    resetsAt: string;
}
export interface EphemeralKeyCreateData {
    dailyLimit: number;
    dailyUsed: number;
    key: string;
    resetsAt: string;
}
export interface Model {
    eval?: Record<string, any>;
    executionProvider?: string;
    modelCard?: Record<string, any>;
    modelType: string;
    name: string;
    sequenceLen?: number;
    sourceDim?: number;
    sourceModel?: string;
    targetDim: number;
    targetModel: string;
}
export interface ModelListMatch {
    eval?: Record<string, any>;
    executionProvider?: string;
    modelCard?: Record<string, any>;
    modelType?: string;
    name?: string;
    sequenceLen?: number;
    sourceDim?: number;
    sourceModel?: string;
    targetDim?: number;
    targetModel?: string;
}
