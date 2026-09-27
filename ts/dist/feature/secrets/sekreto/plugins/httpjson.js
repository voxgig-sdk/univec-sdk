"use strict";
// VENDORED: @voxgig/sekreto 0.2.0 (typescript/plugins/httpjson.ts)
// Source: https://github.com/voxgig/sekreto @ 163f537960de6813cc393b89843949ca3afa8cfc  [tag: sdk-20260925-1316-0]
// License: MIT (c) voxgig - see repository LICENSE. Do not edit: resync from upstream.
/* Copyright (c) 2025 Voxgig Ltd, MIT License */
Object.defineProperty(exports, "__esModule", { value: true });
exports.fetchjson = fetchjson;
const support_1 = require("../provider/support");
const HTTP_TIMEOUT_MS = 10000;
const HTTP_MAXBODY = 8 * 1024 * 1024;
async function fetchjson(method, url, headers, body) {
    let res;
    try {
        res = await fetch(url, {
            method,
            headers,
            body,
            // A vault API never legitimately redirects, and a followed redirect
            // carries X-Vault-Token to the redirect's host (and can downgrade
            // https to http), which checkaddr - it only validates the configured
            // address - cannot see. Refuse to follow one.
            redirect: 'error',
            signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
        });
    }
    catch (err) {
        throw new support_1.SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message);
    }
    let text = '';
    try {
        const decoder = new TextDecoder();
        let size = 0;
        for await (const chunk of res.body ?? []) {
            size += chunk.length;
            if (HTTP_MAXBODY < size) {
                throw new support_1.SekretoError('sekreto: oversized response from ' + url.split('?')[0]);
            }
            text += decoder.decode(chunk, { stream: true });
        }
        text += decoder.decode();
    }
    catch (err) {
        if (err instanceof support_1.SekretoError) {
            throw err;
        }
        throw new support_1.SekretoError('sekreto: cannot reach ' + url.split('?')[0] + ': ' + err.message);
    }
    let parsed = undefined;
    try {
        parsed = JSON.parse(text);
    }
    catch (err) {
        if (200 === res.status) {
            throw new support_1.SekretoError('sekreto: malformed response from ' + url.split('?')[0]);
        }
    }
    return { status: res.status, body: parsed };
}
//# sourceMappingURL=httpjson.js.map