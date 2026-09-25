import AppKit
import Foundation

// MARK: - 配置模型

struct CustomParser: Decodable {
    struct MetricPath: Decodable {
        let label: String
        let path: String?              // 百分比模式：取值路径（剩余百分比；used:true 表示已用需反转）
        let used: Bool?
        let resetPath: String?
        let remainingPath: String?     // 比例模式：剩余量路径（如 total_available）
        let totalPath: String?         // 比例模式：总量路径（如 total_granted）

        enum CodingKeys: String, CodingKey {
            case label, path, used
            case resetPath = "reset_path"
            case remainingPath = "remaining_path"
            case totalPath = "total_path"
        }
    }

    let metrics: [MetricPath]?
}

struct ProviderConfig: Decodable {
    let name: String
    let type: String            // "kimi" | "glm" | "custom"
    let token: String?
    let icon: String?
    let baseURL: String?
    let endpoint: String?
    let authStyle: String?      // bearer | raw | none（custom 用）
    let parser: CustomParser?   // custom 用：JSON 路径解析规则

    enum CodingKeys: String, CodingKey {
        case name, type, token, icon, parser
        case baseURL = "base_url"
        case endpoint
        case authStyle = "auth_style"
    }

    var resolvedIcon: String {
        icon ?? (ProviderKind(rawType: type)?.defaultIcon ?? "⚡")
    }
}

struct FileConfig: Decodable {
    struct Thresholds: Decodable {
        let green: Int?
        let yellow: Int?
    }

    let providers: [ProviderConfig]?
    let thresholds: Thresholds?
    let token: String?
    let baseURL: String?
    let endpoint: String?
    let menuBarMode: String?
    let notificationsEnabled: Bool?
    let launchAtLogin: Bool?

    enum CodingKeys: String, CodingKey {
        case providers, thresholds, token, endpoint
        case baseURL = "base_url"
        case menuBarMode = "menu_bar_mode"
        case notificationsEnabled = "notifications_enabled"
        case launchAtLogin = "launch_at_login"
    }
}

/// 菜单栏展示密度：配置文件与 GUI 共用
enum MenuBarMode: String, CaseIterable {
    case ringPercent = "ring_percent"
    case ringOnly = "ring_only"
    case percentOnly = "percent_only"

    var title: String {
        switch self {
        case .ringPercent: return "圆环+百分比"
        case .ringOnly: return "仅圆环"
        case .percentOnly: return "仅百分比"
        }
    }
}

enum ConfigResult {
    case ok([ProviderRuntime])
    case failed(String)
}

struct DisplaySettings {
    var menuBarMode: MenuBarMode = .ringPercent
    var notificationsEnabled = true
    var launchAtLogin = false
}

// MARK: - 渠道类型注册表

/// 各渠道类型的展示名 / 默认值 / 认证规则集中于此；type 字符串在 ConfigLoader 边界解析一次
enum ProviderKind: String, CaseIterable {
    case kimi, glm, deepseek, custom

    init?(rawType: String) { self.init(rawValue: rawType.lowercased()) }

    /// 表单 / 详情显示名
    var displayName: String {
        switch self {
        case .kimi: return "Kimi · Moonshot"
        case .glm: return "GLM · 智谱"
        case .deepseek: return "DeepSeek · API"
        case .custom: return "自定义渠道"
        }
    }

    /// 渠道行内短名
    var shortName: String {
        switch self {
        case .kimi: return "Kimi"
        case .glm: return "GLM"
        case .deepseek: return "DeepSeek"
        case .custom: return "自定义"
        }
    }

    /// 菜单栏 emoji 默认图标（可被配置 icon 覆盖）
    var defaultIcon: String {
        switch self {
        case .kimi: return "⚡"
        case .glm: return "✦"
        case .deepseek: return "🐳"
        case .custom: return "◈"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .glm: return "https://open.bigmodel.cn"
        case .deepseek: return "https://api.deepseek.com"
        default: return "https://api.kimi.com"
        }
    }

    /// token 缺省时按序尝试的环境变量
    var envTokenKeys: [String] {
        switch self {
        case .glm: return ["GLM_API_KEY", "Z_AI_API_KEY", "ZHIPU_API_KEY", "ANTHROPIC_AUTH_TOKEN"]
        case .kimi: return ["KIMI_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CODING_PLAN_BAR_TOKEN"]
        case .deepseek: return ["DEEPSEEK_API_KEY"]
        case .custom: return []   // 自定义渠道只用配置文件 token：避免环境变量里的第三方 key 被发往任意域名
        }
    }

    /// 认证方式：custom 读配置（默认 bearer），kimi/glm 按类型固定
    func authStyle(from configured: String?) -> String {
        switch self {
        case .custom: return (configured ?? "bearer").lowercased()
        case .glm: return "raw"
        case .kimi, .deepseek: return "bearer"
        }
    }
}

/// Authorization 头值；nil 表示不发送认证头
func authHeaderValue(authStyle: String, token: String) -> String? {
    switch authStyle {
    case "none": return nil
    case "raw": return token
    default: return "Bearer \(token)"
    }
}

struct ProviderRuntime: Identifiable {
    let id = UUID()
    let name: String
    let kind: ProviderKind?   // nil = 配置错误占位行（不参与刷新）
    let icon: String
    let endpoint: URL
    let token: String
    let authStyle: String     // bearer | raw | none
    let parser: CustomParser?
    var state: ProviderState = .loading
}

enum ProviderState {
    case loading
    case loaded(ProviderSnapshot)
    case failed(String)
}

/// 展示口径：Coding Plan 用百分比额度，API 渠道用金额余额
enum SnapshotDisplayStyle {
    case quota
    case balance
}

/// 结构化快照，供 UI 渲染
struct ProviderSnapshot {
    struct Metric: Identifiable {
        let id = UUID()
        let label: String               // "周额度剩余"
        let remainingFraction: Double   // 0...1，进度条填充（剩余量）
        let valueText: String           // "53/100" / "47%"（剩余）
        let resetDate: Date?
        let remainingPct: Int           // 剩余百分比，决定颜色
    }

    let remainingPct: Int?         // 主指标（圆环与着色）
    let menuText: String           // "53%"
    let primaryLabel: String       // 主指标含义："周额度" / "月度 Tokens"
    let badge: String?             // "Coding Plan" / "Coding Plan · Pro"
    let metrics: [Metric]
    let extraLines: [String]       // 附加说明（如 MCP 明细）
    let fetchedAt: Date
    var displayStyle: SnapshotDisplayStyle = .quota
}

extension ProviderSnapshot {
    /// 第二个指标约定为短周期窗口（Kimi / GLM 均为 5h），用于菜单栏内圈
    var innerMetric: Metric? {
        if let fiveHour = metrics.first(where: { metric in
            let label = metric.label.lowercased()
            return label.contains("5h") || label.contains("5 小时") || label.contains("5小时")
        }) {
            return fiveHour
        }
        // 自定义渠道未必把第二指标命名为 5h；只接受百分比指标，避免把加油包/MCP 计数误当内圈
        return metrics.dropFirst().first { $0.valueText.contains("%") }
    }

    var innerPct: Int? { innerMetric?.remainingPct }

    /// 菜单栏 tooltip / 面板共用的 5h 描述；没有短周期指标时为 nil
    var innerSummary: String? {
        guard let metric = innerMetric else { return nil }
        return "\(metric.label) \(metric.remainingPct)%"
    }
}

extension ProviderRuntime {
    /// 构造请求（含认证头）；App 内刷新与 CLI --once 共用
    func urlRequest() -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData   // 禁用缓存，确保手动刷新拿到最新值
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = authHeaderValue(authStyle: authStyle, token: token) {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 按渠道类型解析响应快照
    func snapshot(from data: Data) -> ProviderSnapshot? {
        switch kind {
        case .glm: return SnapshotBuilder.glm(from: data)
        case .deepseek: return SnapshotBuilder.deepseek(from: data)
        case .custom: return parser.flatMap { SnapshotBuilder.custom(parser: $0, data: data) }
        default: return SnapshotBuilder.kimi(from: data)
        }
    }
}

// MARK: - API 响应模型

struct KimiResponse: Decodable {
    struct Summary: Decodable {
        let limit: String
        let used: String?        // 接口按额度状态可能只返回 used 或 remaining 之一
        let remaining: String?
        let resetTime: String
    }
    struct WindowUsage: Decodable {
        let usedRatio: Double
        let resetTime: String
        enum CodingKeys: String, CodingKey {
            case usedRatio = "used_ratio"
            case resetTime = "reset_time"
        }
    }
    let usage: Summary?
    let usages: [String: WindowUsage]?
    struct Money: Decodable {
        let currency: String?
        let priceInCents: String?
    }

    struct BoosterWallet: Decodable {
        let monthlyChargeLimit: Money?
        let monthlyUsed: Money?

    }

    let boosterWallet: BoosterWallet?

    enum CodingKeys: String, CodingKey {
        case usage, usages
        case boosterWallet = "booster_wallet"
    }
}

/// DeepSeek 开放平台余额：`GET /user/balance`
struct DeepSeekBalanceResponse: Decodable {
    struct BalanceInfo: Decodable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    let isAvailable: Bool?
    let balanceInfos: [BalanceInfo]?

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

struct GLMResponse: Decodable {
    struct Detail: Decodable {
        let modelCode: String
        let usage: Int
    }
    struct Limit: Decodable {
        let type: String
        let unit: Int
        let percentage: Int?
        let usage: Int?
        let currentValue: Int?
        let remaining: Int?
        let nextResetTime: Int64?
        let usageDetails: [Detail]?
    }
    struct Payload: Decodable {
        let limits: [Limit]?
        let level: String?
    }
    let data: Payload?
}

// MARK: - GLM 官方用量趋势（消耗量时间序列）

/// `/api/monitor/usage/model-usage` 响应
struct GLMTrendResponse: Decodable {
    struct ModelSummary: Decodable {
        let modelName: String?
        let totalTokens: Int?
    }

    struct ModelData: Decodable {
        let modelName: String?
        let tokensUsage: [Int]?
    }

    struct TotalUsage: Decodable {
        let totalModelCallCount: Int?
        let totalTokensUsage: Int?
        let modelSummaryList: [ModelSummary]?
    }

    struct TrendData: Decodable {
        let xTime: [String]?
        let modelCallCount: [Int]?
        let tokensUsage: [Int]?
        let totalUsage: TotalUsage?
        let modelDataList: [ModelData]?

        enum CodingKeys: String, CodingKey {
            case xTime = "x_time"
            case modelCallCount
            case tokensUsage
            case totalUsage
            case modelDataList
        }
    }

    let data: TrendData?
}

/// 解析后的官方消耗趋势（与本地 HistoryPoint 的“剩余额度”口径不同，独立存储）
struct GLMUsageTrend {
    let times: [Date]
    let tokensPerHour: [Int]
    let totalTokens: Int
    let totalCalls: Int
    let models: [(name: String, tokens: Int)]
}

/// GLM 渠道的官方趋势包：24h + 7 天两个范围
struct GLMTrendBundle {
    let day: GLMUsageTrend
    let week: GLMUsageTrend?
}

extension GLMUsageTrend {
    /// 7 天视图按天聚合（官方返回小时桶，直接画 169 根柱过密）
    var daily: GLMUsageTrend {
        var dayStarts: [Date] = []
        var sums: [Int] = []
        var index: [Int: Int] = [:]
        let calendar = Calendar.current
        for (time, value) in zip(times, tokensPerHour) {
            let start = calendar.startOfDay(for: time)
            let key = Int(start.timeIntervalSince1970)
            if let i = index[key] {
                sums[i] += value
            } else {
                index[key] = sums.count
                dayStarts.append(start)
                sums.append(value)
            }
        }
        return GLMUsageTrend(
            times: dayStarts, tokensPerHour: sums,
            totalTokens: totalTokens, totalCalls: totalCalls, models: models
        )
    }
}

// MARK: - 日期工具

enum ISODate {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
    static func fromMillis(_ ms: Int64?) -> Date? {
        guard let ms else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

// MARK: - 配置加载

enum ConfigLoader {
    static var displaySettings = DisplaySettings()
    static var configFile: URL {
        if let custom = ProcessInfo.processInfo.environment["CODING_PLAN_BAR_CONFIG"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/coding-plan-bar/config.json")
    }

    static let decoder = JSONDecoder()

    static func loadFileConfig() -> FileConfig? {
        guard let data = try? Data(contentsOf: configFile) else { return nil }
        return try? decoder.decode(FileConfig.self, from: data)
    }

    static func load() -> ConfigResult {
        guard let cfg = loadFileConfig() else {
            if FileManager.default.isReadableFile(atPath: configFile.path) {
                return .failed("配置文件解析失败：\(configFile.path)")
            }
            return .failed("未找到配置文件 \(configFile.path)。请参照 README 配置 providers。")
        }

        (F.greenThreshold, F.yellowThreshold) = F.normalizedThresholds(
            green: cfg.thresholds?.green ?? 50, yellow: cfg.thresholds?.yellow ?? 20
        )
        displaySettings = DisplaySettings(
            menuBarMode: MenuBarMode(rawValue: cfg.menuBarMode ?? "") ?? .ringPercent,
            notificationsEnabled: cfg.notificationsEnabled ?? true,
            launchAtLogin: cfg.launchAtLogin ?? false
        )

        var rawProviders = cfg.providers ?? []
        if rawProviders.isEmpty, let token = cfg.token, !token.isEmpty {
            rawProviders = [ProviderConfig(
                name: "Kimi", type: "kimi", token: token,
                icon: nil, baseURL: cfg.baseURL, endpoint: cfg.endpoint,
                authStyle: nil, parser: nil
            )]
        }
        guard !rawProviders.isEmpty else {
            return .failed("配置中没有 providers。请参照 README 配置。")
        }

        var runtimes: [ProviderRuntime] = []
        var errors: [(name: String, message: String)] = []
        for p in rawProviders {
            guard let kind = ProviderKind(rawType: p.type) else {
                errors.append((p.name, "不支持的 type「\(p.type)」"))
                continue
            }
            let authStyle = kind.authStyle(from: p.authStyle)
            let token = resolveToken(for: p, kind: kind) ?? ""
            guard !token.isEmpty || authStyle == "none" else {
                errors.append((p.name, "未配置 token"))
                continue
            }
            guard let endpoint = resolveEndpoint(type: p.type, baseURL: p.baseURL, endpoint: p.endpoint) else {
                errors.append((p.name, kind == .custom ? "自定义渠道需要 endpoint" : "base_url / endpoint 无效"))
                continue
            }
            if kind == .custom, p.parser?.metrics?.isEmpty != false {
                errors.append((p.name, "自定义渠道缺少 parser.metrics 解析规则"))
                continue
            }
            if kind == .custom, !["bearer", "raw", "none"].contains(authStyle) {
                errors.append((p.name, "auth_style 仅支持 bearer / raw / none"))
                continue
            }
            runtimes.append(ProviderRuntime(
                name: p.name, kind: kind, icon: p.resolvedIcon,
                endpoint: endpoint, token: token,
                authStyle: authStyle, parser: p.parser
            ))
        }

        if runtimes.isEmpty {
            return .failed(errors.map { "\($0.name)：\($0.message)" }.joined(separator: "\n"))
        }
        for e in errors {
            runtimes.append(ProviderRuntime(
                name: e.name,
                kind: nil, icon: "⚠️", endpoint: URL(string: "https://invalid")!,
                token: "", authStyle: "none", parser: nil, state: .failed("\(e.name)：\(e.message)")
            ))
        }
        return .ok(runtimes)
    }

    private static func resolveToken(for p: ProviderConfig, kind: ProviderKind) -> String? {
        if let t = p.token, !t.isEmpty { return t }
        for key in kind.envTokenKeys {
            if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        }
        return nil
    }

    /// endpoint 解析：custom 用显式 endpoint，其余按 base_url / 类型默认值拼接（运行时与 UI 预览共用）
    static func resolveEndpoint(type: String, baseURL: String?, endpoint: String?) -> URL? {
        let kind = ProviderKind(rawType: type)
        if kind == .custom {
            guard let ep = endpoint, !ep.isEmpty else { return nil }
            return URL(string: ep)
        }
        if let ep = endpoint, let url = URL(string: ep) { return url }
        let configuredBase = baseURL.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let base = configuredBase ?? kind?.defaultBaseURL ?? ProviderKind.kimi.defaultBaseURL
        if kind == .glm {
            return URL(string: base + "/api/monitor/usage/quota/limit")
        }
        if kind == .deepseek {
            var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            if s.hasSuffix("/v1") { s.removeLast(3) }
            if s.hasSuffix("/user/balance") { return URL(string: s) }
            return URL(string: s + "/user/balance")
        }
        var s = base
        if s.hasSuffix("/coding/v1") { s += "/usages" }
        else if s.hasSuffix("/coding") { s += "/v1/usages" }
        else if !s.hasSuffix("/usages") { s += "/coding/v1/usages" }
        return URL(string: s)
    }
}

// MARK: - Snapshot 构建

enum SnapshotBuilder {
    static let decoder = JSONDecoder()

    /// 百分比指标：remaining = 100 - used
    private static func percentMetric(label: String, usedPct: Int, resetDate: Date?) -> ProviderSnapshot.Metric {
        let rem = max(0, 100 - usedPct)
        return .init(
            label: label,
            remainingFraction: Double(rem) / 100.0,
            valueText: "\(rem)%",
            resetDate: resetDate,
            remainingPct: rem
        )
    }

    static func kimi(from data: Data) -> ProviderSnapshot? {
        let decoded = try? decoder.decode(KimiResponse.self, from: data)
        guard let usage = decoded?.usage else { return nil }
        let fiveHour = decoded?.usages?["limit_5h"]
        let used = Int(usage.used ?? "") ?? 0
        let limit = Int(usage.limit) ?? 0
        let weekly = decoded?.usages?["limit_7d"]
        let remaining = Int(usage.remaining ?? "")
            ?? (limit > 0 ? max(0, limit - used) : nil)
            ?? weekly.map { max(0, limit - Int(($0.usedRatio * Double(limit)).rounded())) }
            ?? 0

        var metrics: [ProviderSnapshot.Metric] = []
        if limit > 0 {
            metrics.append(.init(
                label: "周额度剩余",
                remainingFraction: Double(remaining) / Double(limit),
                valueText: "\(remaining)/\(limit)",
                resetDate: ISODate.parse(usage.resetTime),
                remainingPct: remaining
            ))
        }
        if let ratio = fiveHour?.usedRatio {
            metrics.append(percentMetric(
                label: "5h 窗口剩余",
                usedPct: Int((ratio * 100).rounded()),
                resetDate: ISODate.parse(fiveHour?.resetTime)
            ))
        }
        var boosterLine: String?
        if let wallet = decoded?.boosterWallet,
           let totalText = wallet.monthlyChargeLimit?.priceInCents,
           let usedText = wallet.monthlyUsed?.priceInCents,
           let total = Double(totalText), let used = Double(usedText), total > 0 {
            if used > 0 {
                let remaining = max(0, total - used)
                let fraction = min(max(remaining / total, 0), 1)
                metrics.append(.init(
                    // monthlyUsed > 0 时才能确认加油包已被使用；0 无法区分“未购买”和“已购买未使用”。
                    label: "加油包剩余",
                    remainingFraction: fraction,
                    valueText: "\(F.moneyShort(cents: remaining, currency: wallet.monthlyUsed?.currency))/\(F.moneyShort(cents: total, currency: wallet.monthlyChargeLimit?.currency))",
                    resetDate: nil,
                    remainingPct: Int((fraction * 100).rounded())
                ))
            } else {
                // monthlyChargeLimit 只是官方给出的月度购买/计入上限，不代表已购买。
                boosterLine = "加油包未检测到使用 · 本月可购 \(F.moneyShort(cents: total, currency: wallet.monthlyChargeLimit?.currency))"
            }
        }
        return ProviderSnapshot(
            remainingPct: limit > 0 ? remaining : nil,
            menuText: "\(remaining)%",
            primaryLabel: "周额度",
            badge: "Coding Plan",
            metrics: metrics,
            extraLines: boosterLine.map { [$0] } ?? [],
            fetchedAt: Date()
        )
    }

    /// DeepSeek 开放平台：余额是金额而非百分比，单独走 `.balance` 展示口径
    static func deepseek(from data: Data) -> ProviderSnapshot? {
        guard let decoded = try? decoder.decode(DeepSeekBalanceResponse.self, from: data),
              let infos = decoded.balanceInfos, !infos.isEmpty else { return nil }

        let primaryIndex = infos.firstIndex { $0.currency == "CNY" } ?? 0
        let primary = infos[primaryIndex]
        guard let totalText = primary.totalBalance else { return nil }

        var extras: [String] = []
        var parts: [String] = []
        if let toppedUp = primary.toppedUpBalance, (Double(toppedUp) ?? 0) > 0 {
            parts.append("充值 \(F.moneyAmount(toppedUp, currency: primary.currency))")
        }
        if let granted = primary.grantedBalance, (Double(granted) ?? 0) > 0 {
            parts.append("赠送 \(F.moneyAmount(granted, currency: primary.currency))")
        }
        if !parts.isEmpty { extras.append(parts.joined(separator: " · ")) }

        for (index, info) in infos.enumerated() where index != primaryIndex {
            guard let total = info.totalBalance else { continue }
            extras.append("\(info.currency ?? "其他") 余额 \(F.moneyAmount(total, currency: info.currency))")
        }
        if decoded.isAvailable == false {
            extras.append("账户余额不可用，请检查充值状态")
        }

        return ProviderSnapshot(
            remainingPct: decoded.isAvailable == false ? 0 : nil,
            menuText: F.moneyAmount(totalText, currency: primary.currency),
            primaryLabel: "API 余额",
            badge: "DeepSeek API",
            metrics: [],
            extraLines: extras,
            fetchedAt: Date(),
            displayStyle: .balance
        )
    }

    static func glm(from data: Data) -> ProviderSnapshot? {
        let decoded = try? decoder.decode(GLMResponse.self, from: data)
        guard let payload = decoded?.data, let limits = payload.limits, !limits.isEmpty else { return nil }

        // unit=6：周额度（重置周期为每周）；unit=3：5 小时窗口
        let fiveHour = limits.first { $0.type == "TOKENS_LIMIT" && $0.unit == 3 }
        let monthly = limits.first { $0.type == "TOKENS_LIMIT" && $0.unit == 6 } ?? fiveHour
        let mcp = limits.first { $0.type == "TIME_LIMIT" }

        var metrics: [ProviderSnapshot.Metric] = []
        var remainingPct: Int? = nil
        if let m = monthly, let usedPct = m.percentage {
            remainingPct = max(0, 100 - usedPct)
            metrics.append(percentMetric(label: "周额度剩余", usedPct: usedPct, resetDate: ISODate.fromMillis(m.nextResetTime)))
        }
        if let f = fiveHour, let usedPct = f.percentage {
            metrics.append(percentMetric(label: "5h 窗口剩余", usedPct: usedPct, resetDate: ISODate.fromMillis(f.nextResetTime)))
        }
        var extras: [String] = []
        if let m = mcp {
            let used = m.currentValue ?? 0
            let total = m.usage ?? 0
            let rem = m.remaining ?? max(0, total - used)
            metrics.append(.init(
                label: "MCP 月度剩余",
                remainingFraction: total > 0 ? Double(rem) / Double(total) : 1,
                valueText: "\(rem)/\(total)",
                resetDate: ISODate.fromMillis(m.nextResetTime),
                remainingPct: total > 0 ? Int((Double(rem) / Double(total)) * 100) : 100
            ))
            if let details = m.usageDetails, !details.isEmpty {
                let text = details
                    .filter { $0.usage > 0 }
                    .map { "\($0.modelCode) \($0.usage)" }
                    .joined(separator: " · ")
                if !text.isEmpty { extras.append(text) }
            }
        }
        if metrics.isEmpty { return nil }

        return ProviderSnapshot(
            remainingPct: remainingPct,
            menuText: remainingPct.map { "\($0)%" } ?? "?",
            primaryLabel: "周额度",
            badge: payload.level.map { "Coding Plan · " + $0.prefix(1).uppercased() + $0.dropFirst() },
            metrics: metrics,
            extraLines: extras,
            fetchedAt: Date()
        )
    }

    private static let glmTrendTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// GLM 官方趋势：`startTime`/`endTime` 参数与返回的 x_time 均为本地时区
    static func glmTrendURL(from endpoint: URL, hours: Int, now: Date = Date()) -> URL? {
        guard var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        comps.path = "/api/monitor/usage/model-usage"
        comps.queryItems = [
            URLQueryItem(name: "startTime", value: fmt.string(from: now.addingTimeInterval(-Double(hours) * 3600))),
            URLQueryItem(name: "endTime", value: fmt.string(from: now)),
        ]
        return comps.url
    }

    static func glmTrend(from data: Data) -> GLMUsageTrend? {
        guard let decoded = try? decoder.decode(GLMTrendResponse.self, from: data) else { return nil }
        guard let payload = decoded.data,
              let xTime = payload.xTime, let tokens = payload.tokensUsage, !xTime.isEmpty else { return nil }
        let count = min(xTime.count, tokens.count)
        guard count > 0 else { return nil }

        var times: [Date] = []
        var values: [Int] = []
        for i in 0..<count {
            if let date = glmTrendTime.date(from: xTime[i]) {
                times.append(date)
                values.append(tokens[i])
            }
        }
        guard !times.isEmpty else { return nil }

        let models = (payload.totalUsage?.modelSummaryList ?? [])
            .compactMap { summary -> (String, Int)? in
                guard let name = summary.modelName, let total = summary.totalTokens, total > 0 else { return nil }
                return (name, total)
            }
            .sorted { $0.1 > $1.1 }

        return GLMUsageTrend(
            times: times,
            tokensPerHour: values,
            totalTokens: payload.totalUsage?.totalTokensUsage ?? values.reduce(0, +),
            totalCalls: payload.totalUsage?.totalModelCallCount
                ?? (payload.modelCallCount ?? []).reduce(0, +),
            models: models
        )
    }
}

// MARK: - JSON 路径解析（自定义渠道）

enum Path {
    /// 点路径取值：`data.limits.0.percentage`，支持数组下标
    static func value(at path: String?, in json: Any) -> Any? {
        guard let path, !path.isEmpty else { return nil }
        var current: Any? = json
        for part in path.split(separator: ".") {
            if let idx = Int(part), let arr = current as? [Any] {
                guard idx >= 0, idx < arr.count else { return nil }
                current = arr[idx]
            } else if let dict = current as? [String: Any] {
                current = dict[String(part)]
            } else {
                return nil
            }
        }
        return current
    }

    /// 重置时间：自动识别毫秒 / 秒时间戳 / ISO8601 字符串
    static func date(at path: String?, in json: Any) -> Date? {
        guard let v = value(at: path, in: json) else { return nil }
        if let n = v as? NSNumber {
            let t = n.doubleValue
            if t > 1e12 { return ISODate.fromMillis(Int64(t)) }
            if t > 1e9 { return Date(timeIntervalSince1970: t) }
            return nil
        }
        if let str = v as? String { return ISODate.parse(str) }
        return nil
    }
}

// MARK: - 自定义渠道解析

extension SnapshotBuilder {
    static func custom(parser: CustomParser, data: Data) -> ProviderSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var metrics: [ProviderSnapshot.Metric] = []
        for m in parser.metrics ?? [] {
            // 比例模式：remaining_path / total_path（适合返回金额/次数的接口，如 OpenAI credits）
            if let remRaw = Path.value(at: m.remainingPath, in: json),
               let totalRaw = Path.value(at: m.totalPath, in: json),
               let rem = Self.double(remRaw), let total = Self.double(totalRaw),
               total > 0 {
                let fraction = min(max(rem / total, 0), 1)
                metrics.append(.init(
                    label: m.label,
                    remainingFraction: fraction,
                    valueText: "\(Int((fraction * 100).rounded()))%",
                    resetDate: Path.date(at: m.resetPath, in: json),
                    remainingPct: Int((fraction * 100).rounded())
                ))
                continue
            }
            // 百分比模式：path 直接取剩余百分比（used:true 反转）
            guard let raw = Path.value(at: m.path, in: json) else { continue }
            guard let num = Self.double(raw) else { continue }
            let value = m.used == true ? 100 - num : num
            let clamped = min(max(value, 0), 100)
            metrics.append(.init(
                label: m.label,
                remainingFraction: clamped / 100.0,
                valueText: "\(Int(clamped.rounded()))%",
                resetDate: Path.date(at: m.resetPath, in: json),
                remainingPct: Int(clamped.rounded())
            ))
        }
        guard !metrics.isEmpty else { return nil }
        let primary = metrics[0]
        let primaryLabel = primary.label.replacingOccurrences(of: "剩余", with: "")
        return ProviderSnapshot(
            remainingPct: primary.remainingPct,
            menuText: "\(primary.remainingPct)%",
            primaryLabel: primaryLabel.isEmpty ? "额度" : primaryLabel,
            badge: "自定义",
            metrics: metrics,
            extraLines: [],
            fetchedAt: Date()
        )
    }
}

extension SnapshotBuilder {
    static func double(_ raw: Any) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
}

// MARK: - 格式化与颜色

enum F {
    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let trendAxis: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH时"
        return f
    }()
    static let trendDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
    /// 紧凑计数：1234567 → 1.2M
    static func compactCount(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
        case 1_000_000...: return String(format: "%.1fM", d / 1e6)
        case 1_000...: return String(format: "%.1fK", d / 1e3)
        default: return "\(n)"
        }
    }
    static func money(cents: Double, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: NSNumber(value: cents / 100)) ?? String(format: "%.2f", cents / 100)
        switch currency {
        case "CNY": return "¥\(amount)"
        case "USD": return "$\(amount)"
        default: return "\(amount) \(currency ?? "")".trimmingCharacters(in: .whitespaces)
        }
    }
    /// 金额字符串（DeepSeek 等接口直接返回元，如 "110.00"）
    static func moneyAmount(_ text: String, currency: String?) -> String {
        guard let value = Double(text) else { return "\(text) \(currency ?? "")".trimmingCharacters(in: .whitespaces) }
        return money(cents: value * 100, currency: currency)
    }
    /// 紧凑金额：整数省略小数（¥100.00 → ¥100），用于空间受限的指标行
    static func moneyShort(cents: Double, currency: String?) -> String {
        let amount = cents / 100
        let symbol: String
        switch currency {
        case "CNY": symbol = "¥"
        case "USD": symbol = "$"
        default: symbol = ""
        }
        let text = amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(amount))
            : String(format: "%.2f", amount)
        return symbol.isEmpty ? "\(text) \(currency ?? "")".trimmingCharacters(in: .whitespaces) : "\(symbol)\(text)"
    }
    private static let relative: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.day, .hour, .minute]
        return f
    }()
    static func resetCaption(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 { return "\(F.time.string(from: date)) 已重置" }
        let left = relative.string(from: interval) ?? "-"
        return "\(F.full.string(from: date)) 重置 · 还剩 \(left)"
    }
    static func relativeShort(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 50 { return "刚刚更新" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前更新" }
        return "\(Int(interval / 3600)) 小时前更新"
    }
    /// 颜色阈值（可由配置文件 thresholds 覆盖）：>green 绿，yellow...green 黄，<yellow 红
    static var greenThreshold = 50
    static var yellowThreshold = 20

    /// 阈值归一化：green ≥ 1，yellow 夹在 [0, green]（配置加载与保存共用）
    static func normalizedThresholds(green: Int, yellow: Int) -> (green: Int, yellow: Int) {
        let g = max(green, 1)
        return (g, min(max(yellow, 0), g))
    }

    static func statusColor(remainingPct: Int?) -> NSColor {
        guard let p = remainingPct else { return .systemBlue }
        if p < yellowThreshold { return .systemRed }
        if p <= greenThreshold { return .systemYellow }
        return .systemGreen
    }
}

/// 圆环进度图标（菜单栏与面板共用）：
/// 外圈 = 周额度剩余（描边圆环），内圈 = 5h 窗口剩余（实心扇形）；两者分别按阈值着色
func ringImage(remainingPct: Int?, innerPct: Int? = nil, size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let inset: CGFloat = max(1.2, size * 0.10)
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radius = rect.width / 2
    let outerWidth = max(1.7, size * 0.115)
    let innerRadius = max(1.0, radius - outerWidth - max(0.8, size * 0.05))

    func strokeArc(radius: CGFloat, lineWidth: CGFloat, pct: Int?, color: NSColor?) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        track.lineWidth = lineWidth
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        track.stroke()

        guard let pct, pct > 0 else { return }
        let sweep = 360.0 * CGFloat(min(max(pct, 0), 100)) / 100.0
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        (color ?? F.statusColor(remainingPct: pct)).setStroke()
        arc.stroke()
    }

    strokeArc(
        radius: radius,
        lineWidth: outerWidth,
        pct: remainingPct,
        color: F.statusColor(remainingPct: remainingPct)
    )
    if let innerPct {
        let diskRect = NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )
        let disk = NSBezierPath(ovalIn: diskRect)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        disk.fill()

        let clamped = min(max(innerPct, 0), 100)
        if clamped >= 100 {
            F.statusColor(remainingPct: clamped).setFill()
            disk.fill()
        } else if clamped > 0 {
            let sweep = 360.0 * CGFloat(clamped) / 100.0
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: innerRadius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            wedge.close()
            F.statusColor(remainingPct: clamped).setFill()
            wedge.fill()
        }
    }

    img.unlockFocus()
    return img
}
