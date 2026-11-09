#!/usr/bin/env python3
"""PC half of ForgeBox signing. The PC never receives a private key.

Requires python-ecdsa; preparation also needs Node 24 and forgebox-cli 1.2.0.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'opt/luckfox/secure-boot'))
import forgebox_sign as fb


def read_public(path):
    # Bound the PEM and require the expected curve; no private-key parser exists.
    data = Path(path).read_bytes()
    fb.require(len(data) <= 4096 and b'PRIVATE KEY' not in data, 'expected public PEM')
    key = fb.VerifyingKey.from_pem(data)
    fb.require(key.curve == fb.SECP256k1, 'expected secp256k1 key')
    return '04' + key.to_string().hex()


def read_bounded(path):
    with open(path, 'rb') as stream:
        data = stream.read(fb.MAX_FIRMWARE + 354)
    fb.require(len(data) <= fb.MAX_FIRMWARE + 353, 'firmware/package too large')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prepare = commands.add_parser('prepare', help='compress with official CLI and export two digests')
    prepare.add_argument('--firmware', required=True)
    prepare.add_argument('--unsigned', required=True, help='PC-side unsigned OTA file (must not exist)')
    prepare.add_argument('--cli-dir', required=True, help='installed node_modules/forgebox-cli directory')
    prepare.add_argument('--public-key', required=True)
    prepare.add_argument('--card', required=True)
    assemble = commands.add_parser('assemble', help='verify returned signatures and assemble OTA')
    assemble.add_argument('--unsigned', required=True)
    assemble.add_argument('--firmware', required=True)
    assemble.add_argument('--public-key', required=True, help='trusted enrolled key, not a replacement from the card')
    assemble.add_argument('--card', required=True)
    assemble.add_argument('--out', required=True, help='new signed OTA path')
    registration = commands.add_parser('registration-request', help='used by USB bridge; no USB in this process')
    registration.add_argument('--public-key', required=True)
    registration.add_argument('--nonce', default='')
    registration.add_argument('--legacy', action='store_true')
    registration.add_argument('--card', required=True)
    verify = commands.add_parser('verify-response', help='emit the strictly validated response for the bridge')
    verify.add_argument('--card', required=True)
    args = parser.parse_args()
    if args.command == 'prepare':
        public = read_public(args.public_key)
        original = read_bounded(args.firmware)
        fb.require(0 < len(original) <= fb.MAX_FIRMWARE, 'invalid original size')
        fb.require(not Path(args.unsigned).exists(), 'unsigned output already exists')
        subprocess.run(['node', str(Path(__file__).with_name('forgebox-bridge.cjs')), 'compress',
                        args.cli_dir, args.firmware, args.unsigned], check=True)
        request = fb.firmware_request(read_bounded(args.unsigned), original, public,
                                      Path(args.firmware).name)
        fb.write_json(args.card, 'request.json', request)
        print(json.dumps(request, indent=2))
    elif args.command == 'registration-request':
        request = fb.new_request('register', read_public(args.public_key),
                                 legacy=args.legacy, nonce=args.nonce)
        fb.write_json(args.card, 'request.json', request)
        print(fb.canonical(request).decode())
    else:
        request = fb.validate_request(fb.read_json(args.card, 'request.json'))
        response = fb.read_json(args.card, 'response.json')
        fb.verify_response(request, response)
        if args.command == 'verify-response':
            print(fb.canonical(response).decode())
        else:
            fb.require(request['public_key'] == read_public(args.public_key), 'wrong enrolled public key')
            result = fb.assemble(read_bounded(args.unsigned), request, response,
                                 read_bounded(args.firmware))
            # Never overwrite a firmware file, including through an output symlink.
            with open(args.out, 'xb') as stream:
                stream.write(result)
            print('Verified and assembled:', args.out)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        sys.exit('forgebox-airgap: %s' % error)
