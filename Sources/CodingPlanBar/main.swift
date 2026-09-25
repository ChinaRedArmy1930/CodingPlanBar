import AppKit
import SwiftUI

// MARK: - App Delegate：菜单栏图标 + Popover 面板

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let store = AppStore()
    private let popover = NSPopover()
    private var appearanceObservation: NSKeyValueObservation?
    private var manageWindow: NSWindow?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    /// 面板宿主只建一次；PanelView 观察 store，数据更新自动重绘
    private lazy var panelController = NSHostingController(
        rootView: PanelView(
                store: store,
                onManage: { [weak self] in self?.showManageWindow() },
                onAddToken: { [weak self] name in self?.showManageWindow(editProvider: name) }
            )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Popover 面板（替代 NSMenu，不会被裁剪）
        // transient 在“常规应用 + 菜单栏 Popover”下会偶发不追踪外部点击；
        // 改为 applicationDefined，由事件监听统一负责关闭。
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = panelController
        popover.delegate = self

        // 菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = [.removalAllowed, .terminationOnRemoval]
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        store.onStateChange = { [weak self] in self?.renderTitle() }
        setupMainMenu()
        renderTitle()
        store.start()

        // 深浅色切换时重绘圆环
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderTitle() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
        } else {
            // 激活应用，保证面板内按钮、文本选择和键盘交互稳定
            NSApp.activate(ignoringOtherApps: true)
            popover.contentSize = NSSize(width: 350, height: 640)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
            installOutsideClickMonitors()
        }
    }

    // MARK: 外部点击关闭面板

    /// 自己接管关闭逻辑：点击桌面、其他应用或本应用其他窗口时立即关闭。
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.closePopover()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if self.isEventInsidePopover(event) || self.isEventOnStatusButton(event) {
                return event
            }
            self.closePopover()
            return event
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown, event.keyCode == 53 else { return event }
            self.closePopover()
            return nil
        }
    }

    private func removeOutsideClickMonitors() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    private func closePopover() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = panelController.view.window else { return false }
        return event.window === popoverWindow
    }

    /// 状态栏按钮点击交给原有 action 处理，避免监听器先关闭、action 再打开。
    private func isEventOnStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              event.window === button.window else { return false }
        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitors()
    }

    // MARK: 桌面管理窗口（CCSwitch 风格）

    private func showManageWindow(editProvider: String? = nil) {
        closePopover()
        if editProvider != nil, manageWindow != nil {
            // 需要直达指定渠道编辑时，重建窗口内容
            manageWindow?.close()
        }
        if manageWindow == nil {
            let vc = NSHostingController(rootView: ManageView(store: store, initialEditName: editProvider))
            let window = NSWindow(contentViewController: vc)
            window.title = "Coding Plan · 渠道管理"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 440, height: 600))
            window.center()
            window.delegate = self
            manageWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        manageWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        manageWindow = nil
    }

    /// 点击 Dock 图标：没有窗口时重新打开管理窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if manageWindow == nil {
            showManageWindow()
        }
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        // 兜底：即使全局鼠标监听没有收到事件，切到其他应用时也关闭面板。
        closePopover()
    }

    /// 标准应用菜单栏（关于 / 退出 / 窗口）
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Coding Plan Bar")
        appMenu.addItem(NSMenuItem(title: "关于 Coding Plan Bar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "管理渠道", action: #selector(openManageFromMenu(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openManageFromMenu(_ sender: Any?) {
        showManageWindow()
    }

    // MARK: 菜单栏标题

    /// 标题字体常量（每次重绘复用，避免重复创建 NSFont）
    private enum TitleFont {
        static let error = NSFont.systemFont(ofSize: 13, weight: .medium)
        static let plain = NSFont.systemFont(ofSize: 12)
        static let failed = NSFont.systemFont(ofSize: 12, weight: .medium)
        static let loaded = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }

    private func renderTitle() {
        guard let button = statusItem?.button else { return }

        if let configError = store.configError {
            button.attributedTitle = NSAttributedString(string: "⚠️", attributes: [
                .font: TitleFont.error,
                .foregroundColor: NSColor.systemRed,
            ])
            button.toolTip = "配置错误：\(configError)"
            return
        }

        let text = NSMutableAttributedString()
        var tooltipLines: [String] = []
        for (i, p) in store.providers.enumerated() {
            if i > 0 {
                text.append(NSAttributedString(string: "   ", attributes: [
                    .font: TitleFont.plain,
                ]))
            }
            switch p.state {
            case .loading:
                text.append(NSAttributedString(string: "\(p.icon) …", attributes: [
                    .font: TitleFont.plain,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                tooltipLines.append("\(p.name)：加载中…")
            case .failed:
                text.append(NSAttributedString(string: "\(p.icon) !", attributes: [
                    .font: TitleFont.failed,
                    .foregroundColor: NSColor.systemRed,
                ]))
                tooltipLines.append("\(p.name)：加载失败，点击查看详情")
            case .loaded(let s):
                if s.displayStyle == .balance {
                    // API 余额没有百分比圆环，菜单栏直接显示图标 + 金额
                    let amount = store.menuBarMode == .ringOnly ? p.icon : "\(p.icon) \(s.menuText)"
                    text.append(NSAttributedString(string: amount, attributes: [
                        .font: TitleFont.loaded,
                        .foregroundColor: F.statusColor(remainingPct: s.remainingPct),
                    ]))
                    let extras = s.extraLines.isEmpty ? "" : " · " + s.extraLines.joined(separator: " · ")
                    tooltipLines.append("\(p.name)：\(s.primaryLabel) \(s.menuText)\(extras)")
                } else {
                    switch store.menuBarMode {
                    case .ringPercent:
                        let ring = ringImage(remainingPct: s.remainingPct, innerPct: s.innerPct, size: 16)
                        let attachment = NSTextAttachment()
                        attachment.image = ring
                        attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                        text.append(NSAttributedString(attachment: attachment))
                        text.append(NSAttributedString(string: " \(s.menuText)", attributes: [
                            .font: TitleFont.loaded,
                            .foregroundColor: F.statusColor(remainingPct: s.remainingPct),
                        ]))
                    case .ringOnly:
                        let ring = ringImage(remainingPct: s.remainingPct, innerPct: s.innerPct, size: 18)
                        let attachment = NSTextAttachment()
                        attachment.image = ring
                        attachment.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
                        text.append(NSAttributedString(attachment: attachment))
                    case .percentOnly:
                        text.append(NSAttributedString(string: s.menuText, attributes: [
                        .font: TitleFont.loaded,
                        .foregroundColor: F.statusColor(remainingPct: s.remainingPct),
                        ]))
                        if let innerPct = s.innerPct {
                            text.append(NSAttributedString(string: "·", attributes: [
                                .font: TitleFont.plain,
                                .foregroundColor: NSColor.tertiaryLabelColor,
                            ]))
                            text.append(NSAttributedString(string: "\(innerPct)%", attributes: [
                                .font: TitleFont.loaded,
                                .foregroundColor: F.statusColor(remainingPct: innerPct),
                            ]))
                        }
                    }
                    let inner = s.innerSummary.map { " · \($0)" } ?? ""
                    tooltipLines.append("\(p.name)：\(s.primaryLabel)剩余 \(s.menuText)\(inner)")
                }
            }
        }
        button.attributedTitle = text
        button.toolTip = tooltipLines.joined(separator: "\n")
    }
}

// MARK: - CLI 测试模式（--once）

if CommandLine.arguments.contains("--once") {
    exit(runOnce())
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular) // 常规应用：Dock 常驻；菜单栏图标照常显示
app.run()
