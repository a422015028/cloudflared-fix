# cloudflared 安卓 DNS 53 端口解析问题修复与编译指南

> **本文档用途**：cloudflared 官方发布新版本后，把本文档连同 `fix/` 目录交给 AI，
> AI 按第 3 节流程即可自动完成"打补丁 → 编译 → 交付安卓可用二进制"全流程。
> 适用版本：2026.8.2（已实测），理论上适配所有近期版本（补丁为独立文件，不改动官方源码）。

---

## 1. 问题现象与根因

### 1.1 现象（日志特征）

在安卓上运行 cloudflared（adb shell 或 Termux，无 root），日志出现：

```
ERR Failed to fetch features ... error="lookup cfd-features.argotunnel.com on [::1]:53: read udp [::1]:49259->[::1]:53: read: connection refused"
ERR edge discovery: error looking up Cloudflare edge IPs: the DNS query failed
    error="lookup _v2-origintunneld._tcp.argotunnel.com on [::1]:53: read udp ... connection refused"
ERR Initiating shutdown error="Could not lookup srv records on _v2-origintunneld._tcp.argotunnel.com: ..."
```

随后进程退出，隧道无法建立。

### 1.2 根因（两层）

1. **主因**：Android 系统没有 `/etc/resolv.conf` 文件。cloudflared 用纯 Go 编译
   （`CGO_ENABLED=0`），Go 的纯 Go DNS 解析器找不到 resolv.conf 时会回退到内置
   默认地址 `127.0.0.1:53` / `[::1]:53`。而 Android 的系统 DNS 解析走 netd 的
   私有 socket（`/dev/socket/dnsproxyd`），**本机 53 端口上没有任何 DNS 服务**，
   所以每次 UDP 查询都得到 `connection refused`，所有域名解析全部失败。
2. **官方兜底也失效**：官方在 `edgediscovery/allregions/discovery.go` 里有 DoT
   兜底（`lookupSRVWithDOT`，拨 `1.1.1.1:853`，SNI=`cloudflare-dns.com`）。
   该地址/SNI 在国内网络环境经常不可达，兜底失败；且即使 SRV 查询成功，后续
   对 SRV 目标域名的 A 记录解析（`net.LookupIP`）仍走坏掉的默认解析器，照样失败。

### 1.3 为什么手机能上网但 cloudflared 解析不了

安卓 App 和系统进程通过 netd/binder 查 DNS（私有通道），不经过本机 UDP 53。
独立编译的纯 Go 二进制没有这条通道，只能自己发 UDP 53 查询，却拿不到系统
DNS 服务器地址（没有 resolv.conf 可读）。**修复思路就是：主动探测/指定可用的
外部 DNS 服务器，替换 Go 的全局解析器。**

---

## 2. 修复方案原理

新增一个自包含文件 `cmd/cloudflared/android_dns.go`（**不修改官方任何现有文件**，
与官方代码零冲突，任何新版本都能直接复用）。它在程序 `init()` 阶段：

1. 判断是否需要修复：`GOOS=android`，或环境变量 `CLOUDFLARED_DNS_SERVERS` 已设置，
   或 `/etc/resolv.conf` 缺失/为空（覆盖"在安卓上跑 linux 版二进制"的场景）。
2. 收集候选 DNS，按优先级：环境变量 > `getprop` 读取的安卓系统 DNS
   （`net.dns1/2`、`dhcp.wlan0.dns1/2` 等）> 内置公共 DNS
   （阿里 223.5.5.5、DNSPod 119.29.29.29、114、Cloudflare 1.1.1.1、Google 8.8.8.8 及 IPv6）。
3. 并发探测所有候选（各解析一次 `cloudflare.com`，1.5s 超时），按响应速度排序。
4. 用探测结果替换全局 `net.DefaultResolver`（`PreferGo: true` + 自定义 `Dial`），
   查询时在候选间轮询，单个 DNS 服务器故障可自愈。
5. 生效时向 stderr 打一行 `INF android-dns-fix: ...` 便于确认。

影响范围：cloudflared 的边缘节点发现（SRV + A 记录）、features 获取、API/token
域名解析等所有走默认解析器的查询全部修复；官方自带的 DoT 兜底、DNS 代理模式
（proxydns）等自定义解析器不受影响。普通 Linux（resolv.conf 正常）环境完全不生效。

### 2.1 第二补丁：ingress/origins/dns.go（修域名型源站解析 ERR）

**现象**：主补丁生效、隧道连接全部成功后，日志仍有一条（且每 5 分钟重复一次）：

```
ERR Failed to initialize DNS local resolver error="lookup region1.v2.argotunnel.com on [::1]:53: ... connection refused"
```

**根因**：官方 `DNSResolverService`（用于解析 ingress 规则里**域名型**源站，
见 `cmd/cloudflared/tunnel/configuration.go`）在初始化/刷新时自己构造
`&net.Resolver{PreferGo: true, Dial: peekDial}` 去**探测系统本地 DNS 地址**——
它不经过被替换的 `net.DefaultResolver`。安卓无 resolv.conf，stdlib 回退
`[::1]:53`，拨号被拒 → 探测失败。源站是 IP（如 `http://127.0.0.1:8765`）时
功能无损，仅日志噪音；源站是域名时该组件不可用。

**修复（v2）**：修改同文件 `peekDial`，逻辑分两层：
- **回环：53 目标检测**（`androidFixIsLoopback53`）：目标是 `127.x.x.x:53` / `[::1]:53` 时，
  `GOOS=android` 直接判死（安卓系统解析器从不在回环 53 监听）；其它系统先用
  `androidFixProbeUDP` 发一个最小 DNS 查询（`.` NS）确认真实可达——**不能只看 dial 结果**，
  因为 UDP 的 dial 不做握手、连无监听的 `[::1]:53` 也会"成功"，失败要到 read 阶段才暴露
  （v1 补丁正是踩了这个坑：dial 成功即放行，回退永远不触发，ERR 照旧）。
- **判死后回退公共 DNS**（223.5.5.5 → 119.29.29.29 → 1.1.1.1 → 8.8.8.8），成功后把服务地址
  更新为回退服务器；dialFunc 报错（如 TCP 连死回环被 RST）时同样回退。

改动带 `androidFixProbeUDP` / `android-dns-fix` 标记；`build-android.sh` 用 python3 正则自动
应用（含自动插入 `runtime` 导入），官方重构导致匹配失败时自动跳过并告警（不影响主修复）。
参考 diff：`fix/ingress-origins-dns.android-fix.patch`。

---

## 3. 官方更新后的一键操作流程（给 AI 的指令）

> 新版本发布后，向 AI 说：
> **"cloudflared 出了新版本 XXX，按《安卓cloudflared-DNS修复与编译指南.md》第 3 节流程，
> 下载官方源码、应用 fix/ 目录补丁并编译安卓版"** 即可。

> 若已按第 9 节把本项目部署到 GitHub Actions，则上述流程全自动执行，无需人工介入。

AI 执行步骤：

1. **获取官方源码**
   - 下载官方 release 源码包：`https://github.com/cloudflare/cloudflared/archive/refs/tags/<版本号>.zip`
     （或使用用户已下载的源码 zip），解压。
   - 或 git 克隆后 checkout 对应 tag。
2. **检查源码结构适配性**（见第 6 节检查点，全部满足才继续）
3. **注入补丁**：把 `fix/android_dns.go` 复制到源码的 `cmd/cloudflared/` 目录下；
   同时对 `ingress/origins/dns.go` 应用第二补丁（peekDial 公共 DNS 回退）。
   （可选：把 `fix/android_dns_test.go`、`fix/dns_androidfix_test.go` 也复制过去用于自测）
   两个补丁均由脚本自动完成。
4. **运行一键编译**：
   ```bash
   bash fix/build-android.sh <源码目录> <输出目录>
   ```
   脚本自动：检查/下载符合 go.mod 版本要求的 Go 工具链 → 注入补丁（若未注入）→
   编译 android/arm64（PIE）及 linux/arm64、arm、amd64 纯静态版 → 生成 SHA256SUMS 与 zip。
5. **验证**（见第 5 节清单），交付二进制与使用说明。

### 3.1 手动编译命令（脚本不可用时）

```bash
# 要求: Go 版本 >= 源码 go.mod 里的 "go x.y" 行；无需 Android NDK
cd <源码目录>
export GOTOOLCHAIN=local CGO_ENABLED=0 GOFLAGS=-mod=vendor   # 无 vendor 目录时去掉 GOFLAGS
BT=$(date -u +%Y-%m-%d-%H:%M:%S-UTC)
VER=<版本号>-dnsfix

# 安卓 64 位主力版本（PIE，标准安卓可执行文件）
GOOS=android GOARCH=arm64 go build -trimpath \
  -ldflags "-s -w -X main.Version=$VER -X main.BuildTime=$BT" \
  -o cloudflared-android-arm64 ./cmd/cloudflared

# 纯静态兜底版本（同样可直接在安卓跑，兼容 32 位设备/模拟器）
for arch in arm64 arm amd64; do
  GOOS=linux GOARCH=$arch go build -trimpath \
    -ldflags "-s -w -X main.Version=$VER -X main.BuildTime=$BT" \
    -o cloudflared-linux-$arch ./cmd/cloudflared
done
```

---

## 4. 安卓部署方法

```bash
adb push cloudflared-android-arm64 /data/local/tmp/cloudflared
adb shell chmod +x /data/local/tmp/cloudflared
adb shell /data/local/tmp/cloudflared --version          # 应显示版本号，无 DNS 报错
# 沿用原有启动方式（token 文件等），例如：
adb shell /data/local/tmp/cloudflared --no-autoupdate tunnel run --token-file /data/local/tmp/cloudflared/token
```

- 手动指定 DNS（可选）：`CLOUDFLARED_DNS_SERVERS=192.168.2.1,223.5.5.5`，
  逗号分隔，可带端口；设置后跳过探测直接使用。
- 成功标志：日志**不再出现** `on [::1]:53 ... connection refused`，且启动时有一行
  `INF android-dns-fix: default resolver overridden, dns servers in use: ...`。

---

## 5. 验证清单

编译期（AI 必做）：

| 项目 | 方法 | 预期 |
|---|---|---|
| 补丁已注入 | 源码存在 `cmd/cloudflared/android_dns.go` | 存在 |
| 第二补丁 v2 已应用 | `grep -c 'androidFixProbeUDP' ingress/origins/dns.go` 且 `grep -q '"runtime"' ingress/origins/dns.go` | 计数 ≥ 1 且导入存在 |
| 单元测试 | `go test ./cmd/cloudflared ./ingress/origins -run 'TestAndroidDNS\|TestPeekDial' -v`（需先复制两个测试文件） | PASS/SKIP（沙箱禁 UDP 时 E2E 为 SKIP，正常） |
| 本机冒烟 | 编译 linux/amd64 版并执行 `CLOUDFLARED_DNS_SERVERS=223.5.5.5 ./cloudflared --version` | 打印 `INF android-dns-fix: ...` + 版本号 |
| 静默验证 | 不带环境变量执行 `./cloudflared --version` | 无 `android-dns-fix` 输出（正常 Linux 不干扰） |
| 产物格式 | `file cloudflared-android-arm64` | `ELF 64-bit LSB pie executable, ARM aarch64, interpreter /system/bin/linker64` |

运行期（真机，用户或 AI 通过 adb 验证）：

| 项目 | 预期 |
|---|---|
| `--version` | 正常打印版本 |
| `tunnel run` 日志 | 无 `[::1]:53 connection refused`；出现 `INF android-dns-fix`；无 `Failed to initialize DNS local resolver` / `Failed to refresh DNS local resolver` |
| 边缘发现 | `Registered tunnel connection` 成功（最终目标） |

---

## 6. 官方代码结构变化的适配检查点

每次对官方新版本打补丁前，AI 须确认：

1. `cmd/cloudflared/main.go` 仍是 `package main`（补丁文件与其同包）。若官方
   重构了入口目录，找到新的 main 包目录放入 `android_dns.go` 即可。
2. 官方没有新增 `cmd/cloudflared/android_dns.go` 同名文件（有则覆盖即可，用本补丁版本）。
3. `main.go` 中版本变量仍为 `main.Version` / `main.BuildTime`（ldflags 注入用）；
   若官方改名，同步修改编译命令中的 `-X` 目标。查看方法：
   `grep -n 'Version\s*=' cmd/cloudflared/main.go`
4. go.mod 的 Go 版本要求（`go x.y` 行）——用不低于它的 Go 工具链编译。
5. 第二补丁锚点：`ingress/origins/dns.go` 里存在 `func (r *resolver) peekDial(...)`
   及 `"net/netip"` 导入行（脚本自动检查并应用 v2；标记为 `androidFixProbeUDP`）。
   若检测到只有 `android-dns-fix` 标记而无 `androidFixProbeUDP`（旧 v1），脚本会告警，
   需用官方原始 dns.go 覆盖后重跑。若官方重构导致正则不匹配，脚本跳过并告警，此时按
   `fix/ingress-origins-dns.android-fix.patch` 的思路人工适配：回环:53 目标需做真实
   UDP 探测（不能只看 dial 成败）+ 公共 DNS 回退。
6. 若官方未来自己修复了安卓 DNS（可用特征：源码里出现读取 Android 系统 DNS 或
   自定义 DefaultResolver 的逻辑，或 `cmd/cloudflared/` 有 android 相关文件），
   则本补丁可以停用，改用官方方案验证。

---

## 7. 故障排查

| 症状 | 原因与处理 |
|---|---|
| `android/arm requires external (cgo) linking` | 32 位安卓 PIE 需要 NDK；直接用 `cloudflared-linux-arm`（纯静态）替代 |
| 启动卡 1~2 秒 | 正常现象：并发探测 DNS（上限 1.5s，仅启动一次） |
| 探测全失败但查询正常 | 网络恢复后轮询自愈，无需处理 |
| 仍出现 `[::1]:53` 报错 | 补丁未生效：确认 `GOOS=android`、或 resolv.conf 缺失、或设置了环境变量；确认二进制是本次编译产物 |
| `Failed to initialize/refresh DNS local resolver` | 第二补丁未应用或为旧 v1（v1 因 UDP dial 恒成功而失效）：按 `fix/ingress-origins-dns.android-fix.patch`（v2）适配；源站为 IP 时此错仅为日志噪音 |
| DNS 结果被污染 | 设置 `CLOUDFLARED_DNS_SERVERS` 指定可信 DNS（如 `223.5.5.5` 或自建）；域名型源站回退列表可编辑 `dns.go` 补丁里的 `androidFixFallbackDNS` |
| IPv6-only 网络 | 候选列表已含 IPv6 公共 DNS，探测会自动排序；必要时环境变量手动指定 |
| 想改内置 DNS 列表 | 编辑 `android_dns.go` 中 `androidDNSCandidates` 变量 |

---

## 8. 本次交付物清单（2026.8.2 实测版，双补丁）

- `cloudflared-2026.8.2-dnsfix-android.zip`：全部二进制 + SHA256SUMS
  - `cloudflared-android-arm64`：安卓 64 位标准 PIE 版（**主力推荐**）
  - `cloudflared-linux-arm64` / `-arm` / `-amd64`：纯静态兜底版（32 位设备、模拟器可用）
- `fix/android_dns.go`：主修复补丁（替换全局解析器，可直接用于任何未来版本）
- `fix/ingress-origins-dns.android-fix.patch`：第二补丁 v2 参考 diff（回环:53 检测 + 真实 UDP 探测 + 公共 DNS 回退）
- `fix/android_dns_test.go`、`fix/dns_androidfix_test.go`：两个补丁的自测用例（可选）
- `fix/build-android.sh`：一键编译脚本（自动装 Go、注入双补丁、编译、打包；v1→v2 升级时会告警提示还原官方 dns.go）
- `fix/README.md`：fix 目录简要说明

实测环境：Go 1.26.4、cloudflared 2026.8.2 官方源码、CGO_ENABLED=0、无需 NDK。
真机验证（主补丁）：arm64 安卓（GOOS=android 构建），隧道 4 连接全部注册
（QUIC，hkg 节点），连通性预检 7 项全 PASS。第二补丁 v1 真机复测发现 UDP dial
恒成功导致回退未触发（ERR 残留），已升级 v2（回环检测 + 真实探测，4 项单元测试
全过）；v2 真机复验以日志不再出现
`Failed to initialize/refresh DNS local resolver` 为准。

---

## 9. GitHub Actions 全自动流水线（推荐）

> 把本项目推送到 GitHub 仓库后，`.github/workflows/auto-build.yml` 会全自动完成
> **检测官方更新 → 注入双补丁 → 编译 → 测试 → 发布 Release**，官方每次发版无需任何人工操作。

### 9.1 工作方式

| 环节 | 说明 |
|---|---|
| 触发 | 定时每天 2 次（北京时间 02:23 / 14:23）；`fix/` 或 workflow 变更的 push；手动 dispatch |
| 检测 | 查询 cloudflare/cloudflared 最新**稳定版** tag（跳过 prerelease/draft/beta/rc） |
| 判定 | 本仓库不存在 `<官方版本>-dnsfix` Release 时才构建（避免重复构建） |
| 构建 | 下载官方源码 zip → 按 go.mod 自动安装对应版本 Go（含模块缓存） → 调用 `fix/build-android.sh` 注入双补丁并编译 |
| 验证 | 指南第 6 节适配性检查点 → 两补丁单元测试 → linux/amd64 冒烟测试（验证版本注入 + `android-dns-fix` 生效日志） |
| 发布 | 创建 `<官方版本>-dnsfix` Release：android-arm64 + 3 个 linux 静态版 + 打包 zip + SHA256SUMS + 中文发布说明 |

手动触发（Actions → cloudflared 官方更新自动补丁编译 → Run workflow）可选参数：

- `version`：指定任意官方 tag 构建（含 beta 版本，如 `2026.9.1-beta`）
- `force`：强制重建——Release 已存在也重新编译并覆盖产物、更新说明

### 9.2 首次部署

```bash
cd cloudflared-fix
git init
git add .
git commit -m "init: cloudflared 安卓 DNS 修复补丁 + CI 自动构建"
git remote add origin git@github.com:<你的用户名>/cloudflared-fix.git
git branch -M main
git push -u origin main
```

推送后立即触发一次完整构建（push 自检），自动发布当前最新稳定版。
仓库需开启写权限：Settings → Actions → General → Workflow permissions →
**Read and write permissions**。

### 9.3 行为细节与注意事项

- **产物缺失策略**：`cloudflared-android-arm/arm64 32位` 与 `android-amd64` 因需 NDK
  外部链接，CI 未提供（脚本按预期跳过并告警）；Release 附带对应 linux 纯静态版替代。
- **官方源码重构**：主补丁失效 → 构建失败并邮件通知（按第 6 节人工适配）；第二补丁
  失效 → 仅告警跳过，Release 说明中标注"未应用"，主修复不受影响。
- **活跃保活**：GitHub 会在仓库 60 天无任何提交时自动停用定时任务（会发邮件提醒），
  流水线每次成功构建都会提交 `.github/last-built.txt` 以维持活跃；若上游长期无新版且
  任务被停用，到 Actions 页面重新启用即可。
- **重复触发**：同一时间只允许一个构建在跑（concurrency 串行排队，不取消）。
- **构建缓存**：Go 模块按官方 go.sum 缓存，重复构建更快；全量构建约 10~20 分钟。
