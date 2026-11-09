"""Offline protocol tests; public BIP85 vector only, no USB or real keys."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import subprocess

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'opt/luckfox/secure-boot'))
import forgebox_sign as fb
from embit import bip32

XPRV = 'xprv9s21ZrQH143K2LBWUUQRFXhucrQqBpKdRRxNVq2zBqsx8HVqFk2uYo8kmbaLLHRdqtQpUm98uKfu3vca1LqdGhUtyoFnCNkfmXRyPXLjbKb'


def fixture():
    original, payload = b'original test firmware', b'compressed test fixture'
    ota = ((348).to_bytes(4, 'little') + b'~fwdata!' + len(payload).to_bytes(4, 'big') +
           len(original).to_bytes(4, 'big') + hashlib.sha256(payload).digest() +
           hashlib.sha256(original).digest() + bytes.fromhex('000000010000400000000000') +
           b'\x00' * 128 + b'\x1f' * 128 + b'\x00' + payload)
    return ota, original


class TestForgeBoxProtocol(unittest.TestCase):
    def setUp(self):
        self.key = fb.key_from_root(bip32.HDKey.from_base58(XPRV), 0)
        self.public = fb.public_hex(self.key)
        self.ota, self.original = fixture()
        self.request = fb.firmware_request(self.ota, self.original, self.public, 'test.bin')

    def test_bip85_published_vector_and_index_limits(self):
        self.assertEqual(self.key.to_string().hex(), '7040bb53104f27367f317558e78a994ada7296c6fde36a364e5baf206e502bb1')
        for invalid in (-1, 2**31, True, '0'):
            with self.assertRaises(ValueError):
                fb.key_from_root(bip32.HDKey.from_base58(XPRV), invalid)

    def test_invalid_scalar_fails_without_retry(self):
        from unittest.mock import patch
        for entropy in (b'\x00' * 64, b'\xff' * 64):
            with patch('embit.bip85.derive_entropy', return_value=entropy), self.assertRaises(ValueError):
                fb.key_from_root(bip32.HDKey.from_base58(XPRV), 0)

    def test_two_signatures_and_byte_exact_assembly(self):
        response = fb.sign_request(self.request, self.key)
        self.assertEqual(response, fb.sign_request(self.request, self.key))
        signed = fb.assemble(self.ota, self.request, response, self.original)
        self.assertEqual(signed[:96], self.ota[:96])
        self.assertEqual(signed[352:], self.ota[352:])
        self.assertEqual(signed[96:224], response['signatures'][0].encode())
        # Independently verify through OpenSSL's prehashed ECDSA backend.
        from cryptography.hazmat.primitives import serialization, hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        verifier = serialization.load_pem_public_key(self.key.verifying_key.to_pem())
        for encoded, digest in zip(response['signatures'], fb.digests(self.request)):
            raw = bytes.fromhex(encoded)
            verifier.verify(utils.encode_dss_signature(int.from_bytes(raw[:32], 'big'), int.from_bytes(raw[32:], 'big')),
                            digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))

    def test_wrong_key_tampering_stale_response_and_high_s_rejected(self):
        response = fb.sign_request(self.request, self.key)
        wrong = fb.key_from_root(bip32.HDKey.from_base58(XPRV), 1)
        with self.assertRaises(ValueError):
            fb.sign_request(self.request, wrong)
        for field in ('id', 'original_hash', 'compressed_hash', 'package_hash'):
            changed = dict(self.request, **{field:'00' * 32})
            with self.assertRaises(ValueError):
                fb.verify_response(changed, response)
        changed = copy.deepcopy(response)
        raw = bytes.fromhex(changed['signatures'][0])
        changed['signatures'][0] = (raw[:32] + (fb.SECP256k1.order - int.from_bytes(raw[32:], 'big')).to_bytes(32, 'big')).hex()
        with self.assertRaises(ValueError):
            fb.verify_response(self.request, changed)
        with self.assertRaises(ValueError):
            fb.assemble(self.ota[:-1]+b'x', self.request, response, self.original)
        with self.assertRaises(ValueError):
            fb.assemble(self.ota, self.request, response, b'changed original')

    def test_registration_challenge_and_legacy_are_separate(self):
        for legacy in (False, True):
            nonce = '' if legacy else 'ab' * 32
            request = fb.new_request('register', self.public, legacy=legacy, nonce=nonce)
            response = fb.sign_request(request, self.key)
            self.assertEqual(len(response['signatures']), 1)
            self.assertEqual(fb.digests(request), [hashlib.sha256(bytes.fromhex(self.public+nonce)).digest()])
            self.assertTrue(fb.verify_response(request, response))
        with self.assertRaises(ValueError):
            fb.new_request('register', self.public, legacy=False, nonce='')

    def test_public_export_contains_no_secret(self):
        with tempfile.TemporaryDirectory() as card:
            fb.export_public(card, self.key, 0)
            paths = sorted(p.name for p in (Path(card)/fb.CARD_DIR).iterdir())
            self.assertEqual(paths, ['pubkey.pem', 'public.json'])
            record = fb.read_json(card, 'public.json')
            self.assertEqual(record['bip85_path'], "m/83696968'/2'/0'")
            for p in (Path(card)/fb.CARD_DIR).iterdir():
                self.assertNotIn(self.key.to_string(), p.read_bytes())
                self.assertNotIn(b'PRIVATE KEY', p.read_bytes())

    def test_untrusted_schema_sizes_duplicate_and_symlinks(self):
        for change in ({'action':'shell'}, {'name':'../key.pem'}, {'original_size':True},
                       {'extra':'unexpected'}, {'public_key':'04'+'00'*64}):
            request = dict(self.request, **change)
            request['id'] = fb.identify(request)
            with self.assertRaises(Exception):
                fb.validate_request(request)
        with tempfile.TemporaryDirectory() as card:
            fb.write_json(card, 'request.json', self.request)
            path = Path(card)/fb.CARD_DIR/'request.json'
            path.write_text('{"schema":1,"schema":2}')
            with self.assertRaises(ValueError):
                fb.read_json(card, 'request.json')
            path.write_bytes(b'x'*(fb.MAX_JSON+1))
            with self.assertRaises(ValueError):
                fb.read_json(card, 'request.json')
            path.unlink()
            try:
                path.symlink_to(Path(card)/'outside')
            except OSError:
                return  # Windows may deny symlink creation without developer mode.
            with self.assertRaises(ValueError):
                fb.write_json(card, 'request.json', self.request)

    @unittest.skipUnless(os.environ.get('FORGEBOX_CLI_DIR'), 'set FORGEBOX_CLI_DIR for official compression interoperability')
    def test_actual_cli_prepare_sign_assemble_and_verify(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            original = folder/'firmware.bin'
            original.write_bytes(bytes(range(256))*200)
            public = folder/'owner.pub.pem'
            public.write_bytes(self.key.verifying_key.to_pem())
            unsigned, signed = folder/'unsigned.bin', folder/'signed.bin'
            cli = os.environ['FORGEBOX_CLI_DIR']
            tool = ROOT/'tools/forgebox-airgap.py'
            subprocess.run([sys.executable,str(tool),'prepare','--firmware',str(original),
                            '--unsigned',str(unsigned),'--cli-dir',cli,'--public-key',str(public),
                            '--card',directory],check=True,capture_output=True)
            request = fb.validate_request(fb.read_json(directory,'request.json'))
            fb.write_json(directory,'response.json',fb.sign_request(request,self.key))
            args = [sys.executable,str(tool),'assemble','--unsigned',str(unsigned),
                    '--firmware',str(original),'--public-key',str(public),'--card',directory,'--out',str(signed)]
            subprocess.run(args,check=True,capture_output=True)
            node = "const p=require('path');const m=require(p.join(process.argv[1],'dist/lib/sign_verify.js'));const r=m.verifyOta(process.argv[2],process.argv[3],process.argv[4]);if(!r.compressed_hash_match||!r.original_hash_match||!r.compressed_signature_ok||!r.original_signature_ok)process.exit(1);"
            subprocess.run(['node','-e',node,cli,str(signed),str(original),self.public],check=True)
            self.assertNotEqual(subprocess.run(args,capture_output=True).returncode,0,'existing output overwritten')
            unsigned.write_bytes(unsigned.read_bytes()[:-1]+b'x')
            args[-1] = str(folder/'tampered.bin')
            self.assertNotEqual(subprocess.run(args,capture_output=True).returncode,0)
            self.assertFalse((folder/'tampered.bin').exists())


if __name__ == '__main__':
    unittest.main()
