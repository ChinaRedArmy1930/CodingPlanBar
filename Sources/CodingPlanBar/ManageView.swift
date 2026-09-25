import SwiftUI
import Combine

// MARK: - 渠道管理窗口

struct ManageView: View {
    @ObservedObject var store: AppStore
    var initialEditName: String? = nil

    @State private var drafts: [ProviderDraft] = []
    @State private var greenThreshold: Int = 50
    @State private var yellowThreshold: Int = 20
    @State private var form: (draft: ProviderDraft, isNew: Bool)?
    @State private var pendingDelete: ProviderDraft?
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Group {
            if let form {
                ProviderForm(draft: form.draft, isNew: form.isNew) { updated in
                    if form.isNew {
                        drafts.append(updated)
                    } else if let i = drafts.firstIndex(where: { $0.id == updated.id }) {
                        drafts[i] = updated
                    }
                    self.form = nil
                    commit(refreshData: true)
                } onCancel: {
                    self.form = nil
                }
                .id(form.draft.id)
            } else {
                mainContent
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: AppStore.configDidChange)) { _ in
            load()
        }
        .confirmationDialog(
            "删除渠道「\(pendingDelete?.name ?? "")」？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let d = pendingDelete {
                    drafts.removeAll { $0.id == d.id }
                    commit(refreshData: true)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func load() {
        drafts = store.loadDrafts()
        let t = store.currentThresholds
        greenThreshold = t.green
        yellowThreshold = t.yellow
        // 从"添加 Token"按钮进入时，直接打开对应渠道的编辑表单
        if let name = initialEditName {
            if let d = drafts.first(where: { $0.name == name }) {
                form = (draft: d, isNew: false)
            }
        }
    }

    // MARK: 主内容

    private var mainContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    providerSection
                    settingsSection
                }
                .padding(24)
            }
            bottomBar
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 560, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("渠道管理")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("渠道与显示设置保存在本地 SQLite；外部修改数据库后程序会自动同步")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: 渠道列表

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("渠道", count: drafts.count)
            VStack(spacing: 8) {
                if drafts.isEmpty {
                    emptyState
                }
                ForEach(drafts) { draft in
                    ProviderRow(
                        draft: draft,
                        onEdit: { form = (draft, false) },
                        onDelete: { pendingDelete = draft }
                    )
                }
                addButton
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let count {
                BadgeTag(text: "\(count)", font: .system(size: 9, weight: .bold, design: .rounded))
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: "tray")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            Text("还没有渠道")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("添加 Kimi 或 GLM 开始监控余额")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .cardBackground(cornerRadius: 12)
    }

    private var addButton: some View {
        Button {
            form = (ProviderDraft(name: "", type: "kimi", existingToken: ""), true)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("添加渠道")
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        Color(nsColor: .controlAccentColor).opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: .controlAccentColor))
    }

    // MARK: 设置（颜色阈值 + 刷新间隔）

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("设置")
            VStack(alignment: .leading, spacing: 18) {
                // 颜色阈值：可拖动滑块
                VStack(alignment: .leading, spacing: 6) {
                    Text("剩余额度颜色")
                        .font(.system(size: 12, weight: .medium))
                    ThresholdSlider(green: $greenThreshold, yellow: $yellowThreshold) {
                        commit(refreshData: false)
                    }
                }

                Divider()

                // 自动刷新间隔
                HStack(alignment: .center) {
                    settingLabel("自动刷新", icon: "clock.arrow.circlepath")
                    RefreshIntervalPicker(selection: $store.refreshMinutes)
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                }

                Divider()

                HStack(alignment: .center) {
                    settingLabel("菜单栏显示", icon: "menubar.rectangle")
                    Spacer()
                    Picker("", selection: menuBarModeBinding) {
                        ForEach(MenuBarMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                HStack(alignment: .center) {
                    settingLabel("低额度通知", icon: "bell.badge")
                    Spacer()
                    Toggle("", isOn: notificationsBinding)
                        .labelsHidden()
                        .controlSize(.small)
                }

                HStack(alignment: .center) {
                    settingLabel("开机启动", icon: "power")
                    Spacer()
                    Toggle("", isOn: launchAtLoginBinding)
                        .labelsHidden()
                        .controlSize(.small)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        settingLabel("本地存储", icon: "internaldrive")
                        Spacer()
                        BadgeTag(text: "SQLite", color: AnyShapeStyle(Color(nsColor: .controlAccentColor)))
                    }
                    Text(ConfigLoader.databaseFile.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("配置与鉴权分表存储 · credentials 独立保存 · 文件权限 600")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
            .cardBackground()
        }
    }

    // MARK: 底部状态栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let statusMessage {
                Label(
                    statusMessage,
                    systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.system(size: 10))
                .foregroundStyle(statusIsError ? .red : .green)
                .lineLimit(1)
                .transition(.opacity)
            } else {
                Text("所有修改即时保存 · SQLite 外部修改自动同步")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(drafts.count) 个渠道")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .barFooter()
        .animation(.easeInOut(duration: 0.15), value: statusMessage)
    }

    private var menuBarModeBinding: Binding<MenuBarMode> {
        Binding(
            get: { store.menuBarMode },
            set: { store.setMenuBarMode($0) }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { store.notificationsEnabled },
            set: { store.setNotificationsEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { enabled in
                do {
                    try store.setLaunchAtLogin(enabled)
                    showStatus(enabled ? "已加入登录项 ✓" : "已移出登录项 ✓")
                } catch {
                    showStatus("登录项设置失败：\(error.localizedDescription)", error: true)
                }
            }
        )
    }

    private func settingLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: 即时保存

    private func commit(refreshData: Bool) {
        let names = drafts.map { $0.name.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: { $0.isEmpty }) {
            showStatus("渠道名称不能为空", error: true)
            return
        }
        if Set(names).count != names.count {
            showStatus("渠道名称不能重复", error: true)
            return
        }
        if yellowThreshold >= greenThreshold {
            showStatus("黄色阈值需小于绿色阈值", error: true)
            return
        }
        do {
            try store.saveConfig(
                drafts: drafts,
                green: greenThreshold,
                yellow: yellowThreshold,
                refreshData: refreshData
            )
            showStatus(refreshData ? "已保存并刷新 ✓" : "已保存 ✓")
        } catch {
            showStatus("保存失败：\(error.localizedDescription)", error: true)
        }
    }

    private func showStatus(_ message: String, error: Bool = false) {
        withAnimation {
            statusMessage = message
            statusIsError = error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                if statusMessage == message {
                    statusMessage = nil
                    statusIsError = false
                }
            }
        }
    }
}

// MARK: - 渠道行

private struct ProviderRow: View {
    let draft: ProviderDraft
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    /// 实际调用的域名（与运行时同一套 endpoint 解析）
    private var hostLabel: String {
        if let url = draft.resolvedEndpoint { return url.host ?? url.absoluteString }
        return draft.type == "custom" ? draft.endpoint : draft.baseURL
    }

    var body: some View {
        HStack(spacing: 12) {
            TypeIcon(kind: draft.kind ?? .kimi, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.name)
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(draft.type == "glm" ? Color.teal : Color.indigo)
                        .frame(width: 5, height: 5)
                    Text("\(draft.kind?.shortName ?? draft.type) · \(hostLabel)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            rowButton(icon: "pencil", help: "编辑") { onEdit() }
            rowButton(icon: "trash", help: "删除", color: .red) { onDelete() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardStyle(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            fill: Color.primary.opacity(hovered ? 0.07 : 0.035),
            stroke: hovered ? Color(nsColor: .controlAccentColor).opacity(0.55) : Color(nsColor: .separatorColor)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { hovered = hovering }
        }
    }

    private func rowButton(icon: String, help: String, color: Color = Color(nsColor: .secondaryLabelColor), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .help(help)
    }
}

// MARK: - 渠道类型图标

struct TypeIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 36

    private var gradient: [Color] {
        switch kind {
        case .glm:
            return [Color(red: 0.05, green: 0.65, blue: 0.62), Color(red: 0.12, green: 0.82, blue: 0.72)]
        case .deepseek:
            return [Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.35, green: 0.62, blue: 1.0)]
        case .custom:
            return [Color(red: 0.42, green: 0.45, blue: 0.52), Color(red: 0.55, green: 0.58, blue: 0.66)]
        case .kimi:
            return [Color(red: 0.30, green: 0.35, blue: 0.90), Color(red: 0.55, green: 0.35, blue: 0.95)]
        }
    }

    private var symbol: String {
        switch kind {
        case .glm: return "sparkles"
        case .deepseek: return "water.waves"
        case .custom: return "circle.hexagongrid"
        case .kimi: return "bolt.fill"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(
                    LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .shadow(color: gradient.last?.opacity(0.35) ?? .clear, radius: 3, y: 2)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 阈值拖动滑块

struct ThresholdSlider: View {
    @Binding var green: Int
    @Binding var yellow: Int
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    // 三段色带（带细描边，颜色更收敛）
                    HStack(spacing: 0) {
                        Rectangle().fill(.red.opacity(0.85))
                            .frame(width: width * CGFloat(yellow) / 100)
                        Rectangle().fill(.yellow.opacity(0.85))
                            .frame(width: width * CGFloat(green - yellow) / 100)
                        Rectangle().fill(.green.opacity(0.85))
                    }
                    .frame(width: width, height: 10)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                    .offset(y: 28)

                    // 手柄（气泡 + 圆点）：夹取逻辑收敛在 handle 内，调用方只给绑定与范围
                    let yellowRange = 1...max(1, green - 1)
                    handle(value: $yellow, color: .yellow, width: width, range: yellowRange, onCommit: onCommit)
                        .position(x: width * CGFloat(yellow) / 100, y: 14)

                    let greenRange = yellow + 1...99
                    handle(value: $green, color: .green, width: width, range: greenRange, onCommit: onCommit)
                        .position(x: width * CGFloat(green) / 100, y: 14)
                }
            }
            .frame(height: 56)

            Text("拖动调整：剩余 <\(yellow)% 红色，\(yellow)–\(green)% 黄色，>\(green)% 绿色")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func handle(value: Binding<Int>, color: Color, width: CGFloat, range: ClosedRange<Int>, onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Text("\(value.wrappedValue)%")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(color.opacity(0.18))
                        .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 0.5))
                )
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2.5).shadow(color: .black.opacity(0.15), radius: 1, y: 1))
                .shadow(color: color.opacity(0.4), radius: 2, y: 1)
        }
        .contentShape(Rectangle().inset(by: -8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let deltaPct = Int((g.translation.width / width * 100).rounded())
                    if deltaPct != 0 {
                        value.wrappedValue = min(max(value.wrappedValue + deltaPct, range.lowerBound), range.upperBound)
                    }
                }
                .onEnded { _ in onCommit() }
        )
    }
}

// MARK: - 添加 / 编辑表单

struct ProviderForm: View {
    @State var draft: ProviderDraft
    let isNew: Bool
    let onSave: (ProviderDraft) -> Void
    let onCancel: () -> Void

    @State private var validationError: String?

    private var typeDisplayName: String {
        draft.kind?.displayName ?? draft.type
    }

    private func pathField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
    }

    /// 实际（或将要）请求的 endpoint 预览（与运行时共用同一套解析逻辑）
    private var endpointPreview: String {
        if draft.type == "custom" { return draft.endpoint.isEmpty ? "（待填写接口地址）" : draft.endpoint }
        return ConfigLoader.resolveEndpoint(
            type: draft.type, baseURL: draft.baseURL.isEmpty ? nil : draft.baseURL, endpoint: nil
        )?.absoluteString ?? "（无效的 Base URL）"
    }

    /// Authorization 头预览（与 urlRequest 同一套认证解析）
    private var authPreview: String {
        let style = draft.kind?.authStyle(from: draft.authStyle) ?? draft.authStyle
        return authHeaderValue(authStyle: style, token: maskedToken) ?? "（无认证）"
    }

    /// Token 脱敏显示
    private var maskedToken: String {
        let t = draft.effectiveToken
        guard !t.isEmpty else { return "未设置（读取环境变量）" }
        if t.count <= 10 { return String(t.prefix(4)) + "••••" }
        return String(t.prefix(7)) + "••••" + String(t.suffix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    formHeader

                    VStack(alignment: .leading, spacing: 18) {
                        fieldRow(icon: "person.crop.circle", title: "名称") {
                            TextField("如 Kimi / GLM", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        fieldRow(icon: "sparkles", title: "图标") {
                            TextField("可选：⚡ / ✦ / ◈", text: $draft.icon)
                                .textFieldStyle(.roundedBorder)
                        }

                        fieldRow(icon: "network", title: "类型") {
                            if isNew {
                                Picker("", selection: $draft.type) {
                                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                                        Text(kind.shortName).tag(kind.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 300)
                            } else {
                                HStack(spacing: 8) {
                                    TypeIcon(kind: draft.kind ?? .kimi, size: 22)
                                    Text(typeDisplayName)
                                        .font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text("创建后不可更改")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        if draft.type == "custom" {
                            // 自定义渠道：接口地址 + 认证方式 + 解析路径
                            fieldRow(icon: "arrow.right.circle", title: "接口地址") {
                                TextField("https://api.example.com/v1/usage", text: $draft.endpoint)
                                    .textFieldStyle(.roundedBorder)
                            }
                            fieldRow(icon: "lock.circle", title: "认证方式") {
                                Picker("", selection: $draft.authStyle) {
                                    Text("Bearer").tag("bearer")
                                    Text("Token 原样").tag("raw")
                                    Text("无").tag("none")
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 240)
                            }
                            fieldRow(icon: "curlybraces.square", title: "主指标路径") {
                                pathField("剩余百分比，如 data.usage.remaining", text: $draft.mainPath)
                            }
                            fieldRow(icon: "number.square", title: "剩余量") {
                                pathField("适合金额，如 data.0.total_available", text: $draft.mainRemainingPath)
                            }
                            fieldRow(icon: "divide.circle", title: "总量") {
                                pathField("如 data.0.total_granted", text: $draft.mainTotalPath)
                            }
                            fieldRow(icon: "clock.arrow.circlepath", title: "重置路径") {
                                pathField("可选：时间戳或 ISO 时间", text: $draft.mainResetPath)
                            }
                            fieldRow(icon: "curlybraces.square", title: "5h 路径") {
                                pathField("可选：5h 窗口剩余百分比", text: $draft.extraPath)
                            }
                            fieldRow(icon: "number.square", title: "5h 剩余") {
                                pathField("可选：5h 窗口剩余量", text: $draft.extraRemainingPath)
                            }
                            fieldRow(icon: "divide.circle", title: "5h 总量") {
                                pathField("可选：5h 窗口总量", text: $draft.extraTotalPath)
                            }
                            fieldRow(icon: "clock.arrow.circlepath", title: "5h 重置") {
                                pathField("可选：时间戳或 ISO 时间", text: $draft.extraResetPath)
                            }
                            Text("百分比路径与“剩余量 + 总量”二选一；后者适合 OpenAI credits 这类金额型接口。")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 84)
                        }

                        fieldRow(icon: "key.fill", title: "Token") {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField(
                                    isNew ? "必填" : "留空保持不变",
                                    text: $draft.token
                                )
                                .textFieldStyle(.roundedBorder)
                                Text("当前：\(maskedToken)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if draft.type != "custom" {
                            fieldRow(icon: "globe", title: "Base URL") {
                                TextField(
                                    "默认 \(draft.kind?.defaultBaseURL ?? ProviderKind.kimi.defaultBaseURL)（可选）",
                                    text: $draft.baseURL
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                        }

                        if draft.type == "deepseek" {
                            Text("DeepSeek 读的是开放平台 API 余额（/user/balance），不是 Coding Plan 百分比额度。")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 84)
                        }

                        // 实际调用预览
                        fieldRow(icon: "arrow.right.circle", title: "调用") {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("GET " + endpointPreview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Text("Authorization: " + authPreview)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(18)
                    .cardBackground()

                    if let validationError {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
            }
            formBottomBar
        }
        .frame(minWidth: 440, idealWidth: 480, maxWidth: 640, minHeight: 500, maxHeight: .infinity)
    }

    private var formHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                TypeIcon(kind: draft.kind ?? .kimi, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? "添加渠道" : "编辑渠道")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(isNew ? "接入一个新的套餐或 API 渠道" : draft.name.isEmpty ? "配置渠道信息" : draft.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var formBottomBar: some View {
        HStack {
            Button("取消", action: onCancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isNew ? "添加" : "保存") { validateAndSave() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .barFooter()
    }

    private func fieldRow<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func validateAndSave() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            validationError = "名称不能为空"
            return
        }
        guard draft.kind != nil else {
            validationError = "类型无效"
            return
        }
        if draft.type == "custom" {
            guard ConfigLoader.resolveEndpoint(type: "custom", baseURL: nil, endpoint: draft.endpoint) != nil else {
                validationError = "自定义渠道需要有效的接口地址"
                return
            }
            let hasMainPath = !draft.mainPath.isEmpty
            let mainRatioFields = !draft.mainRemainingPath.isEmpty || !draft.mainTotalPath.isEmpty
            let hasMainRatio = !draft.mainRemainingPath.isEmpty && !draft.mainTotalPath.isEmpty
            if mainRatioFields && !hasMainRatio {
                validationError = "主指标数值模式需要同时填写剩余量和总量路径"
                return
            }
            guard hasMainPath || hasMainRatio else {
                validationError = "自定义渠道需要主指标百分比路径，或“剩余量 + 总量”路径"
                return
            }
            let extraRatioFields = !draft.extraRemainingPath.isEmpty || !draft.extraTotalPath.isEmpty
            let hasExtraRatio = !draft.extraRemainingPath.isEmpty && !draft.extraTotalPath.isEmpty
            if extraRatioFields && !hasExtraRatio {
                validationError = "5h 数值模式需要同时填写剩余量和总量路径"
                return
            }
        }
        if isNew,
           draft.token.trimmingCharacters(in: .whitespaces).isEmpty,
           !(draft.type == "custom" && draft.authStyle == "none") {
            validationError = "Token 不能为空"
            return
        }
        draft.name = name
        draft.icon = draft.icon.trimmingCharacters(in: .whitespaces)
        draft.token = draft.token.trimmingCharacters(in: .whitespaces)
        draft.baseURL = draft.baseURL.trimmingCharacters(in: .whitespaces)
        draft.endpoint = draft.endpoint.trimmingCharacters(in: .whitespaces)
        draft.mainPath = draft.mainPath.trimmingCharacters(in: .whitespaces)
        draft.mainRemainingPath = draft.mainRemainingPath.trimmingCharacters(in: .whitespaces)
        draft.mainTotalPath = draft.mainTotalPath.trimmingCharacters(in: .whitespaces)
        draft.mainResetPath = draft.mainResetPath.trimmingCharacters(in: .whitespaces)
        draft.extraPath = draft.extraPath.trimmingCharacters(in: .whitespaces)
        draft.extraRemainingPath = draft.extraRemainingPath.trimmingCharacters(in: .whitespaces)
        draft.extraTotalPath = draft.extraTotalPath.trimmingCharacters(in: .whitespaces)
        draft.extraResetPath = draft.extraResetPath.trimmingCharacters(in: .whitespaces)
        onSave(draft)
    }
}

// MARK: - 统一卡片样式（固定细边框）

/// 结构来自常显 1px 描边而非阴影；极浅填充保证浅/深色模式都可读
extension View {
    /// 通用变体：形状 / 填充 / 描边可定制（错误卡片、胶囊控制组、悬停行共用）
    func cardStyle<S: InsettableShape>(in shape: S, fill: Color = Color.primary.opacity(0.035), stroke: Color = Color(nsColor: .separatorColor)) -> some View {
        self.background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
    }

    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        cardStyle(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 底部工具条（管理窗口两处共用）

extension View {
    func barFooter() -> some View {
        self.padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - 小胶囊徽标（分区计数 / 卡片徽标共用）

struct BadgeTag: View {
    let text: String
    var font: Font = .system(size: 9)
    var color: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4)))
    }
}
