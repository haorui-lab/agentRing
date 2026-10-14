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
| **后台刷新**（约每 2 分钟） | 文件失败 → SecItem → 再跑 `security` CLI → **弹窗** | **只读 oauth 文件**；失败即「无凭证」。**绝不**碰钥匙串（SecItem / CLI 都不走） |
| **SecItem 读钥匙串** | 可能弹出系统授权 UI | v0.1.16 曾以为 `kSecUseAuthenticationUIFail` 够静默；对 go-keyring 的 **login 文件钥匙串** ACL **仍会弹「输入登录密码」**。现仅显式「重新检查」/诊断才调用，并辅以 `SecKeychainSetUserInteractionAllowed(false)` |
| **`security` 命令行** | 自动路径失败就会跑（进设置、开关监控、后台刷新都可能触发） | **只有**用户点 **「重新检查」** 或跑诊断才允许；进入设置页 / 拨开关 / 自动刷新 → **不跑 CLI、不跑 SecItem** |
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

### 回归：v0.1.16 仍弹窗 → 补丁（未发版；对照近史）

**现象**：正式包 0.1.16 仍频繁弹出「登录钥匙串密码 / gemini」。

**不要和这些提交搞混（它们管的是 AgentRing 自己的 Codex/Cursor 凭据，不碰 gemini）：**
- `c72584d` Data Protection 钥匙串
- `f883903` DP 写入降级
- `17c175d` AES-GCM 文件存储替代自家钥匙串

**真正相邻根因：`985b640`（never read Antigravity keychain on SwiftUI main thread）**
| 应保留 | 误引入 / 放大 |
|--------|----------------|
| Published 缓存，主线程不跑 `Process` | **新增** `SecItemCopyMatching`（此前只有 CLI） |
| AuthSettings 后台 forceRefresh | `warmCredentialsCache` + 120s 过期 → **后台周期性**打钥匙串 |

`9eba3fa`/`f79289e` 只把 CLI 收到显式操作，**自动路径仍 SecItem** → 密码框继续弹。

**修复（贴历史，不盲目加料）：**
- 自动路径：只读 oauth 文件；**access 过期时用同文件 `refresh_token` 调 Google token 端点续期并写回**（不碰钥匙串）
- 显式「重新检查」/诊断：只走 `security` CLI（回到 985b640 **之前**的钥匙串读法）
- **删除**对 gemini 的 SecItem 路径（含 Fail 旗标 / `SecKeychainSetUserInteractionAllowed` 兜底）
- 保留 985b640 的主线程安全架构

**实测反馈（人类）：** 去掉 SecItem 后「不弹了」，但用量空白——因 `~/.gemini/oauth_creds.json` 的 access_token 已过期，有效令牌只在钥匙串。补上 refresh 后续期后，自动路径应能重新展示用量。

**沙盒补丁（审查指出 + 实测纠正）：**
1. 禁止再用 `expandingTildeInPath`：沙盒下 `~` = 容器。
2. 实测：`NSHomeDirectoryForUser` 在本 App 沙盒里**同样**返回容器路径，不够。改用 POSIX `getpwuid(getuid())->pw_dir` 取真实 login home。
3. `Config/AgentRing.entitlements` 增加 `home-relative-path.read-write` → `/.gemini/`。这也解释了为何旧代码「优先 oauth 文件」在沙盒里几乎总是落空、只能去弹钥匙串。

**账号错位（审查指出 + 本机核实）：**
- oauth 文件账号 `zgsdharry.ai@gmail.com` → Quota **403**
- 钥匙串 `gemini/antigravity` 账号 `zgsdharry@gmail.com` → Quota **200**
- 修复：显式「重新检查」**优先**走 CLI；成功后把钥匙串 token/refresh/id_token/expiry 同步写回 oauth 文件；之后自动路径 refresh 才续到正确账号。

**人类反馈「仍无法显示 / 会话已过期」跟进：**
1. 「重新检查」曾立刻 `post(accountChanged)`，与交互式 CLI **竞态**：静默 `fetchUsage` 先用错账号 → 403 → 会话过期 UI；且 oauth 从未被同步（面包屑无 `keychain_cli_ok`）。
2. 修复：等交互式探测成功后再 `accountChanged`。
3. Quota 401/403 后 **隔离** oauth 文件，自动路径不再读它，直到钥匙串同步成功。

**第五层：OAuth Client ID 错配（审查面包屑 + 本机实测）：**
- 面包屑循环：`access_expired` → `refresh_response_invalid`
- 文件 `id_token` 的 azp/aud、agy 二进制内嵌均为 `1071006060591-…apps.googleusercontent.com`
- 代码曾硬编码 Gemini CLI 的 `681255809395-…` → Google refresh 返回 **401 unauthorized_client**
- 改用 Antigravity 客户端后 refresh **HTTP 200**；已替换 `geminiOAuthClientID` / `Secret`

---

## 协作约定

- 仓库路径：`/Users/haorui/Code/github.com/agentRing`
- 分支：`fix/antigravity-keychain-no-prompt`
- **不要** `git push` / `gh pr create` / 强推，除非用户另行明确要求。
