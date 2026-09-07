"""Check the public-image/authenticated-management boundary on a test container."""
import http.cookiejar
import json
import struct
import subprocess
import sys
import urllib.error
import urllib.request
import zlib

container, address = sys.argv[1:]
# Credentials stay in memory, never in process arguments or test output.
tokens = json.loads(subprocess.check_output(['docker', 'exec', container, 'cat', '/data/tokens.json']))
token = tokens['admin']
anonymous = urllib.request.build_opener()
authenticated = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def request(client, path, method='GET', data=None, headers=None, expected=200):
    req = urllib.request.Request(address + path, data=data, method=method, headers=headers or {})
    try:
        response = client.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == expected, f'{method} {path}: {response.status}, expected {expected}'
        return response.read(), response.headers


request(anonymous, '/api/images', expected=401)
request(anonymous, '/api/images', method='POST', data=b'', expected=401)
request(authenticated, '/api/auth/session', method='POST', data=b'', headers={'Authorization': 'Bearer ' + token}, expected=204)
request(authenticated, '/api/images')


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


# Original 8x8 solid-color PNG; no user data is uploaded.
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 8, 8, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress((b'\0' + b'\x24\x5b\x49' * 8) * 8)) + chunk(b'IEND', b'')
boundary = 'pocketimg-api-smoke-boundary'
body = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="smoke.png"\r\nContent-Type: image/png\r\n\r\n'.encode()
        + png + f'\r\n--{boundary}--\r\n'.encode())
uploaded, _ = request(authenticated, '/api/images', method='POST', data=body,
                      headers={'Content-Type': 'multipart/form-data; boundary=' + boundary, 'Origin': address}, expected=201)
path = json.loads(uploaded)['image']['url']
assert path.startswith('/i/'), 'Expected a public image path'
image, headers = request(anonymous, path)
assert image and headers.get_content_type() == 'image/webp'
request(anonymous, '/api/images', expected=401)
print('PASS: anonymous upload/list=401; authenticated upload/list succeed; image URL without Cookie/Token=200')
