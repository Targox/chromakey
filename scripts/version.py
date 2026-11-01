import os
import re

message = os.environ.get('HEAD_MESSAGE', '').splitlines()
subject = message[0] if message else ''
requested = os.environ.get('INPUT_VERSION', '').strip()
release = subject.startswith('release:') or bool(requested)
match = re.match(r'^release:\s*v?(\d+\.\d+\.\d+)\s*$', subject)
version = requested or (match[1] if match else '0.1.' + os.environ['GITHUB_RUN_NUMBER'])
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit(1)
with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
    f.write(f'version={version}\nrelease={str(release).lower()}\n')
