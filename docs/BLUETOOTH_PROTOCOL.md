# AgentRing 蓝牙副屏通讯协议规范 (Bluetooth Sync Protocol)

本文档详细说明 macOS 端 **AgentRing** 与 Android 副屏 **agentRing-Android** 之间的蓝牙配对、连接建立、数据帧定界以及 JSON 报文通讯协议。

---

## 1. 架构与角色定位

```
┌───────────────────────────────────────┐            蓝牙 RFCOMM (SPP)            ┌────────────────────────────────────────┐
│             macOS 客户端              │──────┬─────────────────────────────────>│            Android 副屏 #1             │
│          (AgentRing.app)              │      │  JSON Stream (每帧以 '\n' 结尾)   │         (agentRing-Android)            │
│                                       │      │                                  └────────────────────────────────────────┘
│ • 连接池管理所有已配对副屏 (1:N 拓扑) │      │
│ • 监听配置与用量变化                   │      │                                  ┌────────────────────────────────────────┐
│ • 周期性/事件触发广播最新用量数据      │      └─────────────────────────────────>│            Android 副屏 #2...           │
│ • 各副屏会话隔离，独立保活与重连       │         JSON Stream (每帧以 '\n' 结尾)   │         (agentRing-Android)            │
└───────────────────────────────────────┘                                         └────────────────────────────────────────┘
```

- **数据发送端（Master / Client）**：macOS `AgentRing.app`，负责抓取并计算各 AI 供应商（Codex、Cursor、Antigravity 等）的额度、重置时间和显示状态，建立并维护与多个已配对副屏的 RFCOMM 通道池，广播推送数据。
- **数据接收端（Slave / Server）**：Android 手机（例如 Nubia Z9 mini，Android 5.0+），程序启动后开启屏幕常亮并强制横屏，充当硬件级桌面信息副屏。支持多台设备独立运行、同时接收展示。

---

## 2. 蓝牙层连接规范

### 2.1 物理与协议配置
- **通讯模式**：经典蓝牙 SPP (Serial Port Profile) over RFCOMM。
- **服务名称 (Service Name)**：`AgentRingDisplay`
- **服务 UUID (Standard SPP UUID)**：`00001101-0000-1000-8000-00805F9B34FB`（16-bit: `0x1101`）
- **RFCOMM 通道**：动态由 SDP (Service Discovery Protocol) 协商分配；默认预备通道为 `Channel 5`。

### 2.2 设备广播与发现机制
1. **自动命名规则**：
   - Android 副屏启动时，自动将自身经典蓝牙名称更改为：
     `AgentRing-<DeviceModel>`（例如 `AgentRing-NX513J`）。
2. **可见性模式**：
   - Android 副屏通过反射调用 `BluetoothAdapter.setScanMode(23, 0)`，将蓝牙设为 `SCAN_MODE_CONNECTABLE_DISCOVERABLE` 且常驻可见。
3. **BLE 辅助广播 (Bluetooth Low Energy Advertising)**：
   - Android 端在 Lollipop (API 21+) 及以上启动低延迟、可连接的 BLE 广播（`AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY`），携带设备完整本地名称。此举使 Mac 系统的蓝牙搜索面板能在 1~2 秒内迅速发现该设备。
4. **macOS 端 1:N 多设备连接池与看门狗机制**：
   - macOS 端遍历系统已配对设备（`IOBluetoothDevice.pairedDevices()`），按名称前缀 `AgentRing` 或已知设备 MAC 地址（如 `D8:55:A3:41:24:86`）筛选所有匹配的副屏设备。
   - 内部为每台副屏维护独立的 `DisplaySession` 连接上下文，互不影响；
   - 设有 10 秒周期性重连定时器：遍历所有设备，对未连接的设备发起 SDP 查询与通道连接；
   - 每个会话配备独立的 8 秒连接看门狗；若单台设备离线或连接超时，仅释放该设备会话，不阻塞其他正常副屏的数据推送与保活；
   - 当用量数据发生变化或新设备上线时，向所有处于活跃连接状态的副屏通道并发广播最新的 JSON 数据报文。

---

## 3. 传输层帧定界与编码

- **传输流**：面向字节流的 RFCOMM 串口。
- **字符集**：`UTF-8`。
- **帧定界符**：换行符 `\n`（Line-delimited JSON 流）。
- **心跳与保活**：由于底层 RFCOMM 维护链路层 L2CAP 保活，应用层数据在每次定时刷新（或收到数据变更）时主动以单行 JSON 字符串附加 `\n` 写入通道。

---

## 4. 数据报文规范 (JSON Payload Schema)

每帧报文均为一个独立的 JSON 对象，序列化为单行文本发送。

### 4.1 根对象字段说明

| 字段名 | 类型 | 必选 | 说明 |
| :--- | :--- | :---: | :--- |
| `timestamp` | Integer | 是 | Unix 时间戳（秒），用于副屏校验数据新鲜度并显示更新时间。 |
| `providers` | Array | 是 | 当前处于激活状态并按用户设置排好序的供应商数据数组。 |

### 4.2 `providers` 元素字段说明

每个供应商代表副屏上的一个垂直展示列：

| 字段名 | 类型 | 必选 | 说明 |
| :--- | :--- | :---: | :--- |
| `id` | String | 是 | 供应商唯一标识符：`"codex"`, `"cursor"`, `"antigravity"`, `"antigravity_third"`。 |
| `name` | String | 是 | 列顶部标题：`"Codex"`, `"Cursor"`, `"Antigravity"`, `"Antigravity Third"`。 |
| `primary` | Object | 是 | **外圈主环**及主额度信息对象（参见 4.3 节）。 |
| `secondary` | Object | 否 | **内圈次环**及次额度信息对象。若供应商为单环（如仅有 7 天的 Codex），该字段为 `null` 或省略。 |
| `rows` | Array | 否 | **胶囊行列表**（参见 4.4 节），由服务端按用户激活项完全动态生成，驱动副屏严格按行渲染。 |

### 4.3 `primary` / `secondary` 环形对象字段

| 字段名 | 类型 | 必选 | 说明 |
| :--- | :--- | :---: | :--- |
| `label` | String | 是 | 额度名称（如 `"7天"`, `"Gemini 5小时"`, `"Claude/GPT 5小时"`, `"Included"`）。 |
| `remainingPercent` | Double | 是 | **剩余百分比**（0.0 ~ 100.0），用于驱动圆环绘制弧长及环中心大字显示。 |
| `resetsAt` | String | 否 | 格式化后的紧凑重置倒计时（如 `"3h 33m"`, `"4d 14h"`, `"6d 17h"`）。 |
| `remainingDetails` | String | 否 | 辅助明细文本（例如 Cursor 的 `"120 / 500"`）。 |

### 4.4 `rows` 胶囊列表对象字段

数组内的每个对象驱动副屏渲染一行胶囊药丸 `[ 标签 ]  [ 百分比 ]  [ 倒计时 ]`：

| 字段名 | 类型 | 必选 | 说明 |
| :--- | :--- | :---: | :--- |
| `label` | String | 是 | 左侧标签名称（如 `"7天"`, `"Gemini 5小时"`, `"Claude/GPT 7天"`）。 |
| `percent` | String | 是 | 中间加粗数值（如 `"16%"`, `"52%"`, `"100%"`，或余额 `"$25.00"`）。 |
| `reset` | String | 否 | 右侧重置倒计时文本（如 `"4d 14h"`，无则传空字符串 `""`）。 |

---

## 5. 报文示例 (Sample Payload)

以下为典型的生产环境报文（包含单个 7 天单环的 Codex、双环的 Antigravity Gemini 以及双环的 Antigravity Third）：

```json
{
  "timestamp": 1726487626,
  "providers": [
    {
      "id": "codex",
      "name": "Codex",
      "primary": {
        "label": "7天",
        "remainingPercent": 16.0,
        "resetsAt": "4d 14h"
      },
      "rows": [
        {
          "label": "7天",
          "percent": "16%",
          "reset": "4d 14h"
        }
      ]
    },
    {
      "id": "antigravity",
      "name": "Antigravity",
      "primary": {
        "label": "Gemini 5小时",
        "remainingPercent": 51.0,
        "resetsAt": "3h 33m"
      },
      "secondary": {
        "label": "Gemini 7天",
        "remainingPercent": 86.0,
        "resetsAt": "6d 17h"
      },
      "rows": [
        {
          "label": "Gemini 5小时",
          "percent": "51%",
          "reset": "3h 33m"
        },
        {
          "label": "Gemini 7天",
          "percent": "86%",
          "reset": "6d 17h"
        }
      ]
    },
    {
      "id": "antigravity_third",
      "name": "Antigravity Third",
      "primary": {
        "label": "Claude/GPT 5小时",
        "remainingPercent": 100.0,
        "resetsAt": "4h 59m"
      },
      "secondary": {
        "label": "Claude/GPT 7天",
        "remainingPercent": 33.0,
        "resetsAt": "5d 18h"
      },
      "rows": [
        {
          "label": "Claude/GPT 5小时",
          "percent": "100%",
          "reset": "4h 59m"
        },
        {
          "label": "Claude/GPT 7天",
          "percent": "33%",
          "reset": "5d 18h"
        }
      ]
    }
  ]
}
```

---

## 6. 业务与渲染规则对齐

为了保证副屏在视觉和逻辑上与 macOS 原生 Popover 100% 一致，遵循以下约束：

1. **有效额度与无效窗口过滤**：
   - 若供应商 API 返回的使用率为 0% 且没有重置信息（`used_percent == 0 && reset_at == nil && reset_after_seconds == nil`），判定为无效窗口（如未开通或无 5 小时限制），不构造入报文。
   - 未启用的 Credits 余额（`enabled == false`）不生成 `rows`。
2. **单环与双环映射**：
   - 当 `secondary` 为空时，副屏 `ActivityRingView` 仅渲染单个外环，不绘制内圈底轨；圆环中心数值严格显示 `primary.remainingPercent`。
   - 当 `secondary` 存在时，副屏绘制等宽双同心环，外环为 Primary、内环为 Secondary。
3. **界面纵向多层对齐（Top-Alignment）**：
   - 副屏所有供应商列容器顶部平齐。
   - 供应商标题行（`providerName`）水平基准线绝对对齐。
   - 圆环中心及底边缘水平基准线绝对对齐。
   - 胶囊信息行上对齐：Row 1 必须与相邻列的 Row 1 保持相同 Y 坐标；多出的 Row 2 仅在具备双额度的列下方显示，不影响整体单行对齐。
4. **配色体系对应表**：
   - **Codex (单环 7天)**：`#58744F` (暗青绿)
   - **Codex (双环 5小时 / 7天)**：`#718F66` (嫩绿) / `#58744F` (暗青绿)
   - **Antigravity Gemini (双环)**：`#617FA8` (科技蓝灰) / `#4E6B93` (深蓝灰)
   - **Antigravity Third (双环)**：`#A8785D` (暖陶红) / `#8C5F44` (暗陶褐)
   - **Cursor (双环)**：`#B76776` (玫瑰红) / `#96515E` (暗玫瑰)
   - **圆环底轨**：`#EDF0F5`
   - **胶囊背景**：`#ECEEF1`
