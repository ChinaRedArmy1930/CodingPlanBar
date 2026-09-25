# Coding Plan Bar

原生 macOS 菜单栏应用（Swift + AppKit + SwiftUI），多 Provider 可配置，实时展示 Coding Plan 剩余额度。内置支持 **Kimi** 与 **GLM（智谱 / Z.ai）**，也可通过 JSON 路径解析接入其他只读用量接口。

## 界面

- **菜单栏**：每个 Provider 一个圆环进度指示器 + 剩余百分比（绿/黄/红三档着色，一眼看清余量）
  - 支持三种密度：圆环+百分比 / 仅圆环 / 仅百分比
- **点击图标**：弹出 CCSwitch 风格的面板（Popover）
  - Provider 卡片：圆环 + 大号剩余百分比 + 徽章（套餐等级）
  - 指标进度条：周额度 / 5h 窗口 / Kimi 加油包 / MCP 月度
  - GLM 官方 24 小时 / 7 天消耗趋势
  - 重置时间与倒计时
  - 7 天本地趋势曲线、消耗速率与耗尽预测
  - 低额度系统通知（使用黄色阈值触发）
  - 自动刷新间隔切换（1/5/10/30 分钟）、立即刷新（⌘R）、退出
- 正式 **.app 应用**（含图标），可添加到登录项开机自启
- **管理窗口**：渠道增删改、颜色阈值拖动、菜单栏密度、低额度通知、登录项开关，全部与配置文件双向同步

## 编译打包

```bash
cd ~/code/CodingPlanBar
./build-app.sh
```

产物：`build/CodingPlanBar.app`（首次打包会自动生成图标）

## 配置

配置文件：`~/.config/coding-plan-bar/config.json`
（可用环境变量 `CODING_PLAN_BAR_CONFIG` 指定其他路径）

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
| `launch_at_login` | `false` | GUI 与系统登录项同步；外部修改配置后应用会自动注册/注销 |
| `thresholds.green` | `50` | 高于该值显示绿色 |
| `thresholds.yellow` | `20` | 低于该值显示红色，中间显示黄色 |

本地 7 天趋势保存在同目录 `history.json`，只包含时间戳和剩余百分比，不保存 Token。

### 字段说明

| 字段 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | 显示名称 |
| `type` | 是 | `kimi` / `glm` / `custom` |
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

建议权限：`chmod 600 ~/.config/coding-plan-bar/config.json`

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
├── build-app.sh              # 一键打包 .app
├── Resources/Info.plist      # 应用元信息（保留 Dock，可打开管理窗口）
├── Scripts/make-icon.swift   # 程序化生成 App 图标
└── Sources/CodingPlanBar/
    ├── Models.swift          # 配置、API 模型、解析
    ├── Store.swift           # 状态管理与自动刷新
    ├── PanelView.swift       # SwiftUI 面板（卡片/进度条）
    ├── ManageView.swift      # 桌面渠道管理窗口
    └── main.swift            # 菜单栏图标 + Popover
```

## 数据来源

- Kimi：`GET https://api.kimi.com/coding/v1/usages`
- GLM：`GET https://open.bigmodel.cn/api/monitor/usage/quota/limit`

均为官方只读用量接口，不消耗额度。
