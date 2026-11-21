"""Read-only checks for source publication: links, personal paths and artifacts."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    root = args.root.resolve()
    if (root / '.git').exists():
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], check=True, capture_output=True)
        files = sorted({root / name.decode('utf-8') for name in result.stdout.split(b'\0') if name})
    else:
        excluded = {'.git', 'out', 'build', '.vs', '.idea', '__pycache__', 'local'}
        files = [p for p in root.rglob('*') if p.is_file() and not any(part in excluded for part in p.relative_to(root).parts)]
    private = re.compile(r'(?i)(?:[a-z]:[\\/](?:users[\\/]|project[\\/]|visualstudio[\\/]|windows kits[\\/]|cmake[\\/])|[\\/]\.codex[\\/]|[\\/]Documents[\\/]Codex[\\/])')
    extensions = {'.dll', '.exe', '.pdb', '.map', '.node', '.dmp', '.dpapi', '.zip', '.partial', '.pyc'}
    paths, links, binaries = [], [], []
    markdown = 0
    for path in files:
        relative = path.relative_to(root).as_posix()
        if path.suffix.lower() in extensions or path.name.lower().endswith('.netlog.json'):
            binaries.append(relative)
        if relative.startswith('third_party/'):
            continue  # Preserve upstream notices verbatim.
        text = path.read_text(encoding='utf-8-sig', errors='replace')
        for line, value in enumerate(text.splitlines(), 1):
            if private.search(value):
                paths.append({'file': relative, 'line': line})
        if path.suffix.lower() == '.md':
            markdown += 1
            prose = []
            fence = None
            for value in text.splitlines():
                marker = re.match(r'^[ ]{0,3}(`{3,}|~{3,})', value)
                if marker:
                    if not fence:
                        fence = marker[1]
                    elif marker[1][0] == fence[0] and len(marker[1]) >= len(fence):
                        fence = None
                elif not fence:
                    prose.append(value)
            for target in re.findall(r'\]\(([^)]+)\)', '\n'.join(prose)):
                target = target.strip().strip('<>')
                if not target or target.startswith('#') or urlsplit(target).scheme:
                    continue
                destination = unquote(target.split('#', 1)[0])
                if not (path.parent / destination).exists():
                    links.append({'file': relative, 'target': target})
    required = ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md', '.gitignore',
                'third_party/jsmn/LICENSE', 'third_party/cldr/LICENSE', 'third_party/runtime-notices/LICENSE',
                'transport/THIRD_PARTY_NOTICES.md', 'third_party/network-licenses/modules.json',
                'third_party/network-licenses/github.com_xtls_xray-core/LICENSE']
    missing = [name for name in required if not (root / name).is_file()]
    report = {'passed': not (paths or links or binaries or missing), 'checkedFiles': len(files), 'markdownFiles': markdown,
              'personalPaths': paths, 'brokenLinks': links, 'unexpectedArtifacts': binaries, 'missingFiles': missing}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
