// Live registration adapter tested with an injected device. Never touches USB.
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cp = require('child_process');
const {register} = require('../tools/forgebox-bridge.cjs');
const root = path.resolve(__dirname, '..');
const python = process.env.PYTHON || 'python3';
const script = `
import sys
sys.path.insert(0, sys.argv[1]+'/opt/luckfox/secure-boot')
import forgebox_sign as f
from embit import bip32
root=bip32.HDKey.from_seed(b'public fixture only')
key=f.key_from_root(root,0)
if sys.argv[3]=='export': f.export_public(sys.argv[2],key,0)
else:
    request=f.read_json(sys.argv[2],'request.json')
    f.write_json(sys.argv[2],'response.json',f.sign_request(request,key))
`;
function offline(card, action) {
    cp.execFileSync(python, ['-c', script, root, card, action]);
}
async function test(legacy, corrupt=false, rejected=false) {
    const card = fs.mkdtempSync(path.join(os.tmpdir(), 'forgebox-bridge-test-'));
    let submissions=0, disconnected=0;
    try {
        offline(card, 'export');
        const device = {
            getStatus: async()=>({firmwareVersion:legacy ? '1.0.0' : '1.2.0'}),
            getNonce: async()=>Buffer.alloc(32, 123),
            registerPublicKey: async(pub,nonce,sig)=>{
                assert(!legacy); assert.equal(nonce.toString('hex'), '7b'.repeat(32));
                assert.equal(sig.length,64); submissions++; return !rejected;
            },
            registerPublicKeyLegacy: async(pub,sig)=>{
                assert(legacy); assert.equal(sig.length,64); submissions++; return !rejected;
            },
            disconnect: async()=>{disconnected++;},
        };
        const wait = async()=>{
            offline(card, 'sign');
            if (corrupt) {
                const p=path.join(card,'forgebox-signing/response.json');
                const r=JSON.parse(fs.readFileSync(p)); r.id='00'.repeat(32);
                fs.writeFileSync(p,JSON.stringify(r));
            }
        };
        const action=register(null,path.join(card,'forgebox-signing/pubkey.pem'),card,python,device,wait);
        if (corrupt || rejected) await assert.rejects(action);
        else await action;
        assert.equal(submissions,corrupt ? 0 : 1);
        assert.equal(disconnected,1);
    } finally {
        // Exactly our mkdtemp result, retained in this lexical scope.
        fs.rmSync(card,{recursive:true,force:true});
    }
}
(async()=>{
    await test(false); await test(true); await test(false,true); await test(false,false,true);
    console.log('PASS: challenge/legacy PoP, stale-response rejection, device rejection and disconnect cleanup');
})().catch(e=>{console.error(e);process.exitCode=1;});
