from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import tempfile
import json
import urllib.request

version = os.environ['VERSION']
root = Path(__file__).resolve().parent.parent
archive = root / f'build/VerificationCodeShortcut-{version}.zip'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
key = Path(os.environ['RUNNER_TEMP']) / 'tap-deploy-key'
key.write_text(os.environ['TAP_DEPLOY_KEY'].strip() + '\n')
key.chmod(0o600)
os.environ['GIT_SSH_COMMAND'] = f'ssh -i {key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes'
known = Path.home()/'.ssh/known_hosts'
known.parent.mkdir(mode=0o700, exist_ok=True)
with urllib.request.urlopen('https://api.github.com/meta') as response:
    hostkeys = json.load(response)['ssh_keys']
with known.open('a') as f:
    for hostkey in hostkeys:f.write('github.com ' + hostkey + '\n')
with tempfile.TemporaryDirectory() as directory:
    tap = Path(directory)/'tap'
    subprocess.run(['git','clone','--depth','1','git@github.com:ZimengXiong/homebrew-tools.git',str(tap)],check=True)
    (tap/'lib').mkdir(exist_ok=True)
    cask = (root/'packaging/chromakey.rb.in').read_text().replace('@VERSION@',version).replace('@SHA256@',digest)
    (tap/'Casks/chromakey.rb').write_text(cask)
    shutil.copy2(root/'packaging/verification_code_shortcut_download_strategy.rb',tap/'lib/verification_code_shortcut_download_strategy.rb')
    def git(*args):subprocess.run(['git','-C',str(tap),*args],check=True)
    git('config','user.name','github-actions[bot]')
    git('config','user.email','41898282+github-actions[bot]@users.noreply.github.com')
    renames_path = tap/'cask_renames.json'
    renames = json.loads(renames_path.read_text()) if renames_path.exists() else {}
    previous = renames.get('verification-code-shortcut')
    if previous not in (None, 'chromakey'): raise SystemExit(1)
    renames['verification-code-shortcut'] = 'chromakey'
    renames_path.write_text(json.dumps(renames, indent=2, sort_keys=True) + '\n')
    git('rm','--ignore-unmatch','Casks/verification-code-shortcut.rb')
    git('add','Casks/chromakey.rb','cask_renames.json','lib/verification_code_shortcut_download_strategy.rb')
    if subprocess.run(['git','-C',str(tap),'diff','--cached','--quiet']).returncode:
        git('commit','-m',f'chromakey {version}')
        for attempt in range(3):
            if subprocess.run(['git','-C',str(tap),'push','origin','HEAD:main']).returncode == 0:break
            git('pull','--rebase','origin','main')
        else:raise SystemExit(1)
key.unlink()
