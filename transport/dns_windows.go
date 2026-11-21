package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"

	"claude-desktop-fake/network-transport/internal/connectionlog"
	"github.com/miekg/dns"
)

const (
	dnsRetry  = 11002
	dnsNoData = 11004
)

func resolveDNS(client *http.Client, wire []byte) (body []byte, record connectionlog.DNSRecord, result int) {
	var query dns.Msg
	if err := query.Unpack(wire); err != nil || query.Response || len(query.Question) != 1 {
		return nil, record, dnsRetry
	}
	q := query.Question[0]
	record.Name = strings.ToLower(strings.TrimSuffix(q.Name, "."))
	if record.Name == "" {
		record.Name = "."
	}
	if len(record.Name) > 255 {
		record.Name = record.Name[:252] + "..."
	}
	record.Type = dns.TypeToString[q.Qtype]
	if record.Type == "" {
		record.Type = fmt.Sprintf("TYPE%d", q.Qtype)
	}
	if q.Qtype == dns.TypeAAAA {
		record.Status = "blocked-ipv6"
		return nil, record, dnsNoData
	}
	record.Status = "transport-error"
	if client == nil {
		return nil, record, dnsRetry
	}
	request, err := http.NewRequest("POST", "https://cloudflare-dns.com/dns-query", bytes.NewReader(wire))
	if err != nil {
		return nil, record, dnsRetry
	}
	request.Header.Set("Content-Type", "application/dns-message")
	request.Header.Set("Accept", "application/dns-message")
	response, err := client.Do(request)
	if err != nil {
		return nil, record, dnsRetry
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, record, dnsRetry
	}
	body, err = io.ReadAll(io.LimitReader(response.Body, 65536))
	var parsed dns.Msg
	if err != nil || len(body) > 65535 || parsed.Unpack(body) != nil ||
		!parsed.Response || parsed.Id != query.Id || len(parsed.Question) != 1 ||
		parsed.Question[0].Qtype != q.Qtype || parsed.Question[0].Qclass != q.Qclass ||
		!strings.EqualFold(parsed.Question[0].Name, q.Name) {
		record.Status = "invalid-response"
		return nil, record, dnsRetry
	}
	var answer, authority, additional bool
	parsed.Answer, answer = ipv4DNSRecords(parsed.Answer)
	parsed.Ns, authority = ipv4DNSRecords(parsed.Ns)
	parsed.Extra, additional = ipv4DNSRecords(parsed.Extra)
	if answer || authority || additional {
		parsed.AuthenticatedData = false
		parsed.Compress = true
		body, err = parsed.Pack()
		if err != nil || len(body) > 65535 {
			record.Status = "invalid-response"
			return nil, record, dnsRetry
		}
	}
	if parsed.Rcode != dns.RcodeSuccess {
		record.Status = dns.RcodeToString[parsed.Rcode]
		if record.Status == "" {
			record.Status = fmt.Sprintf("RCODE%d", parsed.Rcode)
		}
		return body, record, 0
	}
	record.Status = "ok"
	if len(parsed.Answer) == 0 {
		record.Status = "no-data"
	}
	for _, rr := range parsed.Answer {
		if a, ok := rr.(*dns.A); ok {
			address := a.A.String()
			if !slices.Contains(record.Addresses, address) {
				record.Addresses = append(record.Addresses, address)
				if len(record.Addresses) == 12 {
					break
				}
			}
		}
	}
	return body, record, 0
}

func ipv4DNSRecords(records []dns.RR) ([]dns.RR, bool) {
	filtered := records[:0]
	changed := false
	for _, rr := range records {
		switch value := rr.(type) {
		case *dns.AAAA:
			changed = true
			continue
		case *dns.RRSIG:
			if value.TypeCovered == dns.TypeAAAA {
				changed = true
				continue
			}
		case *dns.SVCB:
			keep, edited := filterIPv6Hints(value)
			changed = changed || edited
			if !keep {
				continue
			}
		case *dns.HTTPS:
			keep, edited := filterIPv6Hints(&value.SVCB)
			changed = changed || edited
			if !keep {
				continue
			}
		}
		filtered = append(filtered, rr)
	}
	return filtered, changed
}

func filterIPv6Hints(record *dns.SVCB) (keep, changed bool) {
	for _, value := range record.Value {
		if mandatory, ok := value.(*dns.SVCBMandatory); ok && slices.Contains(mandatory.Code, dns.SVCB_IPV6HINT) {
			return false, true
		}
	}
	count := len(record.Value)
	record.Value = slices.DeleteFunc(record.Value, func(value dns.SVCBKeyValue) bool {
		return value.Key() == dns.SVCB_IPV6HINT
	})
	return true, count != len(record.Value)
}
