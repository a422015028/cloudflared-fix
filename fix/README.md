# fix/ —— cloudflared 安卓 DNS 修复套件（双补丁）

配合上级目录《安卓cloudflared-DNS修复与编译指南.md》使用。

| 文件 | 说明 |
|---|---|
| `android_dns.go` | 主补丁：复制到官方源码 `cmd/cloudflared/`，启动时替换全局解析器（环境变量 > getprop 系统 DNS > 公共 DNS 并发探测取最快，轮询自愈） |
| `ingress-origins-dns.android-fix.patch` | 第二补丁 v2 参考 diff：修 `ingress/origins/dns.go` 的 `Failed to initialize DNS local resolver` 报错（域名型源站解析；回环:53 检测 + 真实 UDP 可达性探测 + 公共 DNS 回退。注：v1 只看 dial 成败，因 UDP dial 恒成功而失效，勿回退到 v1 思路） |
| `android_dns_test.go` | 主补丁自测用例 → 复制到 `cmd/cloudflared/` |
| `dns_androidfix_test.go` | 第二补丁自测用例 → 复制到 `ingress/origins/` |
| `build-android.sh` | 一键编译：`bash build-android.sh <官方源码目录> <输出目录>`（自动装 Go、注入双补丁、复制测试、编译 6 目标、打包；第二补丁匹配失败会跳过并告警，不影响主修复） |

官方出新版后，把新版源码 + 本目录交给 AI，按指南第 3 节执行即可。

## CI 自动化

推送到 GitHub 后，`.github/workflows/auto-build.yml` 每天两次检测
cloudflare/cloudflared 官方 Release，发现新版本自动：下载源码 → 注入本目录双补丁
→ 编译 → 单元/冒烟测试 → 发布 `<版本>-dnsfix` Release（全部二进制 + zip +
SHA256SUMS + 中文说明）。也可在 Actions 页手动指定版本构建或勾选 force 强制重建。
详见上级指南第 9 节。
