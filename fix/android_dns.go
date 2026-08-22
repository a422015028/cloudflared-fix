package main

// android_dns.go —— 安卓 DNS 解析修复补丁（自包含文件，不修改官方任何源码）
//
// 【问题根因】
// Android 系统没有 /etc/resolv.conf，Go 的纯 Go DNS 解析器因此回退到内置默认
// 地址 127.0.0.1:53 / [::1]:53。而 Android 的系统 DNS 解析走 netd 私有 socket，
// 并不在本机 53 端口监听 UDP DNS，于是 cloudflared 的所有域名解析全部失败：
//
//	lookup _v2-origintunneld._tcp.argotunnel.com on [::1]:53:
//	read udp [::1]:xxxxx->[::1]:53: read: connection refused
//
// 官方代码自带的 DoT 兜底（edgediscovery/allregions/discovery.go，1.1.1.1:853，
// SNI=cloudflare-dns.com）在国内网络环境经常不可达；且即使 SRV 查询成功，后续
// 对 SRV 目标域名的 A 记录解析（net.LookupIP）仍走坏掉的默认解析器，同样失败。
//
// 【修复方案】
// 程序启动时（init 阶段）把全局 net.DefaultResolver 替换为自定义解析器：
//  1. 环境变量 CLOUDFLARED_DNS_SERVERS（逗号分隔，可带 :port）优先级最高，指定后不再混入其它候选；
//  2. Android 上通过 getprop 读取系统 DNS（net.dns1/net.dns2/dhcp.*.dns*）；
//  3. 内置公共 DNS 候选（国内优先，兼顾国际与 IPv6）；
//  4. 启动时对全部候选并发探测（解析 cloudflare.com），按响应速度排序，最快的排第一；
//  5. 实际查询时在候选列表中轮询（stdlib 每次查询/重试都会重新 Dial），
//     单个 DNS 服务器故障时同一次查询内自动换下一个，可自愈。
//
// 【启用条件】runtime.GOOS == "android"，或设置了环境变量，或 /etc/resolv.conf
// 缺失/为空。普通 Linux 环境（resolv.conf 正常）完全不生效，零影响。

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// 手动指定 DNS 服务器的环境变量，逗号分隔，如 "192.168.2.1,223.5.5.5"
	androidDNSFixEnv = "CLOUDFLARED_DNS_SERVERS"
	// 探测用的域名（稳定存在、记录较小）
	androidDNSProbeHost = "cloudflare.com"
	// 单个候选探测超时
	androidDNSProbeWait = 1500 * time.Millisecond
	// 实际查询时的拨号超时
	androidDNSDialWait = 5 * time.Second
)

// 内置公共 DNS 候选（国内优先，兼顾国际与 IPv6），探测后会按速度重排
var androidDNSCandidates = []string{
	"223.5.5.5:53",              // 阿里 AliDNS
	"119.29.29.29:53",           // 腾讯 DNSPod
	"114.114.114.114:53",        // 114DNS
	"1.1.1.1:53",                // Cloudflare
	"8.8.8.8:53",                // Google
	"[2400:3200::1]:53",         // 阿里 AliDNS IPv6
	"[2606:4700:4700::1111]:53", // Cloudflare IPv6
	"[2001:4860:4860::8888]:53", // Google IPv6
}

func init() {
	androidDNSFixInit()
}

func androidDNSFixInit() {
	envSet := strings.TrimSpace(os.Getenv(androidDNSFixEnv)) != ""

	need := runtime.GOOS == "android" || envSet
	if !need {
		// 覆盖“在安卓上跑 GOOS=linux 版二进制”的情况：resolv.conf 缺失或为空
		data, err := os.ReadFile("/etc/resolv.conf")
		if err != nil || len(strings.TrimSpace(string(data))) == 0 {
			need = true
		}
	}
	if !need {
		return
	}

	servers := androidDNSCandidateServers()
	if len(servers) == 0 {
		return
	}

	// 环境变量显式指定时不探测，直接按给定顺序使用；否则并发探测按速度排序
	if !envSet {
		servers = androidDNSProbe(servers)
	}

	// 轮询计数器：stdlib 解析器每次查询（含同一查询的重试）都会重新调用 Dial，
	// 在候选间轮询即可在单服务器故障时自动换下一个服务器
	var rr uint32
	net.DefaultResolver = &net.Resolver{
		PreferGo: true, // 强制纯 Go 解析器，确保 Dial 生效
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			i := int(atomic.AddUint32(&rr, 1)-1) % len(servers)
			d := net.Dialer{Timeout: androidDNSDialWait}
			return d.DialContext(ctx, network, servers[i])
		},
	}

	// 安卓或手动指定时打印一行提示，便于确认补丁生效（stderr，与 cloudflared 日志风格一致）
	if runtime.GOOS == "android" || envSet {
		fmt.Fprintf(os.Stderr, "INF android-dns-fix: default resolver overridden, dns servers in use: %s\n",
			strings.Join(servers, ", "))
	}
}

// androidDNSCandidateServers 按优先级收集候选 DNS：环境变量 > 安卓系统属性 > 内置列表
func androidDNSCandidateServers() []string {
	var list []string
	seen := map[string]bool{}
	add := func(s string) {
		s = androidDNSNormalize(s)
		if s == "" || seen[s] {
			return
		}
		seen[s] = true
		list = append(list, s)
	}

	if env := strings.TrimSpace(os.Getenv(androidDNSFixEnv)); env != "" {
		for _, s := range strings.Split(env, ",") {
			add(s)
		}
		return list // 用户显式指定：不混入其它候选
	}

	if runtime.GOOS == "android" {
		for _, key := range []string{
			"net.dns1", "net.dns2", "net.dns3", "net.dns4",
			"dhcp.wlan0.dns1", "dhcp.wlan0.dns2",
			"dhcp.eth0.dns1", "dhcp.eth0.dns2",
		} {
			if out, err := exec.Command("/system/bin/getprop", key).Output(); err == nil {
				add(strings.TrimSpace(string(out)))
			}
		}
	}

	for _, s := range androidDNSCandidates {
		add(s)
	}
	return list
}

// androidDNSNormalize 把 "1.1.1.1" / "1.1.1.1:53" / "::1" / "[::1]:53" 统一成带端口的规范形式
func androidDNSNormalize(s string) string {
	s = strings.TrimSpace(s)
	if s == "" || strings.ContainsAny(s, " \t") { // getprop 空值或异常输出
		return ""
	}
	if _, _, err := net.SplitHostPort(s); err == nil {
		return s // 已带端口（IPv6 已带方括号）
	}
	if strings.Contains(s, ":") {
		return "[" + s + "]:53" // 裸 IPv6 字面量
	}
	return s + ":53"
}

// androidDNSProbe 并发探测所有候选（各查一次 cloudflare.com），按响应耗时从快到慢排序；
// 探测失败的候选保留在列表末尾作为兜底（网络恢复后仍可用）。
func androidDNSProbe(servers []string) []string {
	type probeResult struct {
		idx     int
		elapsed time.Duration
	}
	results := make(chan probeResult, len(servers))
	var wg sync.WaitGroup

	for i, srv := range servers {
		wg.Add(1)
		go func(idx int, server string) {
			defer wg.Done()
			r := &net.Resolver{
				PreferGo: true,
				Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, network, server)
				},
			}
			ctx, cancel := context.WithTimeout(context.Background(), androidDNSProbeWait)
			defer cancel()
			start := time.Now()
			if _, err := r.LookupHost(ctx, androidDNSProbeHost); err != nil {
				return
			}
			results <- probeResult{idx, time.Since(start)}
		}(i, srv)
	}
	wg.Wait()
	close(results)

	var ok []probeResult
	for r := range results {
		ok = append(ok, r)
	}
	if len(ok) == 0 {
		return servers // 全部失败（可能网络暂不可用）：保持原顺序
	}
	sort.Slice(ok, func(a, b int) bool { return ok[a].elapsed < ok[b].elapsed })

	used := make(map[int]bool, len(ok))
	ordered := make([]string, 0, len(servers))
	for _, r := range ok {
		ordered = append(ordered, servers[r.idx])
		used[r.idx] = true
	}
	for i, s := range servers {
		if !used[i] {
			ordered = append(ordered, s)
		}
	}
	return ordered
}
