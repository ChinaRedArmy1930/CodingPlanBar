import SwiftUI

// MARK: - 主面板

struct PanelView: View {
    @ObservedObject var store: AppStore
    let onManage: () -> Void
    var onAddToken: (String) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 14) {
            header
            countdownBar
            if let error = store.configError {
                configErrorCard(error)
            } else if store.providers.count > 3 {
                ScrollView {
                    providerList
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 420)
            } else {
                providerList
            }
            footer
        }
        .padding(16)
        .frame(width: 350)
        .onAppear { store.refreshIfStale() }
    }

    private var providerList: some View {
        VStack(spacing: 12) {
            ForEach(store.providers) { provider in
                ProviderCard(
                    provider: provider,
                    histories: store.histories,
                    glmTrend: provider.kind == .glm ? store.glmTrends[provider.name] : nil,
                    onAddToken: onAddToken
                )
            }
        }
    }

    // MARK: 头部（标题 + 刷新 + 管理入口）

    private var header: some View {
        HStack(spacing: 8) {
            Text("Coding Plan")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            if let last = store.lastRefresh {
                Text(F.relativeShort(last))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            headerActions
        }
    }

    /// 刷新 + 设置：一个固定细边框的胶囊控制组
    private var headerActions: some View {
        HStack(spacing: 0) {
            headerButton(icon: "arrow.clockwise", help: "立即刷新 (⌘R)") {
                store.refreshAll(forceTrends: true)
            }
            .keyboardShortcut("r", modifiers: .command)

            Capsule()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 12)

            headerButton(icon: "gearshape", help: "打开管理窗口（渠道 / 颜色阈值）", action: onManage)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .cardStyle(in: Capsule())
    }

    private func headerButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: 循环倒计时进度条（走完自动刷新）

    private var countdownBar: some View {
        VStack(spacing: 3) {
            // TimelineView 按显示刷新率逐帧插值，倒计时丝滑递减
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                LinearBar(
                    fraction: store.countdownFraction(at: context.date),
                    color: Color(nsColor: .controlAccentColor),
                    height: 3
                )
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    Text("自动刷新倒计时")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(store.countdownText(at: context.date)) 后刷新")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func configErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("配置错误")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                Spacer()
                Button("去管理") { onManage() }
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        // 固定红色描边，错误态一眼可辨
        .cardStyle(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            fill: Color.red.opacity(0.06),
            stroke: Color.red.opacity(0.35)
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("自动刷新")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            RefreshIntervalPicker(selection: $store.refreshMinutes)
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 88)
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Provider 卡片

struct ProviderCard: View {
    let provider: ProviderRuntime
    let histories: [String: [HistoryPoint]]
    var glmTrend: GLMTrendBundle?
    var onAddToken: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch provider.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(provider.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text("加载中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(provider.name)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text(message.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if let buttonTitle = tokenButtonTitle(for: message) {
                        Button {
                            onAddToken(provider.name)
                        } label: {
                            Label(buttonTitle, systemImage: "key.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .loaded(let snapshot):
                cardHeader(snapshot)
                VStack(spacing: 10) {
                    ForEach(snapshot.metrics) { metric in
                        MetricRow(metric: metric)
                    }
                }
                if let trend = glmTrend {
                    GLMOfficialTrendSection(bundle: trend)
                }
                if let primary = snapshot.metrics.first {
                    TrendSection(
                        title: primary.label,
                        points: histories[AppStore.historyKey(provider: provider.name, metric: primary.label)] ?? [],
                        resetDate: primary.resetDate
                    )
                }
                if !snapshot.extraLines.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.extraLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private func cardHeader(_ snapshot: ProviderSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: ringImage(remainingPct: snapshot.remainingPct, size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))
                if let badge = snapshot.badge {
                    BadgeTag(text: badge, color: AnyShapeStyle(.tertiary))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(snapshot.menuText)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: F.statusColor(remainingPct: snapshot.remainingPct)))
                Text("\(snapshot.primaryLabel)剩余")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - 自绘进度条（规避 ProgressView + tint 在 Popover 首帧不渲染颜色的系统 bug）

struct LinearBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 自动刷新间隔选择（面板与管理窗口共用）

struct RefreshIntervalPicker: View {
    @Binding var selection: Int

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(AppStore.refreshIntervalOptions, id: \.self) { minutes in
                Text("\(minutes) 分钟").tag(minutes)
            }
        }
        .labelsHidden()
    }
}

// MARK: - 指标行

struct MetricRow: View {
    let metric: ProviderSnapshot.Metric

    private var statusColor: Color {
        Color(nsColor: F.statusColor(remainingPct: metric.remainingPct))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(metric.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                LinearBar(fraction: metric.remainingFraction, color: statusColor, height: 5)
                Text(metric.valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            if let reset = metric.resetDate {
                Text(F.resetCaption(reset))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 84)
            }
        }
    }
}

// MARK: - 7 天趋势 / 消耗速率

/// GLM 官方消耗趋势（`model-usage`）：口径为每小时消耗 tokens，与上方本地“剩余额度”趋势互补
private struct GLMOfficialTrendSection: View {
    let bundle: GLMTrendBundle
    @State private var weekly = false

    private var trend: GLMUsageTrend {
        if weekly, let week = bundle.week { return week.daily }
        return bundle.day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("消耗趋势 · 官方")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Picker("", selection: $weekly) {
                    Text("24h").tag(false)
                    Text("7天").tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 82)
                .labelsHidden()
                Spacer()
                Text("\(F.compactCount(trend.totalTokens)) tok · \(trend.totalCalls) 次")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TrendBars(values: trend.tokensPerHour)
                    .frame(height: 30)
            }
            HStack {
                let formatter = weekly && bundle.week != nil ? F.trendDay : F.trendAxis
                Text(formatter.string(from: trend.times.first ?? Date()))
                Spacer()
                Text(formatter.string(from: trend.times.last ?? Date()))
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.quaternary)
            if !trend.models.isEmpty {
                Text(
                    trend.models.prefix(3)
                        .map { "\($0.name) \(F.compactCount($0.tokens))" }
                        .joined(separator: " · ")
                )
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.top, 2)
    }
}

private struct TrendBars: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let maxValue = max(values.max() ?? 1, 1)
            let count = values.count
            let gap = min(2.0, size.width / CGFloat(count) * 0.25)
            let barWidth = max(1.0, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))

            for (index, value) in values.enumerated() {
                let height = CGFloat(value) / CGFloat(maxValue) * (size.height - 3)
                let x = CGFloat(index) * (barWidth + gap)
                let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                let path = SwiftUI.Path(roundedRect: rect, cornerRadius: min(1.5, barWidth / 2))
                context.fill(path, with: .color(Color.accentColor.opacity(value == maxValue ? 0.9 : 0.45)))
            }
        }
    }
}

private struct TrendSection: View {
    let title: String
    let points: [HistoryPoint]
    let resetDate: Date?

    private var samples: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return points.filter { $0.time >= cutoff }
    }

    /// 本地图为“已用百分比”口径：未使用 = 0 在底部，消耗后上升。
    /// 历史仍存储剩余值（兼容旧数据），渲染时翻转。
    private var usedSamples: [HistoryPoint] {
        samples.map { HistoryPoint(time: $0.time, pct: 100 - $0.pct) }
    }

    /// 实际数据跨度（不满 7 天时如实标注，避免“7 天”标题误导）
    private var spanText: String {
        guard let first = samples.first, let last = samples.last else { return "采样中" }
        let span = last.time.timeIntervalSince(first.time)
        if span < 90 { return "采样中" }
        if span < 3600 { return "\(Int(span / 60)) 分钟" }
        if span < 24 * 3600 { return "\(Int(span / 3600)) 小时" }
        return "7 天"
    }

    private var rangeText: String? {
        guard let minPct = samples.map(\.pct).min(), let maxPct = samples.map(\.pct).max() else { return nil }
        return "\(Int((100 - maxPct).rounded()))–\(Int((100 - minPct).rounded()))%"
    }

    private var insight: String {
        guard let latest = samples.last else { return "等待采样" }
        guard let rate = AppStore.burnRate(points: samples) else {
            return "消耗速率采样中 · 至少两次刷新后可用"
        }
        let eta = latest.pct / rate * 3600
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        let text = formatter.string(from: eta) ?? "\(Int(eta / 60)) 分钟"
        if let resetDate, Date().addingTimeInterval(eta) > resetDate {
            return String(format: "消耗 %.1f%%/小时 · 按当前速率，重置前不会耗尽", rate)
        }
        return String(format: "消耗 %.1f%%/小时 · 按当前速率约 %@ 后耗尽", rate, text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Text("已用趋势 · \(spanText)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    if let rangeText {
                        Text(rangeText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Spacer()
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            if samples.count >= 2 {
                Sparkline(points: usedSamples, color: Color(nsColor: F.statusColor(remainingPct: samples.last?.remainingInt)))
                    .frame(height: 30)
            } else {
                LinearBar(fraction: Double(100 - (samples.last?.pct ?? 100)) / 100, color: .secondary.opacity(0.5), height: 4)
                    .frame(height: 30)
            }
            Text(insight)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }
}

private extension HistoryPoint {
    var remainingInt: Int { Int(pct.rounded()) }
}

private struct Sparkline: View {
    let points: [HistoryPoint]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let times = points.map(\.time.timeIntervalSince1970)
            let minTime = times.min() ?? 0
            let maxTime = times.max() ?? 1
            let timeSpan = max(maxTime - minTime, 1)

            // y 轴自适应：波动 < 20% 时放大局部变化；否则保持 0–100 全量程
            let ys = points.map(\.pct)
            let dataMin = ys.min() ?? 0
            let dataMax = ys.max() ?? 100
            var yMin = 0.0
            var yMax = 100.0
            if dataMax - dataMin < 20 {
                let pad = max(2.0, (20 - (dataMax - dataMin)) / 2)
                yMin = max(0, dataMin - pad)
                yMax = min(100, dataMax + pad)
                if yMax - yMin < 4 {
                    yMin = max(0, dataMin - 2)
                    yMax = min(100, dataMax + 2)
                }
            }
            let ySpan = max(yMax - yMin, 1)

            func position(_ point: HistoryPoint) -> CGPoint {
                let x = (point.time.timeIntervalSince1970 - minTime) / timeSpan * size.width
                let clamped = min(max(point.pct, 0), 100)
                let y = size.height - ((clamped - yMin) / ySpan) * (size.height - 4) - 2
                return CGPoint(x: x, y: y)
            }

            var line = SwiftUI.Path()
            line.move(to: position(points[0]))
            points.dropFirst().forEach { line.addLine(to: position($0)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}

extension ProviderCard {
    /// Token 类错误 → 显示对应按钮；其他错误（网络等）不显示
    private func tokenButtonTitle(for message: String) -> String? {
        if message.contains("未配置 token") { return "添加 Token" }
        if message.contains("HTTP 401") || message.contains("HTTP 403") { return "检查 Token" }
        return nil
    }
}
