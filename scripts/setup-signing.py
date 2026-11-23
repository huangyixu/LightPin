#!/usr/bin/env python3
"""Create a persistent, local-only signing identity once. Never export it with sources."""
import os, pathlib, subprocess, tempfile, hashlib, secrets
state = pathlib.Path.home() / 'Library/Application Support/LightPin/Signing'
identity = state / 'identity.txt'
if identity.exists():
    print('Existing LightPin identity retained:', identity.read_text().strip())
    raise SystemExit(0)
state.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(state, 0o700)
keychain = pathlib.Path.home() / 'Library/Keychains/login.keychain-db'
def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise SystemExit(result.stderr.decode(errors="replace"))
    return result.stdout
with tempfile.TemporaryDirectory(prefix='lightpin-signing-') as directory:
    root = pathlib.Path(directory)
    config = root / 'certificate.cnf'
    config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = LightPin Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
    password = secrets.token_hex(24)
    os.environ["LIGHTPIN_P12_PASSWORD"] = password
    old = os.umask(0o077)
    try:
        run('/usr/bin/openssl', 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650', '-config', str(config), '-keyout', str(root/'key.pem'), '-out', str(root/'cert.pem'))
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', str(root/'key.pem'), '-in', str(root/'cert.pem'), '-out', str(root/'identity.p12'), '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1', '-passout', 'env:LIGHTPIN_P12_PASSWORD')
        run('/usr/bin/security', 'import', str(root/'identity.p12'), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign')
        der = run('/usr/bin/openssl', 'x509', '-in', str(root/'cert.pem'), '-outform', 'DER')
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        (state/'certificate.cer').write_bytes(der)
        identity.write_text(fingerprint+'\n')
        print('Created persistent LightPin identity:', fingerprint)
        print('Private key is stored only in the login keychain.')
    finally:
        os.environ.pop("LIGHTPIN_P12_PASSWORD", None)
        os.umask(old)
