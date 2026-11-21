"""Collect notices for the exact modules recorded in the built transport DLL.

Reads only the verified local module cache; never downloads module contents.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--cache', type=Path, required=True)
parser.add_argument('--build-info', type=Path, required=True)
parser.add_argument('--xray', type=Path, required=True)
parser.add_argument('--go-root', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
args = parser.parse_args()

def escaped(value):
    return ''.join('!' + c.lower() if c.isupper() else c for c in value)

records = []
for line in args.build_info.read_text(encoding='utf-8-sig').splitlines():
    fields = line.strip().split('\t')
    if not fields or fields[0] != 'dep':
        continue
    module, version = fields[1:3]
    folder = args.xray if module == 'github.com/xtls/xray-core' else args.cache / (escaped(module) + '@' + version)
    identifier = re.sub(r'[^a-zA-Z0-9._-]', '_', module)
    destination = args.destination / identifier
    notices = [p for p in folder.iterdir() if p.is_file() and re.match(r'(?i)^(license|copying|notice|copyright)', p.name)] if folder.is_dir() else []
    # Some modules carry an additional Unicode/data notice in subdirectories.
    if module.startswith('golang.org/x/') and folder.is_dir():
        notices += [p for p in folder.rglob('LICENSE*') if p.is_file() and p not in notices]
    if not notices:
        raise SystemExit('Missing source/license in local cache: ' + module)
    destination.mkdir(parents=True, exist_ok=True)
    files = []
    for source in notices:
        relative = source.relative_to(folder)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        files.append({'file': str(target.relative_to(args.destination)).replace('\\', '/'), 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
    records.append({'module': module, 'version': version, 'goSum': fields[3] if len(fields) > 3 else None, 'notices': files})

go_license = args.destination / 'go' / 'LICENSE'
go_license.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(args.go_root / 'LICENSE', go_license)
(args.destination / 'modules.json').write_text(json.dumps(records, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'modules': len(records), 'destination': str(args.destination)}))
