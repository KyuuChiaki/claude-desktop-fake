"""Apply the bounded, reproducible MPL-2.0 Xray transport changes in build output."""
import argparse
import hashlib
import json
import pathlib
import shutil

p = argparse.ArgumentParser()
p.add_argument('--source', required=True)
p.add_argument('--destination', required=True)
a = p.parse_args()
source, target = pathlib.Path(a.source).resolve(), pathlib.Path(a.destination).resolve()
if not (source / 'go.mod').is_file() or source == target:
    raise SystemExit('Invalid Xray source/destination')
relative = pathlib.Path('transport/internet/reality/reality.go')
text = (source / relative).read_text(encoding='utf-8')
if 'func UClient(' not in text or 'if !uConn.Verified {' not in text:
    raise SystemExit('Pinned REALITY layout changed')
for imported in ['gotls "crypto/tls"', '"io"', '"net/http"', '"regexp"', '"strings"', '"sync"', '"golang.org/x/net/http2"', '"github.com/xtls/xray-core/common/utils"']:
    text = text.replace('\t' + imported + '\n', '')
text = text.replace('time.Now().Unix()', 'CdfClock().Unix()')
text = text.replace('DNSName:       c.ServerName,', 'DNSName:       c.ServerName,\n\t\tCurrentTime: CdfClock(),')
verify_start = text.index('\topts := x509.VerifyOptions{')
verify_end = text.index('\nfunc UClient(', verify_start)
text = text[:verify_start] + '\treturn errors.New("CDF REALITY authenticated certificate rejected")\n}\n' + text[verify_end:]
text = text.replace('SessionTicketsDisabled: true,', 'SessionTicketsDisabled: true,\n\t\tTime: CdfClock,')
signature = 'func UClient(c net.Conn, config *Config, ctx context.Context, dest net.Destination) (net.Conn, error) {'
if text.count(signature) != 1:
    raise SystemExit('Pinned UClient signature changed')
text = text.replace(signature, signature.replace('(net.Conn, error)', '(result net.Conn, failure error)') +
                    '\n\tdefer func() { if failure != nil { cdfNotify(ctx, failure); _ = c.Close() } }()')
text = text[:text.index('\tif !uConn.Verified {')] + '''\tif !uConn.Verified {
        return nil, errors.New("CDF REALITY authentication rejected")
    }
    cdfNotify(ctx, nil)
    return uConn, nil
}

// CDF integration: no camouflage HTTP requests, spiders, or delayed failures.
// The clock is set once before any connection; channel ownership stays in Go.
type CdfHandshakeKey struct{}
var CdfClock = time.Now
func cdfNotify(ctx context.Context, failure error) {
    if ch, ok := ctx.Value(CdfHandshakeKey{}).(chan error); ok {
        select { case ch <- failure: default: }
    }
}
'''
marker = target / '.cdf-network-patch.json'
cnc_relative = pathlib.Path('common/net/cnc/connection.go')
cnc_source = (source / cnc_relative).read_text(encoding='utf-8')
cnc_text = cnc_source + '''
// CDF integration: retain TCP half-close semantics for the in-process bridge.
func (c *Connection) CloseWrite() error { return common.Close(c.writer) }
func (c *Connection) CloseRead() error { common.Interrupt(c.reader); return nil }
'''
if target.exists():
    if not marker.is_file():
        raise SystemExit('Refusing to overwrite an unowned Xray build directory')
    record = json.loads(marker.read_text())
    actual = hashlib.sha256((target / relative).read_bytes()).hexdigest()
    if actual != record['patchedSha256']:
        raise SystemExit('External Xray patch modification; preserving files')
    cnc_actual = hashlib.sha256((target / cnc_relative).read_bytes()).hexdigest()
    cnc_expected = record.get('cncPatchedSha256', hashlib.sha256((source / cnc_relative).read_bytes()).hexdigest())
    if cnc_actual != cnc_expected:
        raise SystemExit('External Xray connection modification; preserving files')
else:
    shutil.copytree(source, target)
(target / relative).write_text(text, encoding='utf-8', newline='\n')
(target / cnc_relative).write_text(cnc_text, encoding='utf-8', newline='\n')
record = {'upstream': 'v26.11.9', 'commit': '676eaf66f8f05d4d558ee7a74b4736623d3feeb9',
          'sourceSha256': hashlib.sha256((source / relative).read_bytes()).hexdigest(),
          'patchedSha256': hashlib.sha256((target / relative).read_bytes()).hexdigest(),
          'cncSourceSha256': hashlib.sha256((source / cnc_relative).read_bytes()).hexdigest(),
          'cncPatchedSha256': hashlib.sha256((target / cnc_relative).read_bytes()).hexdigest()}
marker.write_text(json.dumps(record, indent=2), encoding='utf-8')
print(json.dumps(record))
