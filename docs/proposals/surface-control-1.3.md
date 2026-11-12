# Surface control 1.3 提案：输入 CAS、可信写入者、分类额度

状态：M-A4，2026-11-12，供监督裁定；本文不改变合同 1.2、SDK、schema 或 fixture。
用户已选择身份方向：**宿主签发并绑定凭据**。具体字段与迁移仍待监督 Q 轮正式裁定。
依据：消费方 SC-R05（区分远程写入者）、SC-R08（反馈与输入争序号）、审查 R5-04/05。

推荐同时采用：独立 `input_sequence` CAS + 连续全局 journal；可信宿主签发的 opaque
principal；显式开启的分类写预算。它们分别解决冲突、归属、吞吐问题，不能互相替代。
继续保留 1.2 全局 CAS、单一事件顺序、模拟来源、身份/映射/epoch 栅栏及 fail-closed 租约。
没有实际 Pipe B3 反馈丢失率/重发率数据，不以假设数字宣称性能收益。

## 1. 输入比较交换与显示日志分离

### 动机和选项

1.2 反馈不带 CAS 可以写成功，但仍增加 journal 序号，让操作者输入得到 `stale_sequence`。
SDK 正确地拒绝自动重发；高频反馈下，操作者仍需反复 refresh 并重新判断意图。

| 方案 | 输入比较的值 | 日志/分页 | 代价与限制 |
| --- | --- | --- | --- |
| A，推荐 | 独立、连续的 `input_sequence` | 保留统一 `sequence`，反馈也写 journal | session 增一个 UInt64，所有输入路径同步更新，SDK分开保存CAS和事件游标 |
| B | 最后一个 input 事件的全局 sequence，初始0 | 同一 journal；输入highwater会跳过反馈编号 | 少一个递增计数器，但字段虽叫输入序号却不连续，SDK不能用+1校验；每次仍需同时返回全局序号 |
| C | 输入、反馈各自独立日志与游标 | 另加合并顺序或第三个全局序号 | 多日志保留/缺口/原子性更复杂；只读消费者更难重建先后，没有现实用例支撑 |
| 不做 | 仍比较全局sequence | 无迁移 | 1.2可用，冲突仍随反馈频率上升；继续低频反馈和显式refresh |

A只需要**全局journal计数器和输入计数器**，不增加反馈计数器。独立显示CAS没有消费需求；
显示仍按写入顺序最后一次有效值生效，需要严格显示CAS者仍可选择旧 `expected_sequence`。
B也能消除反馈冲突，但没有足够收益抵消输入序号跳号的心智和验证成本。

### 推荐线形和精确行为

候选能力 `input.independent_sequence`。本提案中的名称为待裁定名字；实现必须同时更新Swift类型、
严格parser、JSON Schema、SDK、typed examples和新fixture，不能只让实现接受某个新字段。

- discovery/snapshot/events页新增可选 `latest_input_sequence`（canonical UInt64十进制字符串）。
  宣告能力时必有；无能力时省略。events页的两个latest都是读时highwater，和 `holds` 一样。
- 有该能力时，每条事件带可选 `input_sequence`，表示该事件提交后的输入highwater；
  input事件加一，feedback事件保持原值。事件的 `sequence` 始终连续加一，保留1.2分页和缺口规则。
- `surface_control_input` 恰选一个字段：旧 `expected_sequence` 或新 `expected_input_sequence`。
  都缺失或同时存在返回 `invalid_argument`；无新能力却使用新字段也拒绝，不猜测降级。
  schema用互斥分支表达恰一字段，strict parser作同样检查。identity和pending-expiry校验顺序不变。
- 旧字段始终比较全局journal，包括反馈；成功仍要求响应全局sequence=旧值+1。
  新字段仅比较当前input highwater；成功input_sequence=旧值+1，全局sequence可能跳过已提交反馈。
  建议新比较失败用 `stale_input_sequence`，含义同旧错误：确定未执行；不含自动重发。
- 每个写入journal的input都增加输入计数，包括accepted、ignored/no_change、inactive_layer以及
  宿主生成的 `hold_expired`。这些都可能使旧意图陈旧，不能只数造成数值变化的输入。
  parse/permission/value/CAS等拒绝不写journal、不增加任一计数。
- feedback增加全局sequence，输入highwater不动；silent renew不增加任一计数、不写事件。
  租约到期必须先完成恢复rest的输入提交；旧input CAS随之失败，不能绕过到期栅栏复活运动。
- reset继续用旧全局 `expected_sequence`，原子换epoch并将两计数清零。
  任一需要增长的计数耗尽，先拒绝再执行宿主引擎；不得部分提交。映射换代也清空两计数。

例如初始(global,input)=(0,0)，feedback→(1,0)，input→(2,1)，feedback→(3,1)。
持有input CAS1的下一输入可成功成为(4,2)；持有旧global CAS2的请求仍必须stale。

### 兼容和SDK迁移

`contract_version: 1.3`、schema_version仍1；字段为可选加法，旧1.2请求的全局CAS含义完整保留。
不把旧 `expected_sequence` 偷换成输入计数。旧SDK因版本allowlist拒绝1.3，需要显式升级；
这比在不了解新能力时默默发送输入安全。新SDK接受1.0–1.3，按已校验能力自动选新input CAS，
同时提供 `sequenced`/模式选项让消费者保留全局CAS；针对旧host只发旧字段。

SDK分存 `latest_sequence` 和 `latest_input_sequence`，输入响应/refresh同时更新两者，
`refresh_sequence()`仍返回旧全局highwater，另加 `refresh_input_sequence()`供新调用方明确使用。
EventCursor始终只按统一 `sequence` 连续读取；任何mutation/refresh都不能替它跳游标。
分页时每事件的input_sequence只描述该历史提交，不能用它回退当前CAS highwater。
`stale_input_sequence`后由调用方显式refresh并重新判断，transport_unknown仍不重试。

两宿主改动量：共享session负责计数/比较，宿主adapter只传真实accepted/ignored结果和到期输入；
现有copy-validate-commit原子边界保留。Pipe升级版本/SDK/能力allowlist和schema pin，
桥只处理连续input事件，显示反馈不再无谓冲掉输入CAS；不改业务角色映射和deadman。

## 2. 稳定、可信的写入者标识（SC-R05）

### 比较和选择

| 方案 | 真实性/稳定性 | 隐私与运维 | 建议 |
| --- | --- | --- | --- |
| 宿主管理principal并绑定凭据 | host鉴权后确定，远程请求不能伪造；跨连接稳定 | 需要受保护principal记录；持久化可跨重启稳定 | 用户已选择，推荐 |
| 宿主按裸凭据哈希派生短ID | 同凭据一致 | 公开凭据指纹，可离线比对弱token；截短有碰撞 | 不采用 |
| HMAC(secret,credential) | 不直接暴露裸hash；secret轮换会换ID | 需管理secret、域隔离、碰撞与迁移；无必要在合同规定密码算法 | 可作为host内部实现，不是首选公共约定 |
| 调用方自报ID、host校验绑定 | 若host有凭据→ID表，安全性取决于同一张表 | 增加可被误认为身份的请求字段；host最终仍是签发者 | 不采用 |
| 不做 | 继续origin=remote和单写入者建议 | 读者不能区分模拟操作者与其他代理 | SC-R05仍未解决 |

### 推荐最小合同

候选能力 `events.writer_id`，事件新增可选 `writer_id`（有限长度opaque字符串）。开启能力时
host必须为所有事件提供可信ID，包括interface和host expiry；不开启则保持旧事件shape。
`origin`和`reason`保持旧枚举及语义，writer_id只增加归属，不替代source、权限、freshness和epoch。

writer ID由宿主拥有的principal记录签发，绑定已认证凭据；建议随机128位或更多熵的opaque ID。
**不公开raw credential、SHA(token)或其短串，不在合同核心处理凭据、密码算法、存储或时钟。**
宿主auth层把已脱敏ID通过可信API参数注入session，远程request不增加writer_id，
strict parser继续拒绝调用方的writer字段。核心验证ID格式/长度，不自行认证或签发。

生命周期与边界：

- 同一principal使用同一凭据的多个客户端得到同一ID；这是principal归属，**不是逐客户端识别**。
  当前宿主若只有一条bearer credential，就只能表示一个remote principal；要区分操作者与桥，
  host需要分别配发/绑定凭据。不能从MCP session、User-Agent或调用者自报名字伪造区别。
- principal ID在同一宿主的credential记录有效期内稳定，跨连接不变；持久化记录则跨进程稳定。
  不持久化的独立模拟器至少保证当前instance内稳定，重启已更换instance身份，不能宣称全局身份。
  凭据轮换可由host显式保留同principal；撤销后不重新分配旧ID给另一个主体。
- 不同宿主的相同ID无全局同一人保证；观察者必须按host/instance上下文解释。
  未选择公开身份注册表、显示名、用户PII或授权管理API。
- interface事件用host-owned界面principal；hold expiry用host-owned系统principal，保留
  origin=remote/reason=hold_expired。不可把到期事件归给“最后一个网络调用者”。
  首版不增加 `on_behalf_of` 或租约owner归属字段，也不把writer ID当作可控制他人租约的权限。
- ID缺失/错误由host在开启能力前修正，不能用空值表示“认证失败但仍写成功”。启用配置需要换epoch，
  使旧消费者重新prepare；principal不进入mapping hash，它不改变控件含义。

只读方可以审计、按预期principal筛选新input；筛选时仍要推进完整journal游标。
writer_id不是防重放token，也不保证只有某principal写入；授权仍由host决定。
旧1.2事件不带身份，消费者需要识别时必须要求新能力，不能猜测missing=操作者。
两宿主要把鉴权结果传到adapter和interface/expiry路径，新增配置principal表/注册流程；
无需把凭据放进共享包。Pipe在配置中pin允许的principal（或明确单principal策略），
独立允许系统expiry事件用于停稳，不能只按origin=remote接受任意远程输入。

## 3. 按类别独立的写入额度

### 动机、选项和推荐

目前所有mutation共用60次/s。即使独立input CAS消除重发，feedback仍可能消耗全部写预算，
而silent renew一旦被饿死会触发租约到期。因此这项是host准入策略，不能靠journal分离解决。

| 方案 | 优点 | 代价/不做的后果 |
| --- | --- | --- |
| 独立input/feedback/renew/admin预算，推荐 | 反馈占满自己的桶不会耗尽input或续期桶 | 两host各需分类计账和边界测试 |
| 一个全局桶，预留输入/续期份额 | 可控总量 | 优先队列/借额更复杂；仍需明确保留份额和公平性 |
| 按writer分桶 | 可隔离principal | 多凭据可放大实例吞吐，单principal多个client仍共享；身份不是本轮公平调度方案 |
| 不做 | 参数/CLI不变 | 增大--write-limit只能缓解，不能保证反馈不会挤占操作/续期 |

推荐按**instance+类别**共享预算，所有已认证principal与旧新请求都归入相应类别，不能靠多建
连接/换凭据放大额度。input、feedback、renew、admin(reset)四类互不借额。宿主自动hold expiry
不属于外部写请求，绝不能因额度耗尽而阻塞。解析前transport资源/读限流继续由宿主防护；
本提案不承诺用业务分类预算解决CPU或连接资源耗尽。

为避免同一flag突然换义，建议1.3新增显式独立预算模式（例如 `--write-limits`），保留
`--write-limit N` 旧聚合语义；同时传入两者启动报错。未启用新模式继续旧行为，文档如实标明。
候选能力 `writes.independent_limits` 只在独立模式宣告；启用后旧1.2字段形状也按分类计账，
这是显式选择的新host准入策略，不改变旧CAS。建议初值input60/s、feedback20/s、renew60/s、
admin5/s，可调；先以确定性1s窗口实现并文档化，不宣称token-bucket平滑或瞬时无突发。
公开可选discovery字段 `write_limits`，含 `window_s: 1`、四类整型 `*_per_window`，
只列配置上限，不公开实时余额或principal凭据。schema/parser/SDK随能力一致支持。

超限沿用host的rate-limit错误和确定未执行语义；不写journal，不消耗input序号，
不能用“稍后重试”自动补放旧意图。renew超限时consumer仍遵守原deadline，不能本地延长。
必须钉住：反馈满额后input和renew仍可成功；renew满额不阻止rest/stop输入；
admin满额不阻止系统expiry；窗口边界、非法参数和host clock回退都不制造免费额度。

对两host：限流在现有remote调度层实现，核心session不引入timer/异步/host名；配置与discovery
提供同义字段和CLI，legacy默认值/选项语义保持。Pipe选择启用独立模式，反馈仍推荐变化时
2–5Hz/值、约租约1/3续期；不能因为新预算更大就提高没有消费价值的显示频率。

## 4. Q轮实现和验收顺序

1. 监督书面裁定字段/能力/错误码及预算模式，明确principal稳定范围和host credential配置方式。
2. A实现共享可选合同、Swift单测、schema/typed examples、SDK和v1.3 fixture；v1/1.1/1.2保持逐字。
3. 两host锁同共享SHA，接入input CAS/writer/分类额度，真实进程验证legacy请求与新请求并存。
4. SDK对旧host用旧CAS，对新host显式用新CAS；旧expected_sequence仍受反馈影响，回归不可删除。
   验证global/input耗尽、ignored、expiry、reset、分页、刷新不跳cursor、身份缺失/伪造拒绝。
5. 固定两host同fixture逐步语义、clean HEAD交付、SDK/source哈希、源树外验证及远端双平台CI。
   Pipe升级和业务Worker整链证据由消费窗口独立提供，本工作区不替它宣称通过。

M阶段只提交本文，Q未经裁定不实现。最小交付可以先做input CAS和writer，独立预算是host能力，
但不应以“input冲突消失”作为已解决额度饥饿的结论。

## 5. 留待真实需求的议题

- 多写入者的租约所有权/抢占策略。当前renew不识别owner；writer ID审计并不自动改变这条权限。
- 多显示值一次原子batch、反馈CAS细分。当前每值一次请求，不先加没有消费需求的事务模型。
- feedback事件是否影响BinaryRoleCursor.verify的“最后事件必须仍是本意图”检查。
  独立input CAS只解决写入冲突；现有消费游标的保守全局superseded语义不能悄悄放宽。
  若实际场景需要按input highwater验证，应另行明确“后续feedback不撤销输入意图”的安全条件和测试。
- writer显示名称、组织身份、跨host联合身份、细粒度credential管理接口。公共合同只需要opaque归属。
- host独立限流是否需要token bucket/延迟队列。缺少实际吞吐数据时先用固定窗口，绝不排队补放输入。
