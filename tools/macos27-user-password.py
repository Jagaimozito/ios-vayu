#!/usr/bin/env python3
"""Give a local macOS 27 account on the phone its password and automatic login, without the services that are not up
there (sysadminctl needs com.apple.systemadministration.writeconfig; `dscl . -passwd` fails with eDSAuthFailed).

    python3 tools/macos27-user-password.py USER.plist PASSWORD KCPASSWORD_OUT

USER.plist is the account's record copied from the phone (/var/db/dslocal/nodes/Default/users/USER.plist); it is
rewritten in place with a SALTED-SHA512-PBKDF2 ShadowHashData and the matching authentication_authority.
KCPASSWORD_OUT gets /etc/kcpassword for loginwindow's autoLoginUser (the password XORed with Apple's fixed key, padded
to a multiple of 12). The password is used only here; nothing is kept in the repository.
"""
import hashlib
import os
import plistlib
import sys

user_plist, password, kc_out = sys.argv[1], sys.argv[2].encode(), sys.argv[3]
salt = os.urandom(32)
iterations = 45454
entropy = hashlib.pbkdf2_hmac('sha512', password, salt, iterations, 128)
shadow = plistlib.dumps({'SALTED-SHA512-PBKDF2': {'entropy': entropy, 'iterations': iterations, 'salt': salt}},
                        fmt=plistlib.FMT_BINARY)
with open(user_plist, 'rb') as f:
    record = plistlib.load(f)
record['ShadowHashData'] = [shadow]
record['authentication_authority'] = [';ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>']
record.pop('passwd', None)
record['passwd'] = ['********']
with open(user_plist, 'wb') as f:
    plistlib.dump(record, f, fmt=plistlib.FMT_BINARY)

key = [125, 137, 82, 35, 210, 188, 221, 234, 163, 185, 31]
padded = password + b'\0' * ((12 - len(password) % 12) % 12)
with open(kc_out, 'wb') as f:
    f.write(bytes(b ^ key[i % len(key)] for i, b in enumerate(padded)))
print('record:', user_plist, 'keys', sorted(record.keys()))
print('kcpassword:', kc_out, len(padded), 'bytes')
