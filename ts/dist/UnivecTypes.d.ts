export interface Convert {
    bridge_model: string;
    data: Record<string, any>;
    embedding: any[];
    source_model: string;
    success: boolean;
    target_model: string;
    text: any[];
}
export interface ConvertCreateData {
    bridge_model: string;
    data: Record<string, any>;
    embedding: any[];
    source_model: string;
    success: boolean;
    target_model: string;
    text: any[];
}
export interface Embed {
    data: Record<string, any>;
    model: string;
    success: boolean;
    text: any[];
}
export interface EmbedCreateData {
    data: Record<string, any>;
    model: string;
    success: boolean;
    text: any[];
}
export interface EphemeralKey {
    data: Record<string, any>;
    success: boolean;
}
export interface EphemeralKeyCreateData {
    data: Record<string, any>;
    success: boolean;
}
export interface Model {
    eval?: Record<string, any>;
    execution_provider?: string;
    model_card?: Record<string, any>;
    model_type: string;
    name: string;
    sequence_len?: number;
    source_dim?: number;
    source_model?: string;
    target_dim: number;
    target_model: string;
}
export interface ModelListMatch {
    eval?: Record<string, any>;
    execution_provider?: string;
    model_card?: Record<string, any>;
    model_type?: string;
    name?: string;
    sequence_len?: number;
    source_dim?: number;
    source_model?: string;
    target_dim?: number;
    target_model?: string;
}
