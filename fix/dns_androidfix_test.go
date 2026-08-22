package origins

// dns_androidfix_test.go —— 验证第二补丁 v2（回环:53 检测 + UDP 可达性探测 + 公共 DNS 回退）

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

func echoUDPLoop(t *testing.T, pc net.PacketConn) {
	t.Helper()
	go func() {
		buf := make([]byte, 512)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = pc.WriteTo(buf[:n], addr)
		}
	}()
}

func TestAndroidFixIsLoopback53(t *testing.T) {
	cases := map[string]bool{
		"127.0.0.1:53":   true,
		"[::1]:53":       true,
		"127.0.0.53:53":  true,
		"192.168.1.1:53": false,
		"127.0.0.1:5353": false,
		"8.8.8.8:53":     false,
		"localhost:53":   false,
	}
	for in, want := range cases {
		if got := androidFixIsLoopback53(in); got != want {
			t.Errorf("androidFixIsLoopback53(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestAndroidFixProbeUDP(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("cannot listen udp: %v", err)
	}
	defer pc.Close()
	echoUDPLoop(t, pc)

	if !androidFixProbeUDP(pc.LocalAddr().String(), time.Second) {
		t.Fatalf("probe should succeed against echo server %s", pc.LocalAddr())
	}
}

// 核心场景：目标为回环:53（模拟安卓上无监听的 [::1]:53 / 127.0.0.1:53）时必须走回退。
// 无论走"探测判死"路径（GOOS=linux 且本机 53 无响应）还是"dialFunc 报错"路径，
// 最终都应拿到回退服务器的连接且 r.address 被更新为回退地址。
func TestPeekDialFallbackOnDeadLoopback(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("cannot listen udp: %v", err)
	}
	defer pc.Close()
	echoUDPLoop(t, pc)

	orig := androidFixFallbackDNS
	androidFixFallbackDNS = []string{pc.LocalAddr().String()}
	defer func() { androidFixFallbackDNS = orig }()

	r := &resolver{dialFunc: func(network, address string) (net.Conn, error) {
		return nil, errors.New("simulated dial failure")
	}}

	conn, err := r.peekDial(context.Background(), "udp", "127.0.0.1:53")
	if err != nil {
		t.Fatalf("peekDial should fall back to public resolver, got err: %v", err)
	}
	defer conn.Close()
	if r.address != pc.LocalAddr().String() {
		t.Fatalf("peek address = %q, want fallback %q", r.address, pc.LocalAddr().String())
	}

	// 回退连接应真实可用（能写能读到回显）
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatalf("write to fallback conn: %v", err)
	}
	buf := make([]byte, 64)
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Read(buf); err != nil {
		t.Fatalf("read from fallback conn: %v", err)
	}
}

// 正常路径：非回环目标不做探测，直接走 dialFunc；其错误在无可用回退时原样透传
func TestPeekDialNonLoopbackDirect(t *testing.T) {
	orig := androidFixFallbackDNS
	androidFixFallbackDNS = []string{} // 清空回退列表，聚焦验证 dialFunc 直通路径
	defer func() { androidFixFallbackDNS = orig }()

	r := &resolver{dialFunc: func(network, address string) (net.Conn, error) {
		return nil, errors.New("direct dial attempted")
	}}
	_, err := r.peekDial(context.Background(), "udp", "192.168.2.1:53")
	if err == nil || err.Error() != "direct dial attempted" {
		t.Fatalf("non-loopback should call dialFunc directly, got: %v", err)
	}
	if r.address != "192.168.2.1:53" {
		t.Fatalf("address = %q, want 192.168.2.1:53", r.address)
	}
}
