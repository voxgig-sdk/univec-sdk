import { UnivecEntityBase } from '../UnivecEntityBase';
import type { UnivecSDK } from '../UnivecSDK';
import type { Control } from '../types';
import type { Model, ModelListMatch } from '../UnivecTypes';
declare class ModelEntity extends UnivecEntityBase<Model> {
    constructor(client: UnivecSDK, entopts: any);
    make(this: ModelEntity): ModelEntity;
    list(this: any, reqmatch?: ModelListMatch, ctrl?: Control): Promise<Model[]>;
}
export { ModelEntity };
