"""ForgeBox offline request protocol v1. No secret-key files or USB on the signer.

ECDSA comes from the already-shipped python-ecdsa; BIP85 comes from embit.
Digest-only requests do not prove what firmware does. Review on a trusted PC.
"""
import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path

from ecdsa import SECP256k1, SigningKey, VerifyingKey, util

CARD_DIR = 'forgebox-signing'
MAX_JSON = 16384
MAX_FIRMWARE = 16 * 1024 * 1024
SCHEMA = 'forgebox-offline-v1'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def _hex(value, length):
    require(type(value) is str and len(value) == length * 2 and
            all(c in '0123456789abcdef' for c in value), 'invalid hex field')
    return bytes.fromhex(value)


def public_key(value):
    raw = _hex(value, 65)
    require(raw[0] == 4, 'expected uncompressed secp256k1 key')
    return VerifyingKey.from_string(raw[1:], curve=SECP256k1)


def fingerprint(public):
    public_key(public)
    return hashlib.sha256(bytes.fromhex(public)).hexdigest()


def key_from_root(root, index):
    """Standard BIP85 WIF application; never use the raw BIP32 child scalar.

    The returned key object has immutable internal big integers: Python cannot
    guarantee their zeroization. Callers must not cache it or export its secret.
    """
    from embit import bip85
    require(type(index) is int and 0 <= index < 2**31, 'BIP85 index out of range')
    entropy = bytearray(bip85.derive_entropy(root, 2, [index])[:32])
    try:
        scalar = int.from_bytes(entropy, 'big')
        require(0 < scalar < SECP256k1.order, 'invalid BIP85 scalar; choose another index')
        return SigningKey.from_string(entropy, curve=SECP256k1, hashfunc=hashlib.sha256)
    finally:
        entropy[:] = b'\x00' * len(entropy)


def public_hex(key):
    return '04' + key.verifying_key.to_string().hex()


def identify(request):
    return hashlib.sha256(canonical({k: v for k, v in request.items() if k != 'id'})).hexdigest()


def validate_request(request):
    require(type(request) is dict and request.get('schema') == SCHEMA, 'unsupported request')
    action = request.get('action')
    common = {'schema', 'action', 'public_key', 'id'}
    if action == 'firmware':
        fields = common | {'name', 'original_size', 'compressed_size', 'original_hash',
                           'compressed_hash', 'package_hash'}
        name = request.get('name')
        require(type(name) is str and 1 <= len(name) <= 80 and
                all(c in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name)
                and name not in ('.', '..'), 'invalid firmware label')
        for field in ('original_size', 'compressed_size'):
            require(type(request.get(field)) is int and 0 < request[field] <= MAX_FIRMWARE,
                    'invalid firmware size')
        for field in ('original_hash', 'compressed_hash', 'package_hash'):
            _hex(request.get(field), 32)
    elif action == 'register':
        fields = common | {'legacy', 'nonce'}
        require(type(request.get('legacy')) is bool, 'invalid registration mode')
        _hex(request.get('nonce'), 0 if request['legacy'] else 32)
    else:
        raise ValueError('unsupported signing action')
    require(set(request) == fields, 'unexpected request fields')
    public_key(request.get('public_key'))
    _hex(request.get('id'), 32)
    require(request['id'] == identify(request), 'request ID mismatch')
    return request


def new_request(action, public, **fields):
    request = dict(schema=SCHEMA, action=action, public_key=public, **fields)
    request['id'] = identify(request)
    return validate_request(request)


def digests(request):
    validate_request(request)
    if request['action'] == 'firmware':
        return [bytes.fromhex(request['compressed_hash']), bytes.fromhex(request['original_hash'])]
    payload = bytes.fromhex(request['public_key'] + request['nonce'])
    return [hashlib.sha256(payload).digest()]


def sign_request(request, key):
    validate_request(request)
    require(request['public_key'] == public_hex(key), 'wrong seed, passphrase or BIP85 index')
    # RFC6979 over the supplied SHA256 digest: no Bitcoin prefix, no second hash.
    signatures = [key.sign_digest_deterministic(digest, hashfunc=hashlib.sha256,
                  sigencode=util.sigencode_string_canonize).hex() for digest in digests(request)]
    response = dict(schema=SCHEMA, id=request['id'], public_key=public_hex(key), signatures=signatures)
    verify_response(request, response)
    return response


def verify_response(request, response):
    validate_request(request)
    require(type(response) is dict and set(response) == {'schema', 'id', 'public_key', 'signatures'},
            'invalid response fields')
    require(response['schema'] == SCHEMA and response['id'] == request['id'] and
            response['public_key'] == request['public_key'], 'response belongs to another request/key')
    values = response['signatures']
    expected = digests(request)
    require(type(values) is list and len(values) == len(expected), 'wrong signature count')
    verifier = public_key(request['public_key'])
    for encoded, digest in zip(values, expected):
        signature = _hex(encoded, 64)
        r, s = util.sigdecode_string(signature, SECP256k1.order)
        require(0 < r < SECP256k1.order and 0 < s <= SECP256k1.order // 2, 'invalid/non-low-S signature')
        require(verifier.verify_digest(signature, digest, sigdecode=util.sigdecode_string), 'invalid signature')
    return True


def _directory(card):
    path = Path(card) / CARD_DIR
    require(not path.is_symlink(), 'signing directory must not be a symlink')
    path.mkdir(exist_ok=True)
    require(path.is_dir(), 'invalid signing directory')
    return path


def _no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON field')
        result[key] = value
    return result


def read_json(card, filename):
    require(filename in ('request.json', 'response.json', 'public.json'), 'invalid protocol filename')
    path = _directory(card) / filename
    require(not path.is_symlink(), 'protocol file must not be a symlink')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    with os.fdopen(fd, 'rb') as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), 'protocol file must be regular')
        data = stream.read(MAX_JSON + 1)
    require(len(data) <= MAX_JSON, 'protocol file too large')
    return json.loads(data, object_pairs_hook=_no_duplicates)


def write_public_file(card, filename, data):
    require(filename in ('request.json', 'response.json', 'public.json', 'pubkey.pem'), 'invalid output filename')
    directory = _directory(card)
    path = directory / filename
    require(not path.is_symlink(), 'output must not be a symlink')
    # Public material only. Atomic replace prevents a partial JSON/signature file.
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.forgebox-')
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(card, filename, value):
    write_public_file(card, filename, canonical(value) + b'\n')


def export_public(card, key, index):
    public = public_hex(key)
    record = dict(schema=SCHEMA, public_key=public, fingerprint=fingerprint(public),
                  bip85_path="m/83696968'/2'/%d'" % index)
    write_public_file(card, 'pubkey.pem', key.verifying_key.to_pem())
    write_json(card, 'public.json', record)
    return record


def parse_ota(data):
    require(353 < len(data) <= MAX_FIRMWARE + 353, 'invalid OTA length')
    require(data[:4] == (348).to_bytes(4, 'little') and data[4:12] == b'~fwdata!', 'invalid OTA header')
    compressed, original = int.from_bytes(data[12:16], 'big'), int.from_bytes(data[16:20], 'big')
    require(compressed == len(data) - 353 and 0 < original <= MAX_FIRMWARE, 'invalid OTA sizes')
    require(data[84:96] == bytes.fromhex('000000010000400000000000') and data[352] == 0,
            'unsupported OTA encoding')
    require(hashlib.sha256(data[353:]).digest() == data[20:52], 'compressed payload hash mismatch')
    return dict(compressed_size=compressed, original_size=original,
                compressed_hash=data[20:52].hex(), original_hash=data[52:84].hex())


def firmware_request(ota, original, public, name):
    fields = parse_ota(ota)
    require(ota[96:224] == b'\x00' * 128 and ota[224:352] == b'\x1f' * 128, 'expected unsigned OTA')
    require(len(original) == fields['original_size'] and
            hashlib.sha256(original).hexdigest() == fields['original_hash'], 'original firmware mismatch')
    return new_request('firmware', public, name=name, package_hash=hashlib.sha256(ota).hexdigest(), **fields)


def assemble(ota, request, response, original):
    validate_request(request)
    require(request['action'] == 'firmware', 'not a firmware request')
    require(firmware_request(ota, original, request['public_key'], request['name']) == request,
            'unsigned package changed since request')
    verify_response(request, response)
    result = bytearray(ota)
    result[96:224] = response['signatures'][0].encode('ascii')
    result[224:352] = response['signatures'][1].encode('ascii')
    return bytes(result)
