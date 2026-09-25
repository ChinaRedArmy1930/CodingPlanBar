import AppKit
import SwiftUI

// MARK: - App Delegate：菜单栏图标 + Popover 面板

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let store = AppStore()
    private let popover = NSPopover()
    private var appearanceObservation: NSKeyValueObservation?
    private var manageWindow: NSWindow?
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
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panelController

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
            popover.performClose(nil)
        } else {
            // 必须先激活应用：否则 transient popover 不追踪外部点击，点桌面/其他应用不会自动关闭
            NSApp.activate(ignoringOtherApps: true)
            popover.contentSize = NSSize(width: 350, height: 640)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }

    // MARK: 桌面管理窗口（CCSwitch 风格）

    private func showManageWindow(editProvider: String? = nil) {
        popover.performClose(nil)
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
                switch store.menuBarMode {
                case .ringPercent:
                    let ring = ringImage(remainingPct: s.remainingPct, size: 16)
                    let attachment = NSTextAttachment()
                    attachment.image = ring
                    attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                    text.append(NSAttributedString(attachment: attachment))
                    text.append(NSAttributedString(string: " \(s.menuText)", attributes: [
                        .font: TitleFont.loaded,
                        .foregroundColor: F.statusColor(remainingPct: s.remainingPct),
                    ]))
                case .ringOnly:
                    let ring = ringImage(remainingPct: s.remainingPct, size: 18)
                    let attachment = NSTextAttachment()
                    attachment.image = ring
                    attachment.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
                    text.append(NSAttributedString(attachment: attachment))
                case .percentOnly:
                    text.append(NSAttributedString(string: s.menuText, attributes: [
                    .font: TitleFont.loaded,
                    .foregroundColor: F.statusColor(remainingPct: s.remainingPct),
                    ]))
                }
                tooltipLines.append("\(p.name)：\(s.primaryLabel)剩余 \(s.menuText)")
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
