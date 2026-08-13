import { UnivecEntityBase } from '../UnivecEntityBase';
import type { UnivecSDK } from '../UnivecSDK';
import type { Control } from '../types';
import type { EphemeralKey, EphemeralKeyCreateData } from '../UnivecTypes';
declare class EphemeralKeyEntity extends UnivecEntityBase<EphemeralKey> {
    constructor(client: UnivecSDK, entopts: any);
    make(this: EphemeralKeyEntity): EphemeralKeyEntity;
    create(this: any, reqdata?: EphemeralKeyCreateData, ctrl?: Control): Promise<EphemeralKey>;
}
export { EphemeralKeyEntity };
