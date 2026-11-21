package main

import (
	"bytes"
	"io"
	"net/http"
	"slices"
	"testing"

	"github.com/miekg/dns"
)

type dnsRoundTrip func(*http.Request) (*http.Response, error)

func (fn dnsRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func TestDNSQueriesAndIPv4Answers(t *testing.T) {
	query := new(dns.Msg).SetQuestion("service.example.", dns.TypeAAAA)
	calls := 0
	client := &http.Client{Transport: dnsRoundTrip(func(r *http.Request) (*http.Response, error) {
		calls++
		packet, err := io.ReadAll(r.Body)
		var request dns.Msg
		if err != nil || request.Unpack(packet) != nil {
			t.Fatal("invalid DoH query")
		}
		reply := new(dns.Msg).SetReply(&request)
		reply.AuthenticatedData = true
		for _, text := range []string{
			"service.example. 60 IN A 203.0.113.20",
			"service.example. 60 IN AAAA 2001:db8::20",
			"service.example. 60 IN HTTPS 1 . ipv4hint=203.0.113.20 ipv6hint=2001:db8::20",
		} {
			rr, err := dns.NewRR(text)
			if err != nil {
				t.Fatal(err)
			}
			reply.Answer = append(reply.Answer, rr)
		}
		reply.Extra = []dns.RR{reply.Answer[1]}
		wire := packDNS(t, reply)
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(wire))}, nil
	})}
	_, blocked, status := resolveDNS(client, packDNS(t, query))
	if status != dnsNoData || calls != 0 || blocked.Status != "blocked-ipv6" || blocked.Type != "AAAA" {
		t.Fatalf("AAAA was not rejected locally: %+v, %d calls, status %d", blocked, calls, status)
	}
	query.Question[0].Qtype = dns.TypeA
	wire, record, status := resolveDNS(client, packDNS(t, query))
	if status != 0 || calls != 1 || record.Status != "ok" || record.Name != "service.example" ||
		!slices.Equal(record.Addresses, []string{"203.0.113.20"}) {
		t.Fatalf("unexpected DNS result: %+v, %d calls, status %d", record, calls, status)
	}
	var parsed dns.Msg
	if err := parsed.Unpack(wire); err != nil || len(parsed.Answer) != 2 || len(parsed.Extra) != 0 ||
		parsed.AuthenticatedData {
		t.Fatalf("filtered DNS response is invalid: %+v, %v", parsed, err)
	}
	https, ok := parsed.Answer[1].(*dns.HTTPS)
	if !ok || len(https.Value) != 1 || https.Value[0].Key() != dns.SVCB_IPV4HINT {
		t.Fatalf("HTTPS IPv6 hints were not stripped: %v", parsed.Answer)
	}
}

func packDNS(t *testing.T, msg *dns.Msg) []byte {
	t.Helper()
	wire, err := msg.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return wire
}
