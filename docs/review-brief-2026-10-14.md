# AgentRing · Antigravity 近期改动审阅简报（2026-10-14）

给其他 Coding Agent / 审阅者。只谈 **Antigravity（Gemini）凭证读取** 相关改动，不含 Cursor / X Subscription 用量展示。

本地分支：`fix/antigravity-keychain-no-prompt`（基于 main / v0.1.15）  
相关提交：`9eba3fa` + 本轮未提交优化（**先别 push**）

---

## 1. 用户看到的现象

macOS 反复弹出钥匙串授权对话框，大意是：

> **Agent Ring 想要访问你的钥匙串中的密钥 “gemini”。**

按钮一般是：**始终允许** / **不允许** / **允许**；有时还要输入「登录」钥匙串密码。

**什么时候弹：**

- 打开 Agent Ring 后不久；
- 应用在后台做用量 / 凭证刷新时（大约每隔 **2 分钟** 量级，和凭证缓存约 120 秒有关）；
- 点过「不允许」之后，过一会儿后台刷新又会再弹；
- App 更新或重启后仍可能继续弹；
- 尤其当 `~/.gemini/oauth_creds.json`（Gemini / Antigravity 本地登录文件）**缺失或过期** 时，几乎必现。

**骚扰点：** 不是偶发一次。后台一刷新就再跑同一条读钥匙串的命令，弹窗会反复出现。

---

## 2. 原因（大白话）

AgentRing 要显示 Antigravity / Gemini 用量，必须先拿到访问令牌。

读取顺序原来是：

1. **优先**读本机文件 `~/.gemini/oauth_creds.json` → 有效就不弹窗。
2. 文件没有或过期 → 用系统 API（`SecItem`）读钥匙串条目：service=`gemini`，account=`antigravity`。
3. 沙盒里这条经常**静默读不到**（不是用户拒绝，是权限/ACL 对不上）。
4. 读不到就回退跑命令行：  
   `/usr/bin/security find-generic-password -s gemini -a antigravity -w`  
   → **这条会弹出上面的系统对话框**。
5. 后台约每 2 分钟刷新一次凭证 / 用量 → 每次失败再跑 CLI → **不停弹**。

会走到这条路径的自动逻辑包括：后台刷新、启动预热缓存、拉用量、清缓存后再探测等。

### 和更早一次相关提交的关系

提交 `985b640`（*never read Antigravity keychain on SwiftUI main thread*）：

- **改了什么：** 发现在 SwiftUI 主线程布局时同步跑 `Process(/usr/bin/security)` 会崩（AttributeGraph / SIGABRT），于是改成「Published 缓存 + 后台刷新」，主线程不再直接跑钥匙串 / CLI。
- **没改什么：** 后台仍然会跑 `security` CLI，所以**弹窗骚扰还在**。只是从「主线程崩」变成了「后台反复弹窗」。

本分支是在那次之上，专门消弹窗。

---

## 3. 改了什么（逐条对照）

| 项目 | 改之前 | 改之后 |
|------|--------|--------|
| **后台刷新**（约每 2 分钟） | 文件失败 → SecItem → 再跑 `security` CLI → **弹窗** | 只走：oauth 文件 + **静默** SecItem；失败就当「没有凭证」，**绝不弹窗** |
| **SecItem 读钥匙串** | 可能弹出系统授权 UI | 加上 `kSecUseAuthenticationUIFail`：需要用户点授权时**直接失败、不弹任何 UI** |
| **`security` 命令行** | 自动路径失败就会跑（进设置、开关监控、后台刷新都可能触发） | **只有**用户在设置里点 **「重新检查」**，或跑诊断探测时，才允许可能弹窗的路径；进入设置页 / 拨开关 / 自动刷新 → **静默，不跑 CLI** |
| **用户点了「不允许」之后** | 过一会儿后台又弹 | 约 **60 秒** 冷却（仅挡显式「重新检查」/诊断的 CLI）；后台本来就不走 CLI。条目不存在（exit 44 = `-25300 & 0xFF`）**不**冷却 |
| **刻意没动** | — | **不** reset TCC、不跑 `tccutil`；**不删、不改** 用户钥匙串里的 `gemini` / `antigravity` 条目 |

行为不变的情况：oauth 文件有效，或 SecItem 已能静默读到 → 仍正常拿用量，不会多弹窗。

### 主要改动文件

- `AgentRing/Services/AntigravityAPIService.swift` — 静默 / 交互分流 + 60s 交互冷却
- `AgentRing/Views/Settings/Tabs/AuthSettingsView.swift` — 仅「重新检查」打开可弹窗路径
- `AgentRing/Helpers/AntigravityDiagnosticRunner.swift` — 诊断可 interactive

---

## 4. 怎么验证

1. 本分支本地编译运行 Agent Ring（**不要 push**）。
2. 打开 App，静置几分钟（超过原 ~120s 刷新周期）。  
   → **预期：后台不再自动弹 gemini 钥匙串对话框。**
3. 打开设置 → Antigravity：仅进入页面不应弹窗；点一次「重新检查」最多弹一次。
4. 若点「不允许」：后台仍不弹；约 60 秒内再点「重新检查」应跳过 CLI（不连弹）；冷却过后或重启 App 后可再试。
5. 若 `~/.gemini/oauth_creds.json` 有效：Antigravity 用量应仍正常。

---

## 5. 风险与后续

- 沙盒下 SecItem 本来就经常读不到 Gemini 写入的通用密码；禁用自动 CLI 后，**只有钥匙串、没有有效 oauth 文件** 的用户，后台会显示「无凭证」，需要打开 Antigravity/Gemini 刷新 oauth，或点「重新检查」并点允许。
- 冷却是进程内状态，重启 App 会清空；后台已不走 CLI，一般**不必**跨启动持久化。冷却期内 UI 无倒计时提示，故时长必须短（现 60s），避免用户误以为功能坏了。
- 「条目不存在」靠 `security` 退出码 **44**（`-25300 & 0xFF`）判定；`terminationStatus` 不会等于原始 `-25300`。若某版本「拒绝」也返回 44，可能少冷却一次（可再点一次，可接受）。
- 诊断面板同样尊重冷却：刚拒绝后立刻跑诊断会跳过 CLI；这也要求冷却不能太长。
- 未做自动化 UI 测试覆盖钥匙串弹窗（需要真机 Keychain ACL）。

### 相对 `9eba3fa` 的优化（含审查反馈）

1. CLI 结果三分：`token` / `notFound` / `deniedOrFailed`；**仅拒绝类失败**才冷却。
2. 冷却 24h → **60 秒**（只影响显式交互路径；无 UI 提示，不宜更长）。
3. CLI 读成功时清除冷却。
4. notFound 判定只比 exit 44，删掉永远命不中的 `errSecItemNotFound` 比较。

---

## 协作约定

- 仓库路径：`/Users/haorui/Code/github.com/agentRing`
- 分支：`fix/antigravity-keychain-no-prompt`
- **不要** `git push` / `gh pr create` / 强推，除非用户另行明确要求。
