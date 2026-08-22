import { UnivecEntityBase } from '../UnivecEntityBase';
import type { UnivecSDK } from '../UnivecSDK';
import type { Control } from '../types';
import type { Embed, EmbedCreateData } from '../UnivecTypes';
declare class EmbedEntity extends UnivecEntityBase<Embed> {
    constructor(client: UnivecSDK, entopts: any);
    make(this: EmbedEntity): EmbedEntity;
    create(this: any, reqdata?: EmbedCreateData, ctrl?: Control): Promise<EmbedEntity>;
}
export { EmbedEntity };
