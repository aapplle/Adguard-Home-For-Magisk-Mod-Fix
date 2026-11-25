# AdGuard Home For Android (Hardened Fix)

基于 [Adguard-Home-For-Magisk-Mod](https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod) 独立审计并重构加固的 Magisk / KernelSU / APatch 模块，配套魔改核心为 [AdguardHome-Mod-Fix](https://github.com/aapplle/AdguardHome-Mod-Fix)。

## 核心改进

- **健壮性**：
  - `AGH_SNI` 链启用 `connbytes`（仅检查每条 TLS 连接前 20 KiB），避免全量 HTTPS 数据进入用户态 NFQUEUE；内核不支持 `NFQUEUE`/`connbytes`/`ip6tables`/`nsenter -G` 时自动降级。
  - 移除默认无条件开关飞行模式与无限 `exec "$0"` 死循环，引入有界退避重试与规则熔断器。
  - 修复 `mksh` 下 `/proc/<pid>/cmdline` 遇 `\0` 截断导致防重入与进程查杀失效的问题；以原子锁管理单一守护进程。
  - 移除 `/data/system/ifw`、应用整个 `files/`、`Pictures` 与通用 `shared_prefs` 等高误伤加锁路径，卸载时自动恢复 `private_dns_mode` 与 `tcp_fastopen`。
  - 检测到其他 Hosts 模块时仅提示冲突，不再静默删除用户模块；不再对模块脚本打 `chattr +i`。
- **简洁性**：
  - 4 个独立 5 秒轮询守护合并为单一低功耗 `watchdog.sh`（默认 30 秒周期），`ModuleMOD.sh` 改为开机一次性更新。
  - 端口、`drop_quic`、`blocking_mode` 与 `sni_ports` 均以 `AdGuardHome.yaml` 为单一数据源。
  - 清洗预置白名单中约 80% 对 DNS/SNI 无效的浏览器元素隐藏/修饰符规则。
- **隐私与安全**：
  - 首次安装自动生成本机独立 16 位随机管理密码（写入 `0600` 权限的 `/data/adb/agh/initial_credentials.txt`），升级保留用户的 `AdGuardHome.yaml`。
  - 禁用 `config.prop` 的 `source` 执行，改为白名单键值解析防止 root 命令注入。
  - 默认关闭 `edns_client_subnet`、开启 `anonymize_client_ip` 与 `sni_filter.log_blocked_only`，移除第三方反代 `ghfast.top` 强依赖并缩短/规范更新策略（24h）。
  - 移除 `shuzilm.cn`、友盟、小米/滴滴/淘宝追踪域等商业遥测白名单。
- **可维护性**：
  - 将内置规则抽离为独立文件 `bin/data/userfilters/builtin_rules.txt`，`user_rules` 完全留给用户；修复全部拼写错、语法缺失、自相矛盾与无效 IP 规则。
  - 提供 `scripts/lint_rules.py` 与 GitHub Actions 自动化校验、SHA-256 拉取核心并打包发布流水线。

## 配置说明

配置文件位于 `/data/adb/agh/scripts/config.prop`（纯键值格式，修改后重启生效）：

| 配置项 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `watch_interval` | `30` | 统一守护巡检周期（秒，最低 10） |
| `enable_noads` | `true` | 是否锁定 `noads_paths.list` 中的广告/开屏缓存路径 |
| `enable_proxy_sync` | `true` | 是否自动同步 Surfing/Box/Mihomo/Clash DNS 指向本地 AGH |
| `disable_private_dns` | `true` | 运行时关闭系统私人 DNS（卸载时自动恢复） |
| `disable_tfo` | `true` | 运行时关闭 TCP Fast Open（卸载时自动恢复） |
| `allow_airplane_refresh` | `false` | 规则重建后是否开关飞行模式刷新网络（默认关闭） |
| `PROXY_URL` | `""` | 代理订阅链接（留空则不改写代理模块订阅地址） |

## 鸣谢

- [AdGuardHome](https://github.com/AdguardTeam/AdGuardHome)
- [Adguard-Home-For-Magisk-Mod](https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod)
- [AdguardHome-Mod](https://github.com/liuzq2002/AdguardHome-Mod)
- [GOODBYEADS](https://github.com/8680/GOODBYEADS)
