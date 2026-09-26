# Coding Plan Bar

原生 macOS 菜单栏应用（Swift + AppKit + SwiftUI），多 Provider 可配置，实时展示 Coding Plan 剩余额度和 API 账户余额。内置支持 **Kimi**、**GLM（智谱 / Z.ai）** 和 **DeepSeek API 余额**，也可通过 JSON 路径解析接入其他只读用量接口。

## 系统要求

- macOS 13.0 或更高版本
- Xcode Command Line Tools

检查工具链：

```bash
xcode-select -p
swift --version
```

## 界面

- **菜单栏**：每个 Provider 一个双圆环进度指示器 + 剩余百分比
  - 外圈为周额度剩余（描边圆环），内圈为 5h 窗口剩余（实心扇形），两者分别按绿/黄/红阈值着色
  - 支持三种密度：圆环+百分比 / 仅圆环 / 仅百分比
- **点击图标**：弹出 CCSwitch 风格的面板（Popover）
  - Provider 卡片：圆环 + 大号剩余百分比 + 徽章（套餐等级）
  - DeepSeek 等 API 余额渠道不显示百分比圆环，直接以金额展示账户余额，并列出充值与赠送余额
  - 指标进度条：周额度 / 5h 窗口 / Kimi 加油包 / MCP 月度
  - GLM 官方 24 小时 / 7 天消耗趋势
  - 重置时间与倒计时
  - 7 天本地趋势曲线、消耗速率与耗尽预测
  - 低额度系统通知（使用黄色阈值触发）
  - 周额度 / 5h 窗口重置前系统提醒
  - 自动刷新间隔切换（1/5/10/30 分钟）、立即刷新（⌘R）、退出
- 正式 **.app 应用**（含图标），可添加到登录项开机自启
- **管理窗口**：渠道增删改、颜色阈值拖动、菜单栏密度、低额度通知、重置前提醒、登录项开关，全部与本地 SQLite 双向同步

## 从源码构建

```bash
git clone https://github.com/ChinaRedArmy1930/CodingPlanBar.git
cd CodingPlanBar
./build-app.sh
```

产物：`build/CodingPlanBar.app`（首次打包会自动生成图标）

运行测试：

```bash
swift test
```

只编译 release 可执行文件：

```bash
swift build -c release
```

当前仓库提供的是源码构建流程。`build-app.sh` 生成的 `.app` 未包含 Developer ID 签名和 notarization；如果你分发给其他用户，macOS Gatekeeper 可能要求右键打开或本地构建。

## 配置与鉴权存储

主配置库：

```text
~/.config/coding-plan-bar/coding-plan-bar.sqlite
```

可用 `CODING_PLAN_BAR_DB` 指定其他 SQLite 文件。数据库固定使用 `0600` 权限，结构为：

| 表 | 内容 |
|---|---|
| `settings` | 颜色阈值、菜单栏密度、通知、登录项等全局设置 |
| `providers` | 渠道名称、类型、Base URL、endpoint、自定义 parser |
| `credentials` | 每个渠道的 Token，按 `provider_id` 与渠道一对一关联 |

管理窗口保存时会写 SQLite。应用会监听配置目录并使用数据库摘要热加载外部修改；应用自身的连接使用 rollback journal，常见 `sqlite3` 修改可以自动同步。如果外部工具长时间使用 WAL 模式，修改停留在 `-wal` 文件时热加载不保证立即触发，重新打开应用会始终读取最新提交数据。鉴权信息单独放在 `credentials` 表里，普通渠道配置不混用 Token 字段。

旧版 `config.json` 会在 SQLite 首次初始化且尚无渠道时自动导入。导入成功后，旧 JSON 会被替换为无 Token 的迁移标记，避免明文鉴权同时存在两份。

```json
{
  "storage": "sqlite",
  "database": "~/.config/coding-plan-bar/coding-plan-bar.sqlite",
  "migrated_at": "2026-09-25T..."
}
```

如果需要重新从 JSON 导入，先确认 `config.json` 是完整旧格式，再删除或换一个新的 `CODING_PLAN_BAR_DB` 路径后启动应用。

### SQLite 配置示例

查看结构（不会输出 Token）：

```bash
sqlite3 ~/.config/coding-plan-bar/coding-plan-bar.sqlite '.schema'
```

更新阈值：

```bash
sqlite3 ~/.config/coding-plan-bar/coding-plan-bar.sqlite \
  "INSERT INTO settings(key,value,updated_at) VALUES('thresholds.green','50',strftime('%s','now')) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
```

新增或修改渠道建议通过管理窗口完成；直接写 `credentials` 表时务必避免把 Token 输出到终端或日志。

### 旧 JSON 格式

以下格式仅用于首次迁移导入，日常主存储是 SQLite。

```json
{
  "menu_bar_mode": "ring_percent",
  "notifications_enabled": true,
  "launch_at_login": true,
  "providers": [
    {
      "name": "Kimi",
      "type": "kimi",
      "token": "sk-kimi-你的token"
    },
    {
      "name": "GLM",
      "type": "glm",
      "token": "你的智谱APIKey",
      "base_url": "https://open.bigmodel.cn",
      "icon": "✦"
    },
    {
      "name": "DeepSeek",
      "type": "deepseek",
      "token": "sk-你的DeepSeekKey",
      "icon": "🐳"
    },
    {
      "name": "Custom",
      "type": "custom",
      "endpoint": "https://api.example.com/v1/usage",
      "auth_style": "bearer",
      "token": "你的token",
      "parser": {
        "metrics": [
          {
            "label": "余额剩余",
            "remaining_path": "data.remaining",
            "total_path": "data.total",
            "reset_path": "data.reset_at"
          }
        ]
      }
    }
  ]
}
```

可选全局设置：

| 字段 | 默认 | 说明 |
|---|---|---|
| `menu_bar_mode` | `ring_percent` | `ring_percent` 圆环+百分比；`ring_only` 仅圆环；`percent_only` 仅百分比 |
| `notifications_enabled` | `true` | 额度从高于黄色阈值降到低于阈值时发送系统通知 |
| `reset_notifications_enabled` | `true` | 周额度 / 5h 窗口快重置时发送系统提醒；提前量至少 15 分钟，并会大于自动刷新间隔 |
| `launch_at_login` | `false` | GUI 与系统登录项同步；外部修改配置后应用会自动注册/注销 |
| `thresholds.green` | `50` | 高于该值显示绿色 |
| `thresholds.yellow` | `20` | 低于该值显示红色，中间显示黄色 |

本地 7 天趋势保存在同目录 `history.json`，只包含时间戳和剩余百分比，不保存 Token。

### 字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | 显示名称 |
| `type` | 是 | `kimi` / `glm` / `deepseek` / `custom` |
| `token` | 是* | API Token（*也可用环境变量代替） |
| `icon` | 否 | 加载/错误状态图标，默认 Kimi `⚡`、GLM `✦` |
| `base_url` | 否 | 自定义服务地址（GLM 默认智谱，可改 `https://api.z.ai`） |
| `endpoint` | 否 | 完整接口地址覆盖；`custom` 必填 |
| `auth_style` | 否 | `custom` 认证方式：`bearer`（默认）/ `raw` / `none` |
| `parser` | `custom` 必填 | JSON 路径解析规则，支持百分比路径或“剩余量 + 总量”路径 |

自定义解析路径使用点路径访问 JSON，数组用数字下标，例如 `data.limits.0.percentage`。百分比模式中 `used: true` 表示接口返回的是已用百分比，应用会自动换算成剩余百分比。

Token 环境变量兜底：
- Kimi：`KIMI_API_KEY` / `ANTHROPIC_AUTH_TOKEN`
- GLM：`GLM_API_KEY` / `Z_AI_API_KEY` / `ZHIPU_API_KEY`
- DeepSeek：`DEEPSEEK_API_KEY`

SQLite 文件权限由应用自动设为 `0600`。

### 安全边界

SQLite 让配置和鉴权有事务、外键和独立表结构，但数据库内的 Token 仍是明文。`0600` 权限能限制其他本地用户读取，不能防御同一用户下被入侵的进程。如果之后需要更强隔离，可以继续升级为 Keychain 或 SQLCipher。

### 重置提醒边界

周额度 / 5h 重置提醒基于定时刷新接口返回的 `resetDate` 触发。应用退出、系统休眠或接口刷新失败时不会补发错过的提醒；它不是系统级闹钟。

## 运行

```bash
open build/CodingPlanBar.app
```

命令行调试（每个 Provider 请求一次并打印解析结果）：

```bash
.build/release/CodingPlanBar --once
```

## 开机自启动

系统设置 → 通用 → 登录项与扩展 → 添加 `build/CodingPlanBar.app`。

## 项目结构

```
CodingPlanBar/
├── Package.swift
├── .github/workflows/ci.yml # macOS 测试与构建 CI
├── build-app.sh              # 一键打包 .app
├── Resources/Info.plist      # 应用元信息（保留 Dock，可打开管理窗口）
├── Scripts/make-icon.swift   # 程序化生成 App 图标
├── Sources/CodingPlanBar/
    ├── Models.swift          # 配置、API 模型、解析
    ├── ConfigDatabase.swift  # SQLite 配置与鉴权存储
    ├── Store.swift           # 状态管理与自动刷新
    ├── PanelView.swift       # SwiftUI 面板（卡片/进度条）
    ├── ManageView.swift      # 桌面渠道管理窗口
    └── main.swift            # 菜单栏图标 + Popover
└── Tests/CodingPlanBarTests/ # 解析、SQLite 和提醒逻辑测试
└── Tests/CodingPlanBarTests/ # 解析、SQLite 和提醒逻辑测试
```

## 数据来源

- Kimi：`GET https://api.kimi.com/coding/v1/usages`
- GLM：`GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`
- DeepSeek：`GET https://api.deepseek.com/user/balance`（开放平台 API 余额，不是 Coding Plan）

均为官方只读用量接口，不消耗额度。

## License

MIT License. See [LICENSE](LICENSE).
