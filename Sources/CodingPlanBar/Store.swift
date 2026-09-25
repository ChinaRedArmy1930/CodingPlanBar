import Foundation
import ServiceManagement
import UserNotifications

// MARK: - 本地用量历史（7 天趋势 / 消耗速率）

struct HistoryPoint: Codable, Identifiable {
    var id: Date { time }
    let time: Date
    let pct: Double
}

/// 渠道编辑草稿（管理界面用）
struct ProviderDraft: Identifiable {
    let id = UUID()
    var name: String
    var type: String              // "kimi" | "glm" | "custom"
    var icon: String = ""
    var token: String = ""        // 新输入；留空 = 沿用 existingToken
    var existingToken: String
    var baseURL: String = ""
    // 自定义渠道
    var endpoint: String = ""
    var authStyle: String = "bearer"
    var mainPath: String = ""
    // 比例模式（remaining_path / total_path，如 OpenAI credits）
    var mainRemainingPath: String = ""
    var mainTotalPath: String = ""
    var extraRemainingPath: String = ""
    var extraTotalPath: String = ""
    var mainResetPath: String = ""
    var extraPath: String = ""
    var extraResetPath: String = ""

    /// 生效 token：未输入新值时沿用原值
    var effectiveToken: String { token.isEmpty ? existingToken : token }

    /// 解析后的渠道类型（无效 type 为 nil）
    var kind: ProviderKind? { ProviderKind(rawType: type) }

    /// 按当前草稿字段解析出的实际请求地址（与运行时同一套逻辑）
    var resolvedEndpoint: URL? {
        ConfigLoader.resolveEndpoint(
            type: type, baseURL: baseURL.isEmpty ? nil : baseURL, endpoint: endpoint.isEmpty ? nil : endpoint
        )
    }
}

/// 全局状态：providers 状态、倒计时自动刷新、配置管理
final class AppStore: ObservableObject {
    static let configDidChange = Notification.Name("CodingPlanBarConfigDidChange")

    /// 可选的自动刷新间隔（分钟）；两个 Picker 与初始化校验共用
    static let refreshIntervalOptions = [1, 5, 10, 30]

    @Published private(set) var providers: [ProviderRuntime] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var configError: String?
    @Published private(set) var menuBarMode: MenuBarMode = .ringPercent
    @Published private(set) var notificationsEnabled = true
    @Published private(set) var launchAtLogin = false
    @Published private(set) var histories: [String: [HistoryPoint]] = [:]
    /// GLM 官方消耗趋势（按渠道名索引；失败不覆盖旧数据，趋势区直接隐藏）
    @Published private(set) var glmTrends: [String: GLMTrendBundle] = [:]
    @Published var refreshMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes")
            resetNextRefresh()
        }
    }

    /// 菜单栏标题需要重绘时回调
    var onStateChange: (() -> Void)?

    /// 合并同一 runloop 内的多次状态变更，避免批量刷新时重复重绘菜单栏
    private var stateChangePending = false
    private func notifyStateChange() {
        guard !stateChangePending else { return }
        stateChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateChangePending = false
            self.onStateChange?()
        }
    }

    private var refreshTimer: Timer?
    private(set) var nextRefreshAt = Date.distantFuture
    private var notificationBaseline: [String: Bool] = [:]
    private var notificationCenterConfigured = false
    private var glmTrendFetchedAt: [String: Date] = [:]

    // 配置数据库监听（外部修改 → 热加载）
    private var configSource: DispatchSourceFileSystemObject?
    private var lastConfigDigest = ""
    private var configReloadDebounce: DispatchWorkItem?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "refreshMinutes")
        refreshMinutes = Self.refreshIntervalOptions.contains(saved) ? saved : 5
        histories = Self.loadHistories()

        applyConfig(ConfigLoader.load())
    }

    /// 应用配置加载结果（初始化与热重载共用）
    private func applyConfig(_ result: ConfigResult) {
        switch result {
        case .ok(let list):
            providers = list
            configError = nil
            applyDisplaySettings(ConfigLoader.displaySettings)
        case .failed(let msg):
            configError = msg
        }
    }

    func start() {
        refreshAll()
        startConfigWatch()
        configureNotificationsIfNeeded()
        reconcileLaunchAtLogin()
    }

    private func applyDisplaySettings(_ settings: DisplaySettings) {
        menuBarMode = settings.menuBarMode
        notificationsEnabled = settings.notificationsEnabled
        launchAtLogin = settings.launchAtLogin
    }

    // MARK: 配置数据库监听

    /// 监听配置目录变化，外部修改 SQLite 后热加载
    private func startConfigWatch() {
        let dir = ConfigLoader.databaseFile.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleConfigReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
        lastConfigDigest = Self.configDigest
    }

    private static var configDigest: String {
        ConfigDatabase.digest()
    }

    /// 去抖 0.5s：过滤编辑器/SQLite 临时文件产生的事件风暴；内容相同则忽略（防止自己保存触发循环）
    private func scheduleConfigReload() {
        configReloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let digest = Self.configDigest
            guard !digest.isEmpty, digest != self.lastConfigDigest else { return }
            self.lastConfigDigest = digest
            self.reload()
        }
        configReloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: 显示与系统集成设置（SQLite <-> GUI 双向）

    private func updateConfigSetting(key: String, value: String) throws {
        try ConfigDatabase.setValue(key: key, value: value)
        lastConfigDigest = Self.configDigest
    }

    func setMenuBarMode(_ mode: MenuBarMode) {
        guard mode != menuBarMode else { return }
        do {
            try updateConfigSetting(key: "menu_bar_mode", value: mode.rawValue)
            ConfigLoader.displaySettings.menuBarMode = mode
            menuBarMode = mode
            objectWillChange.send()
            notifyStateChange()
        } catch {
            NSLog("[CPB] 保存菜单栏模式失败：\(error)")
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled != notificationsEnabled else { return }
        do {
            try updateConfigSetting(key: "notifications_enabled", value: enabled ? "true" : "false")
            ConfigLoader.displaySettings.notificationsEnabled = enabled
            notificationsEnabled = enabled
            if enabled { configureNotifications(force: true) }
            objectWillChange.send()
        } catch {
            NSLog("[CPB] 保存通知设置失败：\(error)")
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            try updateConfigSetting(key: "launch_at_login", value: enabled ? "true" : "false")
            ConfigLoader.displaySettings.launchAtLogin = enabled
            launchAtLogin = enabled
        } catch {
            // 系统登录项失败时不同步成功状态，让 GUI 立即回到真实状态
            launchAtLogin = SMAppService.mainApp.status == .enabled
            throw error
        }
    }

    private func reconcileLaunchAtLogin() {
        if launchAtLogin {
            try? setLaunchAtLogin(true)
        } else if SMAppService.mainApp.status == .enabled {
            launchAtLogin = true
        }
    }

    private func configureNotificationsIfNeeded() {
        if notificationsEnabled { configureNotifications(force: false) }
    }

    private func configureNotifications(force: Bool) {
        guard force || !notificationCenterConfigured else { return }
        notificationCenterConfigured = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.provisional]) { _, error in
            if let error { NSLog("[CPB] 通知授权失败：\(error.localizedDescription)") }
        }
    }

    // MARK: 倒计时自动刷新

    /// 当前颜色阈值（管理界面回显）
    var currentThresholds: (green: Int, yellow: Int) {
        (F.greenThreshold, F.yellowThreshold)
    }

    var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }

    /// 基于任意时刻的倒计时比例（TimelineView 按需调用）
    func countdownFraction(at date: Date) -> Double {
        let remaining = max(0, nextRefreshAt.timeIntervalSince(date))
        return min(max(remaining / refreshInterval, 0), 1)
    }

    func countdownText(at date: Date) -> String {
        let sec = Int(max(0, nextRefreshAt.timeIntervalSince(date)).rounded())
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    /// 面板打开时调用：数据过旧（或从未成功刷新）才重新请求
    func refreshIfStale(maxAge: TimeInterval = 90) {
        if lastRefresh.map({ Date().timeIntervalSince($0) > maxAge }) ?? true {
            refreshAll()
        }
    }

    private func resetNextRefresh() {
        nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: false) { [weak self] _ in
            self?.refreshAll()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: 数据刷新

    func refreshAll(forceTrends: Bool = false) {
        resetNextRefresh()
        guard configError == nil else { return }
        for index in providers.indices where providers[index].kind != nil {
            refresh(index: index, forceTrends: forceTrends)
        }
    }

    private func refresh(index: Int, forceTrends: Bool) {
        let p = providers[index]
        providers[index].state = .loading
        notifyStateChange()
        if p.kind == .glm {
            fetchGLMTrend(for: p, force: forceTrends)
        }

        URLSession.shared.dataTask(with: p.urlRequest()) { [weak self] data, response, error in
            // 解析（JSON decode）在后台队列完成，主线程只落状态
            let state = Self.parseState(for: p, data: data, response: response, error: error)
            DispatchQueue.main.async {
                self?.applyState(state, index: index, providerID: p.id)
            }
        }.resume()
    }

    /// 官方趋势为小时粒度，独立于额度刷新做 10 分钟节流（1 分钟刷新档下避免重复请求）
    private func fetchGLMTrend(for p: ProviderRuntime, force: Bool) {
        if !force,
           let at = glmTrendFetchedAt[p.name],
           Date().timeIntervalSince(at) < 600, glmTrends[p.name] != nil {
            return
        }
        var dayTrend: GLMUsageTrend?
        var weekTrend: GLMUsageTrend?
        let group = DispatchGroup()

        func request(_ hours: Int, completion: @escaping (GLMUsageTrend?) -> Void) {
            guard let url = SnapshotBuilder.glmTrendURL(from: p.endpoint, hours: hours) else {
                completion(nil)
                return
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(p.token, forHTTPHeaderField: "Authorization")   // GLM 认证为 raw token
            URLSession.shared.dataTask(with: request) { data, _, _ in
                let trend = data.flatMap { SnapshotBuilder.glmTrend(from: $0) }
                DispatchQueue.main.async { completion(trend) }
            }.resume()
        }

        glmTrendFetchedAt[p.name] = Date()
        group.enter()
        request(24) { trend in dayTrend = trend; group.leave() }
        group.enter()
        request(24 * 7) { trend in weekTrend = trend; group.leave() }
        group.notify(queue: .main) { [weak self] in
            guard let self, let day = dayTrend else { return }
            self.glmTrends[p.name] = GLMTrendBundle(day: day, week: weekTrend)
        }
    }

    private static func parseState(for p: ProviderRuntime, data: Data?, response: URLResponse?, error: Error?) -> ProviderState {
        if let error {
            return .failed("网络错误：\(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var detail = ""
            if let data, let s = String(data: data, encoding: .utf8) { detail = String(s.prefix(120)) }
            return .failed("HTTP \(http.statusCode) \(detail)")
        }
        guard let data else { return .failed("空响应") }
        guard let snapshot = p.snapshot(from: data) else { return .failed("响应解析失败") }
        return .loaded(snapshot)
    }

    private func applyState(_ state: ProviderState, index: Int, providerID: UUID) {
        guard index < providers.count, providers[index].id == providerID else { return }
        let providerName = providers[index].name
        providers[index].state = state
        if case .loaded(let snapshot) = state {
            lastRefresh = Date()
            recordHistory(snapshot: snapshot, providerName: providerName)
            evaluateLowQuotaNotifications(snapshot: snapshot, providerName: providerName)
        }
        notifyStateChange()
    }

    // MARK: - 历史记录 / 消耗速率

    private static var historyFile: URL {
        ConfigLoader.configFile.deletingLastPathComponent().appendingPathComponent("history.json")
    }

    private static func loadHistories() -> [String: [HistoryPoint]] {
        guard let data = try? Data(contentsOf: historyFile) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: [HistoryPoint]].self, from: data)) ?? [:]
    }

    private func recordHistory(snapshot: ProviderSnapshot, providerName: String) {
        let now = Date()
        for metric in snapshot.metrics {
            let key = Self.historyKey(provider: providerName, metric: metric.label)
            var points = histories[key] ?? []
            points.append(HistoryPoint(time: now, pct: Double(metric.remainingPct)))
            let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
            points.removeAll { $0.time < cutoff }
            if points.count > 2400 { points.removeFirst(points.count - 2400) }
            histories[key] = points
        }
        persistHistories()
    }

    private func persistHistories() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(histories) {
            try? data.write(to: Self.historyFile, options: .atomic)
        }
    }

    static func historyKey(provider: String, metric: String) -> String {
        "\(provider)\u{001F}\(metric)"
    }

    func historyPoints(provider: String, metric: String) -> [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return (histories[Self.historyKey(provider: provider, metric: metric)] ?? [])
            .filter { $0.time >= cutoff }
    }

    /// 使用最近 6 小时样本做线性回归估算消耗速率；样本太短时不给结论，避免误导
    static func burnRate(points: [HistoryPoint], now: Date = Date()) -> Double? {
        let samples = points.filter { now.timeIntervalSince($0.time) <= 6 * 3600 }
        guard let first = samples.first, let last = samples.last,
              last.time.timeIntervalSince(first.time) >= 300 else { return nil }

        // 简单线性回归比“首尾两点”更抗偶发抖动；这里把时间归一成小时
        let reference = first.time.timeIntervalSince1970
        let xs = samples.map { ($0.time.timeIntervalSince1970 - reference) / 3600 }
        let ys = samples.map(\.pct)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        let rate = -slope
        return rate > 0 && rate < 100 ? rate : nil
    }

    // MARK: - 低额度通知

    private func evaluateLowQuotaNotifications(snapshot: ProviderSnapshot, providerName: String) {
        guard notificationsEnabled else {
            notificationBaseline.removeAll()
            return
        }
        for metric in snapshot.metrics {
            let key = "\(providerName)\u{001F}\(metric.label)"
            let isLow = metric.remainingPct < F.yellowThreshold
            let wasLow = notificationBaseline[key] ?? false
            if isLow, !wasLow {
                sendLowQuotaNotification(providerName: providerName, metric: metric)
            }
            notificationBaseline[key] = isLow
        }
    }

    private func sendLowQuotaNotification(providerName: String, metric: ProviderSnapshot.Metric) {
        let content = UNMutableNotificationContent()
        content.title = "\(providerName) 额度偏低"
        content.body = "\(metric.label) \(metric.valueText)，低于 \(F.yellowThreshold)% 阈值"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "low-quota-\(providerName)-\(metric.label)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: 配置管理（管理界面）

    /// 从 SQLite 读取可编辑草稿
    func loadDrafts() -> [ProviderDraft] {
        guard let cfg = ConfigLoader.loadFileConfig() else { return [] }
        return (cfg.providers ?? []).map { p in
            var d = ProviderDraft(
                name: p.name, type: p.type.lowercased(),
                existingToken: p.token ?? "", baseURL: p.baseURL ?? ""
            )
            d.icon = p.icon ?? ""
            d.endpoint = p.endpoint ?? ""
            d.authStyle = ProviderKind(rawType: p.type)?.authStyle(from: p.authStyle) ?? "bearer"
            let metrics = p.parser?.metrics ?? []
            if metrics.count > 0 {
                d.mainPath = metrics[0].path ?? ""
                d.mainResetPath = metrics[0].resetPath ?? ""
                d.mainRemainingPath = metrics[0].remainingPath ?? ""
                d.mainTotalPath = metrics[0].totalPath ?? ""
            }
            if metrics.count > 1 {
                d.extraPath = metrics[1].path ?? ""
                d.extraResetPath = metrics[1].resetPath ?? ""
                d.extraRemainingPath = metrics[1].remainingPath ?? ""
                d.extraTotalPath = metrics[1].totalPath ?? ""
            }
            return d
        }
    }

    /// 保存渠道列表与阈值到 SQLite，并热重载
    /// - Parameter refreshData: 渠道列表变化时为 true（重新加载并刷新网络）；仅阈值变化时为 false（只重绘颜色）
    func saveConfig(drafts: [ProviderDraft], green: Int, yellow: Int, refreshData: Bool = true) throws {
        let (g, y) = F.normalizedThresholds(green: green, yellow: yellow)
        var providerConfigs: [ProviderConfig] = []
        for draft in drafts {
            var metrics: [CustomParser.MetricPath] = []
            if draft.type == "custom" {
                metrics.append(CustomParser.MetricPath(
                    label: "余额剩余",
                    path: draft.mainRemainingPath.isEmpty || draft.mainTotalPath.isEmpty ? draft.mainPath : nil,
                    used: nil,
                    resetPath: draft.mainResetPath.isEmpty ? nil : draft.mainResetPath,
                    remainingPath: draft.mainRemainingPath.isEmpty ? nil : draft.mainRemainingPath,
                    totalPath: draft.mainTotalPath.isEmpty ? nil : draft.mainTotalPath
                ))
                if !draft.extraPath.isEmpty || (!draft.extraRemainingPath.isEmpty && !draft.extraTotalPath.isEmpty) {
                    metrics.append(CustomParser.MetricPath(
                        label: "5h 窗口剩余",
                        path: draft.extraRemainingPath.isEmpty || draft.extraTotalPath.isEmpty ? draft.extraPath : nil,
                        used: nil,
                        resetPath: draft.extraResetPath.isEmpty ? nil : draft.extraResetPath,
                        remainingPath: draft.extraRemainingPath.isEmpty ? nil : draft.extraRemainingPath,
                        totalPath: draft.extraTotalPath.isEmpty ? nil : draft.extraTotalPath
                    ))
                }
            }
            providerConfigs.append(ProviderConfig(
                name: draft.name,
                type: draft.type,
                token: draft.effectiveToken,
                icon: draft.icon.isEmpty ? nil : draft.icon,
                baseURL: draft.baseURL.isEmpty ? nil : draft.baseURL,
                endpoint: draft.endpoint.isEmpty ? nil : draft.endpoint,
                authStyle: draft.type == "custom" ? draft.authStyle : nil,
                parser: draft.type == "custom" ? CustomParser(metrics: metrics) : nil
            ))
        }

        let config = FileConfig(
            providers: providerConfigs,
            thresholds: .init(green: g, yellow: y),
            token: nil,
            baseURL: nil,
            endpoint: nil,
            menuBarMode: menuBarMode.rawValue,
            notificationsEnabled: notificationsEnabled,
            launchAtLogin: launchAtLogin
        )
        try ConfigDatabase.saveConfig(config)
        lastConfigDigest = Self.configDigest

        F.greenThreshold = g
        F.yellowThreshold = y
        if refreshData {
            reload()
        } else {
            // 仅阈值变化：不重新请求网络，只触发 UI 重绘（面板 + 菜单栏颜色）
            objectWillChange.send()
            notifyStateChange()
        }
    }

    /// 配置变更后热重载
    func reload() {
        let result = ConfigLoader.load()
        applyConfig(result)
        if case .ok = result { refreshAll() }
        notifyStateChange()
        NotificationCenter.default.post(name: Self.configDidChange, object: nil)
    }
}

// MARK: - CLI 测试模式（--once）

func runOnce() -> Int32 {
    switch ConfigLoader.load() {
    case .failed(let msg):
        FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
        return 1
    case .ok(let providers):
        let group = DispatchGroup()
        var exitCode: Int32 = 0
        for p in providers {
            if case .failed(let msg) = p.state {
                print("=== \(p.name) (error) ===")
                print("ERROR: \(msg)")
                continue
            }
            guard p.kind != nil else { continue }
            group.enter()
            URLSession.shared.dataTask(with: p.urlRequest()) { data, response, error in
                defer { group.leave() }
                print("=== \(p.name) (\(p.kind?.rawValue ?? "error")) → \(p.endpoint) ===")
                if let error { print("ERROR: \(error.localizedDescription)"); exitCode = 1; return }
                if let http = response as? HTTPURLResponse { print("HTTP \(http.statusCode)") }
                if let data {
                    if let snapshot = p.snapshot(from: data) {
                        let suffix = snapshot.displayStyle == .balance ? "" : "剩余"
                        print("菜单栏：\(p.icon) \(snapshot.menuText)（\(snapshot.primaryLabel)\(suffix)）")
                        for m in snapshot.metrics {
                            let reset = m.resetDate.map { " · " + F.resetCaption($0) } ?? ""
                            print("  \(m.label)：\(m.valueText)\(reset)")
                        }
                        for e in snapshot.extraLines { print("  \(e)") }
                    } else {
                        print("RAW: \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")")
                    }
                }
            }.resume()
        }
        group.wait()
        return exitCode
    }
}
