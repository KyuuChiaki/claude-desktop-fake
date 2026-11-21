module claude-desktop-fake/network-transport

go 1.27

require (
	github.com/miekg/dns v1.1.73
	github.com/xtls/xray-core v0.0.0
	go.yaml.in/yaml/v3 v3.0.5
	golang.org/x/crypto/x509roots/fallback v0.0.0-20261020153306-9f2b28d4331a
	golang.org/x/sys v0.49.0
)

require (
	github.com/apernet/quic-go v0.61.1-0.20260806010916-184d081eef3e // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/juju/ratelimit v1.0.2 // indirect
	github.com/klauspost/compress v1.20.1 // indirect
	github.com/klauspost/cpuid/v2 v2.4.2 // indirect
	github.com/kr/text v0.2.0 // indirect
	github.com/molecule-man/go-brrr v1.2.0 // indirect
	github.com/pires/go-proxyproto v0.16.0 // indirect
	github.com/quic-go/qpack v0.6.0 // indirect
	github.com/refraction-networking/utls v1.8.3-0.20261108164504-a13c59ffe98b // indirect
	github.com/xtls/reality v0.0.0-20261108101329-4bb46b2afd8b // indirect
	github.com/yuin/gopher-lua v1.1.2 // indirect
	go4.org/netipx v0.0.0-20231129151722-fdeea329fbba // indirect
	golang.org/x/crypto v0.58.0 // indirect
	golang.org/x/exp v0.0.0-20240506185415-9bf2ced13842 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sync v0.24.0 // indirect
	golang.org/x/text v0.43.0 // indirect
	google.golang.org/grpc v1.85.0 // indirect
	google.golang.org/protobuf v1.36.12 // indirect
	layeh.com/gopher-luar v1.0.11 // indirect
	lukechampine.com/blake3 v1.4.1 // indirect
)

replace github.com/xtls/xray-core => ../out/network-dependencies/xray
