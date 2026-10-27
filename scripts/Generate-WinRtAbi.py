"""Generate the fixed SDK interface catalogue and x64 transparent forwarders.

Only ABI declarations are consumed, never SDK collection implementations.
Regenerate with the exact SDK used by Build.ps1; review generated diffs.
"""
import pathlib
import re
import argparse
import os
import winreg

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sdk-root', type=pathlib.Path, help='Windows Kits/10 installation root')
parser.add_argument('--sdk-version', default='10.0.26100.0')
args = parser.parse_args()
sdk_root = args.sdk_root or os.environ.get('WindowsSdkDir')
if not sdk_root:
    for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\Microsoft\Windows Kits\Installed Roots', 0, winreg.KEY_READ | view) as key:
                sdk_root = winreg.QueryValueEx(key, 'KitsRoot10')[0]
                break
        except OSError:
            pass
if not sdk_root:
    parser.error('Windows SDK was not found; pass --sdk-root or use a developer shell')
if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', args.sdk_version):
    parser.error('Invalid SDK version')
SDK = pathlib.Path(sdk_root) / 'Include' / args.sdk_version / 'winrt'
files = ['windows.system.userprofile.h', 'windows.globalization.h',
         'windows.globalization.datetimeformatting.h',
         'windows.globalization.numberformatting.h']
lines = [f'// Generated from Windows SDK {args.sdk_version} by Generate-WinRtAbi.py.']
for file in files:
    source = (SDK / file).read_text(encoding='utf-8-sig')
    for match in re.finditer(r'MIDL_INTERFACE\("([^"]+)"\)\s*(\w+) : public IInspectable\s*\{(.*?)\n\s*\};', source, re.S):
        guid, name, body = match.groups()
        count = 6 + len(re.findall(r'virtual HRESULT STDMETHODCALLTYPE', body))
        p = guid.split('-')
        tail = bytes.fromhex(p[3] + p[4])
        value = '{0x%s,0x%s,0x%s,{%s}}' % (*p[:3], ','.join('0x%02x' % b for b in tail))
        lines.append(f'CDF_WINRT_ABI({name},{count},{value})')
(ROOT / 'include/runtime_winrt_catalog.inc').write_text('\n'.join(lines)+'\n')
asm = ['; Generated x64 tail forwarding: preserve stack arguments and XMM registers.',
       'option casemap:none', '.code']
for i in range(6, 40):
    asm += [f'public CdfWinrtForward{i}', f'CdfWinrtForward{i} proc', '  mov rcx, [rcx+16]', '  mov rax, [rcx]',
            f'  jmp qword ptr [rax+{i*8}]', f'CdfWinrtForward{i} endp']
asm.append('end')
(ROOT / 'src/runtime_winrt_forward.asm').write_text('\n'.join(asm)+'\n')
