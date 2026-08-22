package main

// android_dns_test.go —— 临时验证文件（验证 android_dns.go 的修复逻辑），不随补丁分发

import (
	"context"
	"net"
	"testing"
	"time"
)

func TestAndroidDNSNormalize(t *testing.T) {
	cases := map[string]string{
		"1.1.1.1":     "1.1.1.1:53",
		"1.1.1.1:53":  "1.1.1.1:53",
		"::1":         "[::1]:53",
		"[::1]:53":    "[::1]:53",
		"  8.8.8.8  ": "8.8.8.8:53",
		"":            "",
		" ":           "",
	}
	for in, want := range cases {
		if got := androidDNSNormalize(in); got != want {
			t.Errorf("normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAndroidDNSCandidateServers(t *testing.T) {
	t.Setenv("CLOUDFLARED_DNS_SERVERS", "192.168.2.1, 223.5.5.5:53, [::1]:53")
	servers := androidDNSCandidateServers()
	want := []string{"192.168.2.1:53", "223.5.5.5:53", "[::1]:53"}
	if len(servers) != len(want) {
		t.Fatalf("got %v, want %v", servers, want)
	}
	for i := range want {
		if servers[i] != want[i] {
			t.Fatalf("got %v, want %v", servers, want)
		}
	}
}

// 端到端验证：探测候选 -> 用排序第一的服务器真实解析 argotunnel.com
// 若沙箱环境禁止 UDP/53 直连外网，此测试可能失败，属环境限制而非代码问题。
func TestAndroidDNSOverrideE2E(t *testing.T) {
	t.Setenv("CLOUDFLARED_DNS_SERVERS", "")
	servers := androidDNSCandidateServers()
	if len(servers) == 0 {
		t.Fatal("no candidate servers")
	}
	ordered := androidDNSProbe(servers)
	t.Logf("probe ordered servers: %v", ordered)

	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, network, ordered[0])
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	addrs, err := r.LookupHost(ctx, "argotunnel.com")
	if err != nil {
		t.Skipf("lookup via %s failed (sandbox may block direct UDP/53 egress): %v", ordered[0], err)
	}
	t.Logf("resolved argotunnel.com via %s -> %v", ordered[0], addrs)
}
