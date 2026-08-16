# minfix 修复更新日志（fork: aapplle/Adguard-Home-For-Magisk-Mod-Fix）

上游：[liuzq2002/Adguard-Home-For-Magisk-Mod](https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod)
本 fork 在上游基础上修复 KSU 软重启竞态，并由 GitHub Actions 自动跟随上游
（源码取上游 main，AdGuardHome 二进制取上游 release，自动合并打包发版）。

## minfix5（20260720-minfix5，2026-08-16）⚠️ 重要：修复 minfix4 引发的 CPU 占用

**minfix4 的 `agh_running()` 用 shell 循环逐个读 `/proc/*/cmdline`（tr+grep），
实机出现 toybox `tr` 对某个 /proc 文件死循环（单核 60%+ 持续占用、机身 105°C），
且该设计每 5 秒周期对全系统数百进程各 fork 两次，本身就不可接受。**

修复：三处 `/proc` 逐进程扫描（service.sh 清理块、iptables.sh 存活检查、
uninstall.sh 清杀）全部改为 `pgrep/pkill -f` 按二进制全路径的正则匹配
（`...bin/AdGuardHome( |$)`，结尾锚定防误伤 .yaml 等邻串）——C 实现、
单次 fork、无逐进程扫描。保留 v4 的「先杀守护 → 等 1 秒 → TERM → 等待 →
SIGKILL 兜底」时序，fork-exec 窗口漏网实例仍在下一轮检查/兜底中被捕获。

沙箱验证：全矩阵（fb+软重启×3 / 自愈 / flush / fail_flag×2 / 卸载 /
PATH 传播 / 漏网看门狗收敛 / 竞态注入）通过；**看门狗稳态 CPU 0.05%**
（20 秒窗口 1 个 tick）。

## minfix4（20260720-minfix4，2026-08-16）✅ 实机验收通过（其 /proc 扫描部分被 minfix5 取代）

修复 KSU 软重启「垂死看门狗 fork-exec 窗口竞态」：软重启瞬间旧看门狗拉起的
AGH 恰落在按名匹配的盲区里（fork 后 exec 前 comm 仍为 sh），漏网实例持有
sessions.db 单实例锁，导致此后每次按新配置启动的 AGH 全部死亡、端口永久漂移。

- AGH 匹配全面改为 `/proc/*/cmdline` 首参数精确匹配二进制全路径，
  不再依赖 pgrep/pkill 语义与进程名窗口；
- service.sh 清理改多轮扫描（先杀守护并等 1 秒让漏网 spawn 落地，≤5 轮
  清杀 + SIGKILL 兜底）；
- iptables.sh 看门狗存活检查改用同款 `agh_running()`；
- uninstall.sh 同样改为 cmdline 精确清杀；
- 清理日志附带诊断码（`清理后 pgrep -x rc=N`）。

实机验证：随机多轮「正常重启 + 软重启」，8/8 轮清理零残留、日志零异常行、
config=YAML=实际监听三向一致、单实例、DoH 过滤链路活跃；一次数秒 DNS 抖动
按设计直通降级并自动恢复。

## minfix3（20260720-minfix3）

依据实机验证脚本（test1/test2）撤销 minfix2 的两处错误推断：
`pgrep -x` 实机可命中（恢复 `-x` 写法）；mksh 命令替换无 fork 自计数
（去重守卫恢复上游 `-gt 1`）。新增 iptables.sh 顶部 PATH 自愈导出
（实机存在 PATH 残缺环境下被拉起的守护实例，导致无时间戳日志与误判重生）。

## minfix2（20260720-minfix2）

据当时日志推断调整匹配写法与守卫阈值（后被 minfix3 的实机测试证伪并撤销）。

## minfix1（20260720-minfix1）

首轮结构性修复（在 minfix4 中全部保留）：

- service.sh：软重启先清理上一世代（先杀守护再等 AGH 死透再启新，
  规避 sessions.db 锁）；启动失败清空重定向规则（DNS 直通）+ 5 秒退避重试；
  顶部补全 PATH；
- iptables.sh：新增端口真实监听检查（/proc/net/udp|tcp），未就绪清空重定向
  让 DNS 直通、下轮重试；config.prop 每轮循环 re-source（漏网旧守护也跟随
  当前端口收敛）；ip6 DROP 先查后加防重复累积；
- customize.sh：升级时按路径 `-f` 清杀旧守护（原按名 pkill 杀不中 sh 进程）；
- uninstall.sh：补全进程清理与 nat/ip6 规则清理（原卸载后规则指向死端口）。

## 上游原版问题清单（本 fork 修复的竞态）

KSU 软重启（只重启 framework、内核进程存活、重跑 service.sh）时：

1. service.sh 无条件再启 AGH → 多实例线性增长；
2. 每次运行随机化端口，但旧 iptables.sh 守护缓存旧端口 → 规则永不跟随
   （端口漂移）；
3. 新守护被去重守卫挡掉，只有旧世代存活；
4. 看门狗健康检查被任意存活实例蒙蔽 → 规则端口实例死亡时无自愈，
   DNS 永久断；
5. `pgrep` 任意实例即通过 → 新实例死亡仍记「启动成功」（误报）；
6. 启动失败 `exec "$0"` 无延时 → 约每秒一轮的紧循环重写配置；
7. 垂死看门狗 fork-exec 窗口漏网实例 → sessions.db 锁死后续所有实例
   （minfix4 修复）。
