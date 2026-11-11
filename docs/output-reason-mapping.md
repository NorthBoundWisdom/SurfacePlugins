# Output reason keys

| Key | Legacy text |
| --- | --- |
| `output.reason.001` | 限位、单周期变化量和速度必须是有效的有限数值 |
| `output.reason.002` | 安全门需要非空、唯一的限位与不超过 450 ms 的心跳期限 |
| `output.reason.003` | 实际状态含非有限数值 |
| `output.reason.004` | 时钟倒退，需重新连接安全门 |
| `output.reason.005` | 适配器未连接，禁止输出 |
| `output.reason.006` | 心跳时间异常，禁止输出 |
| `output.reason.007` | 心跳超时，已停止输出 |
| `output.reason.008` | 未收到对端心跳，已停止输出 |
| `output.reason.009` | 等待对端心跳 |
| `output.reason.010` | 使能关闭，禁止运动输出 |
| `output.reason.011` | 等待新鲜实际状态：\(limit.id) |
| `output.reason.012` | 实际状态超出软限位：\(limit.id) |
| `output.reason.013` | 目标缺失或不是有限数值：\(limit.id) |
| `output.reason.014` | 请先关闭再开启使能，禁止自动恢复运动 |
| `output.reason.015` | 限位 / 限速中 |
| `output.reason.016` | 输出已就绪 |
| `output.reason.017` | OSC bundle 嵌套过深 |
| `output.reason.018` | OSC 地址必须以 / 开始 |
| `output.reason.019` | OSC 不接受非有限浮点数 |
| `output.reason.020` | OSC bundle 元素过大 |
| `output.reason.021` | OSC UDP 数据包过大 |
| `output.reason.022` | 本适配器只接受立即执行的 OSC bundle |
| `output.reason.023` | 实际状态 OSC 地址无效 |
| `output.reason.024` | OSC 数据包长度或嵌套无效 |
| `output.reason.025` | OSC bundle 长度无效 |
| `output.reason.026` | OSC 地址无效 |
| `output.reason.027` | OSC 缺少类型标签 |
| `output.reason.028` | OSC 实际值不是有限数值 |
| `output.reason.029` | 不支持 OSC 类型标签 |
| `output.reason.030` | OSC 消息有多余字节 |
| `output.reason.031` | OSC 字符串必须是非空字符编码的 ASCII |
| `output.reason.032` | OSC 数值不完整 |
| `output.reason.033` | OSC 字符串缺少结束符 |
| `output.reason.034` | OSC 字符串不是 ASCII |
| `output.reason.035` | OSC 字符串填充无效 |
| `output.reason.036` | 尚未确认对端标识 |
| `output.reason.037` | 禁止在停止帧中发送运动值 |
| `output.reason.038` | 参数值必须是有限数值 |
| `output.reason.039` | 实际回传包含未知参数或非法数值 |
