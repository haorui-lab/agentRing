# BLE 绑定验证记录（2026-10-23）

需求见 [BLE 副屏绑定方案](ble-binding-plan.md)。本次同时修改 Mac 与 `/Users/haorui/Code/github.com/agentRing-ESP-LCD`。本文记录提交前的本地构建与实机验证；本次未发布版本。

## 实机结果

- 设备为 ESP32-P4 v3.2，串口 `/dev/cu.usbmodem5CF71073231`，广播名 `AgentRing-LCD-C361`。
- 用户完成验证码配对并确认「配对成功，数据已同步」。固件日志确认显式 SMP、绑定主机认证成功、解析本机 4 个供应商的数据帧。Mac 设置的无障碍状态与截图确认「已绑定，正在同步本机数据」。
- 本机系统名称实际核对为 `M-IV`。Mac 通过加密握手发送名称，ESP32 在 NVS 保存；受保护的 NVS 备份确认该名称已持久化，固件重启日志确认恢复了 4 字节的名称。
- 已重新启动本机应用和 ESP32。随后再次收到 `BLE owner authenticated; data channel enabled` 与 4 个供应商的数据帧，期间没有重新开启物理配对窗口，无需再次输入验证码。
- 最终重启采集期间，绑定状态下拒绝了 12 次其他主机连接尝试。采集日志中未发现 panic、assert 或 Guru Meditation。这是现场连接拒绝证据，未把它表述为完整的双 Mac 对照实验。
- 名称展示已更新：连接管理突出显示「已连接：M-IV」；断开显示「已绑定：M-IV」与等待重连提示；顶部状态栏和底部数据来源同步展示。

## 构建与自动化检查

- Mac Debug 构建通过，运行产物通过 `codesign --verify --deep --strict`。本次最后的增量构建没有编译警告；较早完整构建仍有其他模块既有警告。
- Mac 检查通过：明确选择才连接、不同 UUID 不继承选择、配对失败停止重试、已选设备临时离线继续重连、LCD 不降级到旧协议、握手分阶段授权、认证等待错误分类、UTF-8 名称限制。
- ESP-IDF 构建通过并烧录，写入后的 hash 校验通过；未擦除 NVS。
- 固件策略检查遍历 800 种授权状态，只允许唯一绑定主机的已认证、已加密、128 位密钥会话写入。
- USB/BLE 独立组帧、旧会话残片清除、超长帧丢弃恢复检查通过。
- 名称展示检查通过：连接、绑定但断开、未绑定、空名称回退、UTF-8 名称。
- 负向编译检查确认错误 NimBLE 头文件顺序会失败；ELF 符号检查确认链接真实 `ble_sm_inject_io` 与 `ble_gap_security_initiate`。

## Android 设备行状态修正

- 原因：vivo Android 通过经典蓝牙 SPP 传输数据，BLE 仅用于广播发现；原设备行只读取 BLE 状态，因此经典连接成功后仍显示 BLE 配对按钮与旧的服务发现错误。
- 设置页现在优先读取实际经典连接，再读取 BLE 就绪/连接中状态。经典连接成功显示「已连接」「经典蓝牙 · SPP」，不再显示 BLE 配对操作和旧错误。停止广播的经典设备保留独立设备行；经典连接成功后阻止并取消同名的重复 BLE 会话。名称匹配仅用于展示和减少重复连接，不授权 BLE 数据。
- 首轮更新后，用户允许蓝牙访问，实机无障碍状态与截图均确认 vivo 的上述状态，LCD 同时显示「已通过 BLE 连接，正在同步本机数据」。日志确认 RFCOMM 通道 4 建立，经典通道写入 1158 字节。
- 检查「立即推流」时发现原入口通过 `NSApp.delegate` 转型取数据，实机点击未触发推送。已统一改用现有 `AppDelegate.shared`，同时修正首次连接取当前数据的入口；手动推流同时覆盖经典和 BLE。
- 最后修正版 Debug 构建、签名校验、策略回归与 `git diff --check` 通过。构建仍有既有 IOBluetooth SDP 可选值和 AppIntents 元数据提示。
- 用户允许系统蓝牙访问后，实机确认手动推流由「立即推流」变为「已推送」，日志确认经典通道写入成功。随后补充修正：已绑定 LCD 无需重新广播即可重连，设备列表必须补入真实就绪会话，避免底部已连接而设备行误显示「重连」。
- 最终运行进程为 35425。最新构建与签名校验通过；启动后的无障碍状态确认 LCD 与 vivo 均为禁用的「已连接」按钮，分别显示 BLE 与经典蓝牙 SPP。18:57:08 点击推流后显示「已推送」，日志记录手动向两路推流及经典通道写入 1158 字节。未单独拍摄 Android 接收端屏幕，不将 Mac 写入成功当作 Android 显示内容的独立验收。
- 已点击重新扫描，日志确认扫描开始/结束；随后用户切换了界面，界面采集服务又报错，未继续操作用户界面。重新扫描后的最终列表未另行截图核对。

本轮证据文件前缀为 `build/ble-binding-validation/evidence/android-state-`。

## 首次配对问题及修正

初版仅在 PASSKEY_ACTION 时生成验证码，用户点击屏幕后看不到码；NimBLE 头文件引入顺序又让 `ble_sm_inject_io` 被替换成返回 ENOTSUP 的宏占位实现。此前单纯构建成功和策略检查未覆盖这个问题。

现已改为物理开启 120 秒窗口后立即显示随机六位码，窗口内断开不换码；Mac 明确请求 SMP，等待系统配对完成，再读取身份并写入名称。安全请求 ACK 不能授权用量推送。最多五次失败的 SMP 会话后关闭窗口。增加编译保护与负向编译检查，避免再次链接占位接口。修正版首次配对已经通过上述实机验收。

## 验证边界

错误验证码/主动取消、手动确认换绑、Mac 整机休眠或重启、可控的双 Mac 对照实验尚未逐项执行。ESP32 名称显示逻辑和名称持久性已检查，物理屏幕的新排版尚未通过截图核对。Mac 设置页已实际查看。

当前运行的是 `build-temp/Build/Products/Debug/AgentRing.app`；`/Applications/AgentRing.app` 保留原安装版本。验证记录、构建/烧录日志、首次配对和重连日志、二进制校验值保存在 `build/ble-binding-validation/evidence/`。

## 重跑命令

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AgentRing.xcodeproj -scheme AgentRing -configuration Debug \
  -derivedDataPath build/ble-binding-validation build
bash Scripts/test-ble-binding.sh

cd /Users/haorui/Code/github.com/agentRing-ESP-LCD
bash scripts/test-ble-binding.sh
source /Users/haorui/esp/esp-idf-v5.5/export.sh
idf.py build
python scripts/test-ble-security-build.py
idf.py -p /dev/cu.usbmodem5CF71073231 -b 921600 flash
```

## 可恢复备份

ESP32 项目的 `build/ble-binding-backup-20261023/` 保存原设备分区头与完整 8 MiB factory 分区，也保存成功绑定后的 NVS。目录权限 700、备份权限 600，均在 Git 忽略目录内。NVS 含绑定密钥，不应公开分享。不要在成功配对后用旧 NVS 覆盖现有绑定。
