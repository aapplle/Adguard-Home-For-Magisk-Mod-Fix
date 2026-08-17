# minfix 修复更新日志（fork: aapplle/Adguard-Home-For-Magisk-Mod-Fix）

上游：[liuzq2002/Adguard-Home-For-Magisk-Mod](https://github.com/liuzq2002/Adguard-Home-For-Magisk-Mod)
本 fork 在上游基础上修复 KSU 软重启竞态，并由 GitHub Actions 自动跟随上游
（源码取上游 main，AdGuardHome 二进制取上游 release，自动合并打包发版）。

## minfix9（20260720-minfix9，2026-08-17）KSU late-load 跳过启动 + 看门狗补端口监听

- **重新归因“外部启动器双跑”**：KSU 官方源码显示 late-load 路径也会执行
  service 阶段，随后软重启的 `on_services()` 又执行一次，同一启动周期内
  `service.sh` 会被多次触发。这不是另一个 root 管理器，而是 KSU 自身的
  late-load + soft reboot 多阶段执行。
- **service.sh 新增 late-load 首次跳过**：`KSU_LATE_LOAD=1` 在整个 boot
  周期内都是常驻标志（内核 flag），不能只凭它判断“本次是 late-load 首次
  执行”。实现用 **boot_id marker**：同一 boot 内首次 late-load 执行跳过，
  之后（如 soft reboot 的 service 阶段）正常启动。当前使用场景（late-load
  后不软重启）不存在，因此不会牺牲功能，同时从根上消除 late-load 与
  soft reboot 两个 service.sh 世代重叠。
- **移除 fix8 双跑合并等待**：late-load 首次跳过已消除唯一已知的并发
  `service.sh` 重叠源，`otherservice()` / 20 秒等待 / 终局判定不再需要；
- **iptables.sh 看门狗循环加入 `port_listening "$redir_port"`**：AGH 进程
  存活但 DNS 端口未监听时，触发 `setup_rules()` 清空/重建规则，避免规则
  指向死端口持续断网。端口未恢复时按原设计清空 REDIRECT 让 DNS 直通。
- 验证：新增 phaseN（late-load 跳过 + 普通启动回归）、phaseM（端口死亡自动
  清规则直通）；phaseL 改为“无合并”单启动回归；phaseA（fb+sr×3）回归全过。

## minfix8（20260720-minfix8，2026-08-17）冷启动双跑合并：消除「清理,清理,成功,成功」形态

minfix7 实机日志（03:15 / 07:55 两轮冷启动）：健康跳过门已压制重触发（03:16、
03:18 两次「跳过重复启动」），但**冷启动窗口双跑依旧**——A 在等路由时 AGH 尚
未存在，B 的健康门必然不通过，照样全量清理/随机化/拉起一遍（日志双清理双成功，
即用户指出的连续形态）。

修复（无锁、无标记文件、无世代令牌——与被回滚的历史 minfix8 完全不同的机制）：

- service.sh 健康门之后新增**并发双跑合并等待**：检测另有 service.sh 实例存活
  （零 fork 内建 cmdline 扫描，按 pid `$$` 剔除自身，不依赖 pgrep 语义）→ 最多
  等 20 秒；期间或等待结束后（终局判定：另一实例退出后其拉起的 AGH+看门狗仍在
  服务）任一时刻判定健康即记「另一实例已完成启动，本实例跳过」退出。冷启动从
  此只出现一对「清理→成功」；
- 失败安全：等待以「另一实例存活」为前提，超时/实例消失且仍不健康则照常走
  原清理重建流程（行为与原先完全一致）；「看门狗已起→实例退出」的亚秒级健康
  窗口靠等待后的终局判定兜住（1 秒轮询可能错过窗口本身）。

验证：applier 幂等 + bash -n/mksh -n；**phaseL 专项**：双跑 1.2s 间隔（合并等
待路径）与 3s 间隔（健康门路径）均单清理单成功+跳过落日志、单实例、三向收敛、
DNS 正常；单实例冷启动无等待惩罚；健康重触发仍跳过；死亡世代正确全量重建。
全矩阵 phaseA~D / I / J / K / cpu 回归全过（本次同时修复了沙箱 harness 的
reset 漏杀看门狗 bug：kill_sim 的 pkill 模式未随沙箱改名重写，残留看门狗 5 秒
内重生 AGH 桩，曾令多轮测试在幻影世代上通过/失败——已改为 $HOME 前缀模式并
加 SIGKILL 兜底，全部矩阵在干净 harness 上复验）。

## minfix7（20260720-minfix7，2026-08-17）健康世代跳过 + 种子化端口：消除每次触发造成的 DNS 中断窗口

minfix6 实机日志（02:50~02:55）新发现：外部启动器每波触发（含 boot_completed
波次）都把**健康世代整体拆掉重建**——清理杀死在役 AGH 后需等路由 + 重启
（实测 13~17 秒），期间 DNS 完全中断（用户观察到的「短暂无网络后自恢复」即
此窗口）；且双跑实例各自 `$RANDOM` 随机化端口，交错时存在端口漂移隐患
（交替模式下 A 先绑旧值、B 覆盖写新值 → 规则指向死端口）。等路由使双实例
同步化后日志呈「清理,清理,成功,成功」连续形态（fix4/5 为交替形态），即双跑
仍在发生的直接证据。

修复（保持「确证健康才跳过、否则照常重建」的失败安全设计，无锁无令牌）：

- **service.sh 健康世代跳过门**：AGH 存活（cmdline 前缀，零 fork 内建扫描）+
  看门狗存活 + config 端口真实在听，三者齐备则记录
  `[minfix v20260720.7] 当前世代健康，跳过重复启动` 并退出——外部启动器的
  双跑第二实例、boot_completed 波次、软重启（旧世代健康存活时）都不再拆台
  重建，DNS 零中断；任一条件不成立即走原 minfix4 清理重建流程（宁重建勿漏判）。
- **端口随机化以 boot_id 为种子**（mksh 安全算术）：取 cksum 十进制的两个
  不重叠 5 位切片 + `10#` 强制十进制（数值 <10^5 远离 32 位边界；前导零字面量
  mksh/bash 解析不一致、整数位运算曾在设备 mksh 求值失败——两次前车之鉴均
  规避），实测 mksh/bash 逐位一致、跨次运行恒定；R1==R2 时 +13 错开防
  DNS-TCP 与 web 端口冲突。效果：双跑/重复触发写入相同端口值，任何交错下
  YAML = config.prop = 幸存实例监听端口；跨完整重启端口仍变化。

验证：applier 干净树应用 + 幂等 + bash -n / mksh -n；**phaseK 专项**：种子公式
mksh==bash 且跨次恒定、双跑冷启 → 单实例三向收敛、健康重触发 → 端口不变 +
「跳过重复启动」落日志 + 零拆台、AGH/看门狗死亡 → 正确全量重建；全矩阵
phaseA~D / I / J / cpu_sanity 回归全过。

## minfix6（20260720-minfix6，2026-08-17）飞行模式门控 + 等默认路由：修复「软重启 1 次断网、2 次恢复」

minfix5 实机日志（02:35~02:38）：每代 AGH 均正常启动、端口/规则正确，但正常
重启 + 1 次软重启后整机 DNS 解析异常无网络，第 2 次软重启即恢复——与已回滚的
历史 minfix6 所修症状完全一致（该修复未包含在 minfix4 回滚基线中）：

- 根因：上游 setup_rules 每次重建规则都开关一次飞行模式（刷新网络）。软重启时
  service.sh 先于 framework 就绪重跑，AIRPLANE_MODE 广播可能丢失/未被处理——
  飞行模式被"打开"后无人关闭 → 射频关闭、整机断网（端口/规则全部正常与现象
  吻合；第二次软重启时 toggle 完整执行把飞行模式关掉，故恢复）。

修复（自历史 minfix6 原样移植，当时已实机验证有效）：

- iptables.sh 飞行模式 toggle 加门：仅当 `sys.boot_completed=1`（framework
  完全就绪、广播可靠）才执行；REDIRECT 拦截 53 端口不依赖客户端刷新，跳过
  无副作用；
- service.sh 启动 AGH 前最多等 15 秒默认路由就绪（`ip route` 查 default），
  杜绝 AGH 在断网窗口启动导致上游 DoH 连接自出生即黑洞的并发动因。

验证：applier 干净树应用 + 幂等 + bash -n / mksh -n；沙箱 phaseA~D + phaseI +
cpu_sanity 回归全过；**新增 phaseJ**：boot_completed 未就绪窗口 0 次 toggle、
就绪后精确 on→off 各一次（2 puts + 2 broadcasts）、规则照常重建、DNS 探针正常、
路由等待代码在位。getprop 桩支持经状态文件控制 sys.boot_completed。

## minfix5（20260720-minfix5，2026-08-17）零 fork 化 cmdline 扫描：根治 tr 烧核，保留 minfix4 思路

minfix4 的 /proc/*/cmdline 扫描对每个进程 fork 一条 `tr '\0' '\n' | grep -qx`
管道：实机出现 toybox tr 对某个 /proc 文件死循环（单核持续占满、机身高温），
且数百进程 × 每 5 秒的 fork 洪水本身不可接受。

修复（保持 minfix4「按 cmdline 匹配、不信任进程名/pgrep 语义」思路不变）：

- 全部 4 处扫描（service.sh 清理主扫 + SIGKILL 兜底、iptables.sh 的
  agh_running、uninstall.sh 清杀）改为 **shell 内建 read+case 直读 cmdline**：
  read 剥离 NUL 后各参数无缝拼接（实测 mksh/bash 运行时语义一致），
  `case "$c" in "$BIN"*)` 前缀即锚定 argv[0]，与 minfix4 首参数匹配等价；
- **零 fork、零外部命令**：该路径不再执行任何外部二进制（tr/grep/cat 全部
  退出），tr 烧核从机制上不可能再发生；实测全 /proc 未命中扫描（~50 进程）
  耗时 <10ms，看门狗稳态 CPU ~0.1%；
- 防御细节：每轮 `c=` 先清空（读不到 cmdline 的进程不残留上一轮的值，杜绝
  误杀）；僵尸/内核线程的 cmdline 为空，天然不匹配。

验证：applier 干净树应用 + 幂等 + bash -n / mksh -n；沙箱矩阵 phaseA~D +
cpu_sanity 全过；**新增 phaseI：mksh（真机同款 shell）运行时实测**——NUL 剥离
语义 mksh==bash、活实例命中、无假阳性、全扫耗时、残值防护，全过。沙箱 AGH 桩
同步修正 argv[0] 保真度（shebang 桩 re-exec 双写路径，使 /proc cmdline 与真机
ELF 二进制一致；此前失真桩曾让匹配测试空转通过）。

## minfix4（20260720-minfix4，2026-08-16）✅ 实机验收通过

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
