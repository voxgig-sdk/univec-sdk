// Execute the generated live suite through real HTTP on loopback. No Univec
// requests leave the process: the preload rejects any unexpected origin.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const http = require('node:http')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const root = path.resolve(__dirname, '../../..')
const catalogue = [
  {name:'convert-bridge',modelType:'convert-bridge',executionProvider:'cpu'},
  {name:'embed-bridge',modelType:'embed-bridge',executionProvider:'cpu',restrictedTargets:['commercial']},
  {name:'source',modelType:'embed',targetModel:'source',targetDim:2},
  {name:'source-target',modelType:'convert',sourceModel:'source',targetModel:'target',sourceDim:2,targetDim:3},
]
async function exercise(fault) {
  const calls = [], errors = []
  const server = http.createServer(async (req,res) => {
    let raw = ''; for await (const data of req) raw += data
    const body = JSON.parse(raw || '{}')
    const route = req.url
    calls.push({ method:req.method, path:route, body })
    try {
      const publicRoute = ['/v1/models','/v1/ephemeral/key'].includes(route)
      assert.equal(req.headers.authorization, publicRoute ? undefined : route.includes('/ephemeral/') ? 'Bearer eph_fixture' : 'Bearer uv_fixture')
      assert(!Object.keys(body).some(key => key.startsWith('$')), 'Selectors leaked into body')
      if (route.endsWith('/key')) assert.deepEqual(body,{})
      if (route.endsWith('/embed')) assert.deepEqual(body,{model:'source',texts:['SDK live coverage test.']})
      if (route.endsWith('/convert')) assert.deepEqual(body,{source_model:'source',target_model:'target',embeddings:[[0.25,0.75]]})
      if (route.endsWith('/embed-bridge')) assert.deepEqual(body,{bridge_model:'source',target_model:'target',texts:['SDK live coverage test.']})
    } catch (e) { errors.push(e.message) }
    if (fault === 'disconnect' && route === '/v1/embed') return req.socket.destroy()
    if (Number.isInteger(fault) && route === '/v1/embed') { res.writeHead(fault,{'content-type':'application/json'}); return res.end(JSON.stringify({success:false,error:{message:'do not log uv_fixture'}})) }
    if (fault === 'catalogue' && route === '/v1/models') { res.writeHead(500); return res.end('{}') }
    if (fault === 'key' && route.endsWith('/key')) { res.writeHead(429); return res.end('{}') }
    if (fault === 'invalid-json' && route === '/v1/embed') return res.end('not-json')
    let data = route === '/v1/models' ? catalogue : route.endsWith('/key') ? {key:'eph_fixture',dailyLimit:10,dailyUsed:0,resetsAt:'2026-09-15T00:00:00Z'} : route.endsWith('/embed') ? {model:body.model,embeddings:[[0.25,0.75]]} : {source_model:body.source_model || body.bridge_model,target_model:body.target_model,embeddings:[[0.1,0.2,0.7]]}
    if (route.endsWith('/embed-bridge')) { data.bridge_model=data.source_model; delete data.source_model; data.model='bridge-fixture' }
    if (fault === 'bridge-shape' && route === '/v1/embed-bridge') { data.source_model=data.bridge_model; delete data.bridge_model }
    if (fault === 'shape' && route === '/v1/embed') data.embeddings=[[1]]
    if (fault === 'contract' && route === '/v1/ephemeral/key') data.dailyLimit='10'
    res.writeHead(200,{'content-type':'application/json'}); res.end(JSON.stringify({success:true,data}))
  })
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
  const temp = fs.mkdtempSync(path.join(os.tmpdir(),'univec-live-'))
  const port = server.address().port
  const preload = path.join(temp,'transport.cjs')
  fs.writeFileSync(preload,`const fetch = globalThis.fetch;
require(${JSON.stringify(path.join(root,'ts/dist-test/utility.js'))}).liveDelayMs = () => 0;
globalThis.fetch=(url,init)=>{const parsed=new URL(url);if(parsed.origin!=='https://api.univec.ai')throw Error('Unexpected origin');return fetch('http://127.0.0.1:${port}'+parsed.pathname+parsed.search,init)};
`)
  try {
    const output = await new Promise((resolve,reject)=>{
      const env={...process.env,UNIVEC_TEST_LIVE:'TRUE',UNIVEC_APIKEY:'uv_fixture'}; delete env.NODE_TEST_CONTEXT
      const proc=spawn(process.execPath,['--require',preload,'--test','dist-test/live.test.js'],{cwd:path.join(root,'ts'),env,timeout:30000})
      let text='';proc.stdout.on('data',d=>text+=d);proc.stderr.on('data',d=>text+=d);proc.on('error',reject);proc.on('close',code=>resolve({code,text}))
    })
    assert.deepEqual(errors,[])
    assert(!output.text.includes('uv_fixture') && !output.text.includes('eph_fixture'),'Credentials leaked in report')
    const report=JSON.parse(output.text.split('\n').find(l=>l.includes('LIVE SUMMARY '))?.split('LIVE SUMMARY ')[1] || '{}')
    assert.equal(report.planned,8,output.text)
    if (!fault) { assert.equal(output.code,0,output.text);assert.equal(calls.length,8);assert.equal(report.passed,8) }
    else {
      assert.notEqual(output.code,0,output.text)
      if (fault === 'catalogue') assert(calls.some(c=>c.path==='/v1/ephemeral/key'))
      else if (fault === 'key' || fault === 'contract') assert(calls.some(c=>c.path==='/v1/convert'))
      else {
        assert(calls.some(c=>c.path==='/v1/embed-bridge'),'Independent bridge was not attempted')
        assert(calls.some(c=>c.path==='/v1/ephemeral/convert'),'Independent ephemeral workflow was not attempted')
      }
    }
  } finally { server.closeAllConnections();await new Promise(resolve=>server.close(resolve));fs.rmSync(temp,{recursive:true,force:true}) }
}
for (const fault of [null,401,422,429,500,'disconnect','invalid-json','shape','bridge-shape','contract','catalogue','key']) test('generated Univec live scenario: '+(fault || 'success'),()=>exercise(fault))
