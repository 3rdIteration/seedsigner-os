#!/usr/bin/env node
/* Official forgebox-cli 1.2.0 compression/USB adapter. Never loads a private key.
 * register: keeps the USB session open while the card visits the offline signer.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const cp = require('child_process');
const readline = require('readline/promises');

function cli(directory) {
    const root = path.resolve(directory);
    if (JSON.parse(fs.readFileSync(path.join(root, 'package.json'))).version !== '1.2.0')
        throw Error('This adapter is tested with forgebox-cli 1.2.0 only');
    return root;
}
function python(executable, args) {
    return cp.execFileSync(executable, [path.join(__dirname, 'forgebox-airgap.py'), ...args],
                           {encoding:'utf8', maxBuffer:32768}).trim();
}
async function register(root, pem, card, executable, device, waitForCard) {
    // Injected device/wait seam supports protocol tests without touching USB.
    try {
        const status = await device.getStatus();
        const version = String(status.firmwareVersion || '').trim();
        if (!version) throw Error('No factory firmware version; refusing registration');
        const legacy = version === '1.0.0';
        const nonce = legacy ? Buffer.alloc(0) : await device.getNonce();
        if (!legacy && nonce.length !== 32) throw Error('Invalid nonce');
        const args = ['registration-request', '--public-key', pem, '--card', card,
                      '--nonce', nonce.toString('hex')];
        if (legacy) args.push('--legacy');
        const request = JSON.parse(python(executable, args));
        const publicKey = Buffer.from(request.public_key, 'hex');
        console.log('One-time registration key (compare ALL hex on device):\n' +
                    publicKey.subarray(1).toString('hex').toUpperCase());
        console.log('SHA256 key fingerprint: ' + crypto.createHash('sha256').update(publicKey).digest('hex'));
        await waitForCard();
        const response = JSON.parse(python(executable, ['verify-response', '--card', card]));
        if (response.id !== request.id || response.public_key !== request.public_key || response.signatures.length !== 1)
            throw Error('Response does not match this live registration session');
        const signature = Buffer.from(response.signatures[0], 'hex');
        if (!crypto.verify('sha256', Buffer.concat([publicKey, nonce]),
                {key:fs.readFileSync(pem), dsaEncoding:'ieee-p1363'}, signature))
            throw Error('Proof of possession failed');
        console.log('Compare the device key and confirm on ForgeBox to register.');
        const ok = legacy ? await device.registerPublicKeyLegacy(publicKey, signature) :
                          await device.registerPublicKey(publicKey, nonce, signature);
        if (!ok) throw Error('Device rejected registration (nonce may have expired); start a fresh session');
        console.log('Device reported registration successful.');
    } finally { await device.disconnect(); }
}
async function main(args) {
    const [command, directory, ...rest] = args;
    const root = cli(directory);
    if (command === 'compress' && rest.length === 2) {
        const [source, destination] = rest;
        if (fs.existsSync(destination)) throw Error('Output already exists');
        const {processOta} = require(path.join(root, 'dist/lib/sign_verify.js'));
        processOta(source, destination, null);
    } else if (command === 'register' && rest.length === 3) {
        const [pem, card, executable] = rest;
        const {UsbManager} = require(path.join(root, 'dist/lib/usb-manager.js'));
        const device = await UsbManager.findDevice();
        await register(root, pem, card, executable, device, async () => {
            const input = readline.createInterface({input:process.stdin, output:process.stdout});
            try { await input.question('Keep ForgeBox connected. Sign request on SeedSigner, return card, press Enter: '); }
            finally { input.close(); }
        });
    } else throw Error('Usage: node forgebox-bridge.cjs compress CLI_DIR FIRMWARE UNSIGNED\n' +
                        '   or: node forgebox-bridge.cjs register CLI_DIR PUBLIC_PEM CARD PYTHON_EXECUTABLE');
}
module.exports = {register};
if (require.main === module) main(process.argv.slice(2)).catch(error => {
    console.error('forgebox-bridge: ' + error.message); process.exitCode = 1;
});
