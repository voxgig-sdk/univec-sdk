// Univec SDK public API (generated).

#ifndef UNIVEC_API_H
#define UNIVEC_API_H

#include "sdk.h"

// Convert entity.
Entity* convert_entity_new(UnivecSDK* client, voxgig_value* entopts);
Entity* univec_convert(UnivecSDK* client, voxgig_value* entopts);
voxgig_value* convert_stream(Entity* e, const char* action, voxgig_value* args, voxgig_value* callopts, PNError** err);
// Embed entity.
Entity* embed_entity_new(UnivecSDK* client, voxgig_value* entopts);
Entity* univec_embed(UnivecSDK* client, voxgig_value* entopts);
voxgig_value* embed_stream(Entity* e, const char* action, voxgig_value* args, voxgig_value* callopts, PNError** err);
// EphemeralKey entity.
Entity* ephemeral_key_entity_new(UnivecSDK* client, voxgig_value* entopts);
Entity* univec_ephemeral_key(UnivecSDK* client, voxgig_value* entopts);
voxgig_value* ephemeral_key_stream(Entity* e, const char* action, voxgig_value* args, voxgig_value* callopts, PNError** err);
// Model entity.
Entity* model_entity_new(UnivecSDK* client, voxgig_value* entopts);
Entity* univec_model(UnivecSDK* client, voxgig_value* entopts);
voxgig_value* model_stream(Entity* e, const char* action, voxgig_value* args, voxgig_value* callopts, PNError** err);

#endif // UNIVEC_API_H
