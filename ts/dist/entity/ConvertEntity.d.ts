import { UnivecEntityBase } from '../UnivecEntityBase';
import type { UnivecSDK } from '../UnivecSDK';
import type { Control } from '../types';
import type { Convert, ConvertCreateData } from '../UnivecTypes';
declare class ConvertEntity extends UnivecEntityBase<Convert> {
    constructor(client: UnivecSDK, entopts: any);
    make(this: ConvertEntity): ConvertEntity;
    create(this: any, reqdata?: ConvertCreateData, ctrl?: Control): Promise<Convert>;
}
export { ConvertEntity };
