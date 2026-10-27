"""Read Claude's package without running the application or altering its files."""
import argparse, hashlib, json, pathlib, struct

p = argparse.ArgumentParser()
p.add_argument('--app', required=True, type=pathlib.Path)
p.add_argument('--output', required=True, type=pathlib.Path)
a = p.parse_args()
exe = a.app / 'claude.exe'
data = exe.read_bytes()
sentinel = b'dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX'
pos = data.find(sentinel)
fuses = {}
if pos >= 0:
    version, count = data[pos + len(sentinel):pos + len(sentinel) + 2]
    names = ['RunAsNode', 'EnableCookieEncryption', 'EnableNodeOptionsEnvironmentVariable',
             'EnableNodeCliInspectArguments', 'EnableEmbeddedAsarIntegrityValidation',
             'OnlyLoadAppFromAsar', 'LoadBrowserProcessSpecificV8Snapshot',
             'GrantFileProtocolExtraPrivileges']
    fuses = {'version': version, 'raw': data[pos+len(sentinel)+2:pos+len(sentinel)+2+count].decode('ascii'),
             'values': {names[i] if i < len(names) else str(i): chr(x)
                        for i, x in enumerate(data[pos+len(sentinel)+2:pos+len(sentinel)+2+count])}}
asar = a.app / 'resources' / 'app.asar'
with asar.open('rb') as f:
    head = f.read(16)
    size = struct.unpack_from('<I', head, 12)[0]
    tree = json.loads(f.read(size))
    header_size = struct.unpack_from('<I', head, 4)[0] + 8
    files = []
    def walk(node, prefix=''):
        for name, item in node.get('files', {}).items():
            path = prefix + name
            if 'files' in item:
                walk(item, path + '/')
            else:
                files.append((path, item))
    walk(tree)
    package = {}
    for path, item in files:
        if path == 'package.json':
            f.seek(header_size+int(item['offset']))
            package = json.loads(f.read(item['size']))
    matches = []
    terms = (b'getPreferredSystemLanguages', b'getCreationTime', b'acceptLanguages',
             b'navigator.language', b'process.versions', b'process.env.TZ')
    for path, item in files:
        if item.get('unpacked') or not path.endswith(('.js','.json','.cjs','.mjs')) or item.get('size',0)>25_000_000:
            continue
        f.seek(header_size+int(item['offset']))
        content=f.read(item['size'])
        for term in terms:
            at=content.find(term)
            if at>=0:
                matches.append({'path':path,'term':term.decode(),'offset':at,
                                'snippet':content[max(0,at-150):at+250].decode('utf8','replace')})
report={'method':'static package inspection; no Claude process launched', 'executable':str(exe),
        'sha256':hashlib.sha256(data).hexdigest(), 'electronVersionFile':(a.app/'version').read_text().strip(),
        'fuses':fuses,'asarPackage':package,'asarFileCount':len(files),'runtimeSourceReferences':matches}
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:report[k] for k in ('method','electronVersionFile','fuses','asarFileCount')},ensure_ascii=False))
