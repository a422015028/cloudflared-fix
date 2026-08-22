#!/usr/bin/env bash
# ============================================================================
# build-android.sh —— cloudflared 安卓版一键编译脚本（含 DNS 修复）
#
# 用法:
#   ./build-android.sh [源码目录] [输出目录]
#   示例: ./build-android.sh ./cloudflared-2027.1.3 ./out
#
# 功能:
#   1. 自动检查/安装满足 go.mod 版本要求的 Go 工具链（无需 NDK）
#   2. 自动将同目录下的 android_dns.go 补丁复制进源码（不存在时）
#   3. 编译 android/arm64（PIE）+ linux/arm64、linux/arm、linux/amd64（纯静态，
#      同样可直接在安卓上运行，兼容 32 位设备与模拟器）
#   4. 生成 SHA256SUMS.txt 与 zip 包
#
# 可选环境变量:
#   GO=...                      指定已有 go 可执行文件路径
#   CLOUDFLARED_VERSION=...     覆盖自动识别的版本号
#   GO_MIRROR=...               Go 下载镜像（默认 https://dl.google.com/go，
#                               国内可设 https://mirrors.aliyun.com/golang）
# ============================================================================
set -euo pipefail

SRC_DIR="${1:-}"
OUT_DIR="${2:-./out-cloudflared-android}"
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_MIRROR="${GO_MIRROR:-https://dl.google.com/go}"
WORK_ROOT="${TMPDIR:-/tmp}/cloudflared-android-build"

OUT_DIR="$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 定位源码目录 ----------
if [[ -z "$SRC_DIR" ]]; then
    for d in "$PWD" "$PWD"/cloudflared-*; do
        [[ -f "$d/go.mod" && -d "$d/cmd/cloudflared" ]] && SRC_DIR="$d" && break
    done
fi
[[ -n "$SRC_DIR" && -f "$SRC_DIR/go.mod" ]] || die "未找到 cloudflared 源码目录（应包含 go.mod 与 cmd/cloudflared/），用法: $0 <源码目录> [输出目录]"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
log "源码目录: $SRC_DIR"

# ---------- 2. 注入 DNS 修复补丁 ----------
if [[ ! -f "$SRC_DIR/cmd/cloudflared/android_dns.go" ]]; then
    [[ -f "$FIX_DIR/android_dns.go" ]] || die "补丁文件 $FIX_DIR/android_dns.go 不存在"
    cp "$FIX_DIR/android_dns.go" "$SRC_DIR/cmd/cloudflared/android_dns.go"
    log "已注入 DNS 修复补丁 cmd/cloudflared/android_dns.go"
else
    log "DNS 修复补丁已存在，跳过注入"
fi

# 复制可选测试文件（存在时）
[[ -f "$FIX_DIR/android_dns_test.go" && ! -f "$SRC_DIR/cmd/cloudflared/android_dns_test.go" ]] && cp "$FIX_DIR/android_dns_test.go" "$SRC_DIR/cmd/cloudflared/" && log "已复制 android_dns_test.go"
[[ -f "$FIX_DIR/dns_androidfix_test.go" && ! -f "$SRC_DIR/ingress/origins/dns_androidfix_test.go" ]] && cp "$FIX_DIR/dns_androidfix_test.go" "$SRC_DIR/ingress/origins/" && log "已复制 dns_androidfix_test.go"

# ---------- 2b. 应用 ingress/origins/dns.go 第二补丁（修域名型源站解析 ERR） ----------
# 官方 DNSResolverService 用独立的 &net.Resolver{} 探测"本地 DNS"，不走被替换的
# net.DefaultResolver；安卓无 resolv.conf 时回退 [::1]:53 → 报
# "Failed to initialize DNS local resolver" 且每 5 分钟刷一次 ERR。
# 此补丁让 peekDial 拨号失败时回退公共 DNS。
patch_ingress_dns() {
    local f="$SRC_DIR/ingress/origins/dns.go"
    if [[ ! -f "$f" ]]; then
        warn "未找到 ingress/origins/dns.go，跳过第二补丁（官方可能已重构，若安卓日志仍报 'Failed to initialize DNS local resolver' 需人工适配）"
        return 0
    fi
    if grep -q 'androidFixProbeUDP' "$f"; then
        log "第二补丁 v2（ingress/origins/dns.go）已存在，跳过"
        return 0
    fi
    if grep -q 'android-dns-fix' "$f"; then
        warn "检测到旧版 v1 补丁（无 androidFixProbeUDP 标记）：v1 对 UDP 死回环地址存在误判（UDP dial 恒成功、失败在 read 阶段才暴露，导致回退不触发）。请用官方原始 ingress/origins/dns.go 覆盖此文件后重跑脚本升级到 v2"
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { warn "无 python3，跳过第二补丁"; return 0; }
    python3 - "$f" <<'PYEOF' || { warn "第二补丁应用失败（官方代码可能已变化），跳过——主 DNS 修复不受影响"; return 0; }
import re, sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
if "androidFixProbeUDP" in src:
    sys.exit(0)
# 1) add "runtime" import (keep gofmt alphabetical order)
src2, n1 = re.subn(r'(\t"net/netip"\n)', r'\1' + '\t"runtime"\n', src, count=1)
if n1 != 1:
    src2, n1 = re.subn(r'(\t"net"\n)', r'\1' + '\t"runtime"\n', src, count=1)
if n1 != 1:
    sys.exit(1)
# 2) replace peekDial with android-dns-fix v2
pattern = r"func \(r \*resolver\) peekDial\(ctx context\.Context, network, address string\) \(net\.Conn, error\) \{[\s\S]*?\n\}"
new = '''// android-dns-fix v2: on Android there is no /etc/resolv.conf, so the stdlib falls back
// to [::1]:53 / 127.0.0.1:53 where no DNS listener exists. Note that a UDP "dial" to
// those addresses always succeeds (UDP has no handshake); the failure only surfaces
// later at read time ("read: connection refused"), which is why a dial-error-only
// fallback (v1) never triggered. v2 detects loopback:53 targets and verifies real
// reachability (skipped on GOOS=android, where the system resolver never listens on
// loopback:53), then falls back to public resolvers. This fixes
// "Failed to initialize DNS local resolver" and keeps hostname-origin resolution working.
var androidFixFallbackDNS = []string{
\t"223.5.5.5:53",
\t"119.29.29.29:53",
\t"1.1.1.1:53",
\t"8.8.8.8:53",
}

const androidFixProbeTimeout = 500 * time.Millisecond

func androidFixIsLoopback53(address string) bool {
\thost, port, err := net.SplitHostPort(address)
\tif err != nil || port != "53" {
\t\treturn false
\t}
\tip := net.ParseIP(host)
\treturn ip != nil && ip.IsLoopback()
}

// androidFixProbeUDP sends a minimal DNS query ("." NS) and waits for any reply to
// determine whether a working UDP resolver actually exists behind a dialable address.
func androidFixProbeUDP(addr string, timeout time.Duration) bool {
\tc, err := net.DialTimeout("udp", addr, timeout)
\tif err != nil {
\t\treturn false
\t}
\tdefer c.Close()
\t_ = c.SetDeadline(time.Now().Add(timeout))
\t// minimal DNS query: header(RD=1, qdcount=1) + root qname + qtype=NS + qclass=IN
\tq := []byte{0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01}
\tif _, err := c.Write(q); err != nil {
\t\treturn false
\t}
\tbuf := make([]byte, 512)
\t_, err = c.Read(buf)
\treturn err == nil
}

func androidFixDialFallback(ctx context.Context, network string) (net.Conn, string, bool) {
\tfor _, srv := range androidFixFallbackDNS {
\t\tvar d net.Dialer
\t\tif c, e := d.DialContext(ctx, network, srv); e == nil {
\t\t\treturn c, srv, true
\t\t}
\t}
\treturn nil, "", false
}

func (r *resolver) peekDial(ctx context.Context, network, address string) (net.Conn, error) {
\tr.network = network
\tr.address = address
\tif androidFixIsLoopback53(address) {
\t\tdead := runtime.GOOS == "android" || !androidFixProbeUDP(address, androidFixProbeTimeout)
\t\tif dead {
\t\t\t// android-dns-fix: system resolver address unusable, use a public resolver
\t\t\tif conn, srv, ok := androidFixDialFallback(ctx, network); ok {
\t\t\t\tr.address = srv
\t\t\t\treturn conn, nil
\t\t\t}
\t\t}
\t}
\tconn, err := r.dialFunc(network, address)
\tif err != nil {
\t\t// android-dns-fix: retry with public resolvers (e.g. TCP dial to dead loopback)
\t\tif conn, srv, ok := androidFixDialFallback(ctx, network); ok {
\t\t\tr.address = srv
\t\t\treturn conn, nil
\t\t}
\t\treturn nil, err
\t}
\treturn conn, nil
}'''
out, n2 = re.subn(pattern, new, src2, count=1)
if n2 != 1:
    sys.exit(1)
open(path, "w", encoding="utf-8").write(out)
PYEOF
    if grep -q 'androidFixProbeUDP' "$f"; then
        log "已应用第二补丁 v2 ingress/origins/dns.go（回环:53 检测 + 真实 UDP 探测 + 公共 DNS 回退）"
    else
        warn "第二补丁 v2 未生效，跳过"
    fi
}
patch_ingress_dns

# ---------- 3. 准备 Go 工具链 ----------
ver_ge() {  # ver_ge 当前版本 要求版本 → 满足返回0
    local cur="$1" req="$2"
    [[ "$(printf '%s\n%s\n' "$req" "$cur" | sort -V | head -1)" == "$req" ]]
}

GO_BIN="${GO:-}"
if [[ -z "$GO_BIN" ]]; then
    if command -v go >/dev/null 2>&1; then GO_BIN="$(command -v go)";
    elif [[ -x "$WORK_ROOT/go/bin/go" ]]; then GO_BIN="$WORK_ROOT/go/bin/go";
    fi
fi

NEED_VER="$(awk '/^go [0-9]/ {print $2; exit}' "$SRC_DIR/go.mod")"
[[ -n "$NEED_VER" ]] || NEED_VER="1.22"
log "go.mod 要求 Go >= $NEED_VER"

if [[ -n "$GO_BIN" ]] && ver_ge "$("$GO_BIN" version | awk '{print $3}' | tr -d 'go')" "$NEED_VER"; then
    log "使用现有 Go: $GO_BIN ($("$GO_BIN" version | awk '{print $3}'))"
else
    log "需要下载 Go >= $NEED_VER ..."
    mkdir -p "$WORK_ROOT"
    # 从官方版本列表里找符合 major.minor 的最新补丁版本
    GO_FULL="$(curl -fsSL "https://go.dev/dl/?mode=json&include=all" \
        | grep -o "\"go1\\.[0-9]*\\.[0-9]*\"" \
        | tr -d '"' | awk -F. -v req="$NEED_VER" 'BEGIN{split(req,r,".")} {if ($2==r[1]) {print; exit}}')"
    [[ -n "$GO_FULL" ]] || GO_FULL="go${NEED_VER}.0"
    case "$(uname -m)" in
        x86_64)  GO_ARCH=amd64 ;;
        aarch64) GO_ARCH=arm64 ;;
        *) die "不支持的宿主架构: $(uname -m)" ;;
    esac
    log "下载 ${GO_FULL}.linux-${GO_ARCH}.tar.gz (镜像: $GO_MIRROR)"
    curl -fsSL -o "$WORK_ROOT/go.tgz" "$GO_MIRROR/${GO_FULL}.linux-${GO_ARCH}.tar.gz" \
        || die "Go 下载失败，可设置 GO_MIRROR=https://mirrors.aliyun.com/golang 重试"
    rm -rf "$WORK_ROOT/go" && tar -C "$WORK_ROOT" -xzf "$WORK_ROOT/go.tgz"
    GO_BIN="$WORK_ROOT/go/bin/go"
    log "Go 工具链就绪: $("$GO_BIN" version)"
fi

# ---------- 4. 版本号 ----------
VERSION="${CLOUDFLARED_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(cd "$SRC_DIR" && git describe --tags --always 2>/dev/null || true)"
    [[ -n "$VERSION" ]] || VERSION="$(basename "$SRC_DIR" | sed -E 's/^cloudflared-//')"
fi
VERSION="${VERSION}-dnsfix"
BUILD_TIME="$(date -u +%Y-%m-%d-%H:%M:%S-UTC)"
log "版本号: $VERSION"

# ---------- 5. 编译 ----------
mkdir -p "$OUT_DIR"
cd "$SRC_DIR"
export GOTOOLCHAIN=local CGO_ENABLED=0
if [[ -d "$SRC_DIR/vendor" ]]; then export GOFLAGS=-mod=vendor; fi
LDFLAGS="-s -w -X main.Version=$VERSION -X main.BuildTime=$BUILD_TIME"

build() {  # build <GOOS> <GOARCH>
    local goos="$1" goarch="$2"
    local out="$OUT_DIR/cloudflared-$goos-$goarch"
    log "编译 GOOS=$goos GOARCH=$goarch ..."
    if GOOS=$goos GOARCH=$goarch "$GO_BIN" build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/cloudflared; then
        log "成功: $out"
    else
        warn "编译失败: $goos/$goarch（android 32位/x86 需 NDK 外部链接；可用对应 linux 静态版替代）"
        rm -f "$out"
    fi
}

build android arm64   # 安卓 64 位主力版本（PIE）
build android arm     # 32 位安卓（需 NDK，失败可忽略）
build android amd64   # 模拟器（需 NDK，失败可忽略）
build linux  arm64    # 纯静态，arm64 安卓可直接运行
build linux  arm      # 纯静态，32 位安卓可直接运行
build linux  amd64    # 纯静态，x86 模拟器可直接运行

# ---------- 6. 校验与打包 ----------
cd "$OUT_DIR"
if [[ -x "$(command -v sha256sum)" ]]; then sha256sum cloudflared-* > SHA256SUMS.txt; fi
if [[ -x "$(command -v zip)" ]]; then zip -q "../cloudflared-${VERSION}-android.zip" cloudflared-* SHA256SUMS.txt && log "打包完成: ../cloudflared-${VERSION}-android.zip"; fi

log "全部完成。产物列表:"
ls -lh "$OUT_DIR"
log "安卓部署示例: adb push cloudflared-android-arm64 /data/local/tmp/cloudflared && adb shell chmod +x /data/local/tmp/cloudflared"
