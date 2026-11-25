## 2026.11.25 (Hardened Fix 重构版)

### 健壮性修复
- **NFQUEUE `connbytes` 限流与能力探测**：在 `AGH_SNI` 链启用 `-m connbytes --connbytes 0:20480`，避免全量 HTTPS 上传/代理流进入用户态队列；启动时自动探测内核 `NFQUEUE`/`connbytes`/`ip6tables`/`nsenter -G` 能力并平滑降级。
- **消除无限飞行模式与 `exec "$0"` 死循环**：移除默认无条件开关飞行模式行为（改为 `allow_airplane_refresh=false` 可选）；为 `service.sh` 与 `watchdog.sh` 引入有界重试退避与规则熔断器。
- **修复 Android `mksh` `/proc/cmdline` NUL 截断**：统一用 `tr '\0' ' '` 读取进程命令行，并引入原子目录锁替代脆弱防重入逻辑。
- **对称放行自身流量**：新增 IPv4 `ADGUARD_OUT` 专链，对 AGH 自身（`gid 9000`）放行 853 与 UDP/443，与 IPv6 `ADGUARD6` 行为一致，且与 `AdGuardHome.yaml` 中的 `drop_quic` 保持单一数据源同步。
- **清理破坏性路径与相对路径 Bug**：修复 `data/system/cube` 缺前导 `/` 导致卸载残留问题；移除 `/data/system/ifw`、`com.galaxy.stock/files`、通用 `shared_prefs`、`Pictures` 与通用图片缓存目录锁定；卸载时完整解锁隐藏文件并恢复 `private_dns_mode` 与 `tcp_fastopen`。

### 隐私与安全加固
- **消除硬编码弱口令**：首次安装时使用 `/dev/urandom` + 核心 `--hash-password` 为每台设备生成独立 16 位随机密码（保存在 `0600` 权限的 `/data/adb/agh/initial_credentials.txt`）；升级时**保留用户现有 `AdGuardHome.yaml`**，不再覆写密码/上游/自建规则。
- **去除强制第三方反代**：`Update.json` 与默认规则源直连 GitHub / 官方源，取消 `ghfast.top` 中转依赖，过滤列表更新周期改为 24 小时。
- **收紧默认隐私设置**：默认关闭 `edns_client_subnet`、开启 `anonymize_client_ip` 与 `sni_filter.log_blocked_only`，并移除 `shuzilm.cn`、`umeng`、`tracking.miui.com` 等商业遥测白名单。
- **消除 `config.prop` root 命令注入**：以白名单键值解析器替代 `. "$CONFIG_FILE"`。

### 简洁性与可维护性
- **四合一低功耗守护**：合并 `iptables.sh`/`ModuleMOD.sh`/`NoAdsService.sh`/`ProxyConfig.sh` 为单一 30 秒周期 `watchdog.sh`，大幅降低 CPU 唤醒频率。
- **规则解耦与自动质检**：将内置规则从 `user_rules` 抽离为 `bin/data/userfilters/builtin_rules.txt`，修复全部 6 处 `$important` 拼写错、3 处语法缺失、2 组直接冲突与 12 条无效 IP 规则，并清洗预置白名单中约 1.19 万条无效浏览器规则。
- **新增 CI 自动化校验与发版流水线**：集成 `shellcheck`、规则质检脚本 `scripts/lint_rules.py`、核心 SHA-256 校验与自动打包发布。
