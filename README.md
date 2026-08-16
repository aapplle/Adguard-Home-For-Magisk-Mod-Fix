# AdGuard Home For Android — 软重启竞态修复版（minfix）

[liuzq2002/Adguard-Home-For-Magisk-Mod](https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod)
的最小 diff 修复 fork：解决 KernelSU/Magisk **软重启**（只重启 Android
framework、内核进程存活、service.sh 重新执行）时的 DNS 去广告模块竞态问题。

- 修复内容与实机验证记录：[changelog-fix.md](changelog-fix.md)
- 下载安装：[Releases](https://github.com/aapplle/Adguard-Home-For-Magisk-Mod-Fix/releases)
  （模块内 updateJson 已指向本仓库，管理器内可直接收到更新提示）

## 修复摘要（相对上游最小 diff，5 个脚本）

| 问题（上游） | 修复 |
|---|---|
| 软重启多实例 + sessions.db 锁死新实例 | service.sh 启动前多轮清理上一世代（cmdline 精确匹配，先杀守护再杀 AGH 并等死透） |
| 规则端口永不跟随新配置（漂移） | iptables.sh 每轮循环 re-source 配置 + 按「端口真实监听」作健康真相 |
| 看门狗失明 → DNS 永久断 | AGH 起不来时清空重定向让 DNS 直通，恢复后自动重建规则 |
| 启动失败误报 + 每秒紧循环 | 失败清规则直通 + 5 秒退避重试 |
| 升级/卸载残留守护与死端口规则 | customize.sh / uninstall.sh 按路径清杀进程并清理 nat/ip6 规则 |
| 守护环境 PATH 残缺（无时间戳日志/误判） | service.sh 与 iptables.sh 顶部 PATH 自愈导出 |

上游更新时只需重跑 `fixes/apply-fixes.sh`（幂等、锚点式），由 GitHub Actions
自动完成——见下。

## 自动构建（GitHub Actions）

`.github/workflows/build.yml`：

- **每 6 小时**检查上游 main 是否有新提交，有则自动同步；
- **手动触发**（Actions → Sync upstream & build → Run workflow）可强制重建
  或递增修复修订号（bump fixrev）；
- 流水线：拉上游 main 源码 → `fixes/apply-fixes.sh` 套用修复 → 语法与标记
  校验 → 从**上游 release** 下载 AdGuardHome 二进制（上游仓库树内没有该
  文件）→ 合并打包 zip → 提交同步结果并创建 Release + 更新 Update.json。

本地构建：

```bash
git clone https://github.com/aapplle/Adguard-Home-For-Magisk-Mod-Fix
cd Adguard-Home-For-Magisk-Mod-Fix
bash fixes/apply-fixes.sh Adguardhome        # 幂等，可重复执行
# 从上游 release zip 解出 bin/AdGuardHome 放入 Adguardhome/bin/ 后：
(cd Adguardhome && zip -r9 ../module.zip .)
```

## 致谢

- 上游模块作者：[liuzq2002](https://github.com/liuzq2002)
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)
