import XCTest
@testable import CodingPlanBar

final class CodingPlanBarTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coding-plan-bar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        setenv("CODING_PLAN_BAR_CONFIG", "/dev/null", 1)
        setenv("CODING_PLAN_BAR_DB", "/dev/null", 1)
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func jsonData(_ value: String) -> Data {
        Data(value.utf8)
    }

    func testKimiSnapshotParsesWeeklyFiveHourAndBooster() throws {
        let data = jsonData("""
        {
          "usage": {
            "limit": "100",
            "used": "48",
            "resetTime": "2026-09-30T15:59:00Z"
          },
          "usages": {
            "limit_5h": {
              "used_ratio": 0.18,
              "reset_time": "2026-09-25T22:59:00Z"
            },
            "limit_7d": {
              "used_ratio": 0.48,
              "reset_time": "2026-09-30T15:59:00Z"
            }
          },
          "booster_wallet": {
            "monthlyChargeLimit": {
              "currency": "CNY",
              "priceInCents": "10000"
            },
            "monthlyUsed": {
              "currency": "CNY",
              "priceInCents": "0"
            }
          }
        }
        """)

        let snapshot = try XCTUnwrap(SnapshotBuilder.kimi(from: data))
        XCTAssertEqual(snapshot.remainingPct, 52)
        XCTAssertEqual(snapshot.menuText, "52%")
        XCTAssertEqual(snapshot.metrics.map(\.label), ["周额度剩余", "5h 窗口剩余"])
        XCTAssertEqual(snapshot.metrics.map(\.remainingPct), [52, 82])
        XCTAssertEqual(snapshot.extraLines, ["加油包未检测到使用 · 本月可购 ¥100"])
        if case .quota = snapshot.displayStyle {} else {
            XCTFail("Expected Kimi to use quota display style")
        }
    }

    func testGLMSnapshotParsesWeeklyFiveHourAndMCP() throws {
        let data = jsonData("""
        {
          "code": 200,
          "data": {
            "level": "pro",
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "percentage": 23,
                "next_reset_time": 1798768800000
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "percentage": 16,
                "next_reset_time": 1793881200000
              },
              {
                "type": "TIME_LIMIT",
                "unit": 1,
                "usage": 1000,
                "current_value": 280,
                "remaining": 720,
                "next_reset_time": 1793274000000,
                "usageDetails": [
                  {"modelCode": "search-prime", "usage": 228},
                  {"modelCode": "web-reader", "usage": 52},
                  {"modelCode": "unused", "usage": 0}
                ]
              }
            ]
          }
        }
        """)

        let snapshot = try XCTUnwrap(SnapshotBuilder.glm(from: data))
        XCTAssertEqual(snapshot.remainingPct, 77)
        XCTAssertEqual(snapshot.badge, "Coding Plan · Pro")
        XCTAssertEqual(snapshot.metrics.map(\.label), ["周额度剩余", "5h 窗口剩余", "MCP 月度剩余"])
        XCTAssertEqual(snapshot.metrics.map(\.remainingPct), [77, 84, 72])
        XCTAssertEqual(snapshot.metrics.last?.valueText, "720/1000")
        XCTAssertEqual(snapshot.extraLines, ["search-prime 228 · web-reader 52"])
    }

    func testDeepSeekSnapshotUsesBalanceDisplayStyle() throws {
        let data = jsonData("""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": "5.50",
              "granted_balance": "0.00",
              "topped_up_balance": "5.50"
            },
            {
              "currency": "CNY",
              "total_balance": "47.47",
              "granted_balance": "0.00",
              "topped_up_balance": "47.47"
            }
          ]
        }
        """)

        let snapshot = try XCTUnwrap(SnapshotBuilder.deepseek(from: data))
        XCTAssertEqual(snapshot.menuText, "¥47.47")
        XCTAssertEqual(snapshot.primaryLabel, "API 余额")
        XCTAssertEqual(snapshot.badge, "DeepSeek API")
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertNil(snapshot.remainingPct)
        XCTAssertEqual(snapshot.extraLines, ["充值 ¥47.47", "USD 余额 $5.50"])
        if case .balance = snapshot.displayStyle {} else {
            XCTFail("Expected DeepSeek to use balance display style")
        }
    }

    func testCustomParserSupportsUsedPercentageAndRatioMetrics() throws {
        let parser = CustomParser(metrics: [
            .init(
                label: "余额剩余",
                path: "data.used_percent",
                used: true,
                resetPath: nil,
                remainingPath: nil,
                totalPath: nil
            ),
            .init(
                label: "5h 窗口剩余",
                path: nil,
                used: nil,
                resetPath: nil,
                remainingPath: "windows.5h.remaining",
                totalPath: "windows.5h.total"
            ),
        ])
        let data = jsonData("""
        {
          "data": {"used_percent": 35},
          "windows": {
            "5h": {"remaining": 24, "total": 80}
          }
        }
        """)

        let snapshot = try XCTUnwrap(SnapshotBuilder.custom(parser: parser, data: data))
        XCTAssertEqual(snapshot.remainingPct, 65)
        XCTAssertEqual(snapshot.metrics.map(\.remainingPct), [65, 30])
        XCTAssertEqual(snapshot.metrics.last?.valueText, "30%")
    }

    func testSQLiteMigratesLegacyJSONAndRemovesPlainTextToken() throws {
        let legacyURL = temporaryDirectory.appendingPathComponent("legacy-config.json")
        let databaseURL = temporaryDirectory.appendingPathComponent("config.sqlite")
        try """
        {
          "menu_bar_mode": "ring_only",
          "notifications_enabled": false,
          "reset_notifications_enabled": true,
          "thresholds": {"green": 65, "yellow": 25},
          "providers": [
            {
              "name": "Kimi",
              "type": "kimi",
              "token": "local-kimi-token"
            }
          ]
        }
        """.write(to: legacyURL, atomically: true, encoding: .utf8)
        setenv("CODING_PLAN_BAR_CONFIG", legacyURL.path, 1)
        setenv("CODING_PLAN_BAR_DB", databaseURL.path, 1)

        let migrated = try ConfigDatabase.loadConfig()
        XCTAssertEqual(migrated.providers?.map(\.name), ["Kimi"])
        XCTAssertEqual(migrated.providers?.first?.token, "local-kimi-token")
        XCTAssertEqual(migrated.menuBarMode, "ring_only")
        XCTAssertEqual(migrated.notificationsEnabled, false)
        XCTAssertEqual(migrated.resetNotificationsEnabled, true)
        XCTAssertEqual(migrated.thresholds?.green, 65)
        XCTAssertEqual(migrated.thresholds?.yellow, 25)

        let markerData = try Data(contentsOf: legacyURL)
        let marker = try XCTUnwrap(try JSONSerialization.jsonObject(with: markerData) as? [String: Any])
        XCTAssertEqual(marker["storage"] as? String, "sqlite")
        XCTAssertNil(marker["providers"])
        XCTAssertFalse(String(data: markerData, encoding: .utf8)!.contains("local-kimi-token"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? Int, 0o600)
    }

    func testSQLiteConfigurationRoundTrip() throws {
        let legacyURL = temporaryDirectory.appendingPathComponent("missing-config.json")
        let databaseURL = temporaryDirectory.appendingPathComponent("roundtrip.sqlite")
        setenv("CODING_PLAN_BAR_CONFIG", legacyURL.path, 1)
        setenv("CODING_PLAN_BAR_DB", databaseURL.path, 1)

        let initial = try ConfigDatabase.loadConfig()
        XCTAssertTrue((initial.providers ?? []).isEmpty)

        let parser = CustomParser(metrics: [
            .init(
                label: "余额剩余",
                path: nil,
                used: nil,
                resetPath: "data.reset_at",
                remainingPath: "data.remaining",
                totalPath: "data.total"
            )
        ])
        let configuration = FileConfig(
            providers: [
                ProviderConfig(
                    name: "DeepSeek",
                    type: "deepseek",
                    token: "local-deepseek-token",
                    icon: "🐳",
                    baseURL: nil,
                    endpoint: nil,
                    authStyle: nil,
                    parser: nil
                ),
                ProviderConfig(
                    name: "Custom",
                    type: "custom",
                    token: "local-custom-token",
                    icon: nil,
                    baseURL: nil,
                    endpoint: "https://api.example.test/usage",
                    authStyle: "raw",
                    parser: parser
                ),
            ],
            thresholds: .init(green: 60, yellow: 25),
            token: nil,
            baseURL: nil,
            endpoint: nil,
            menuBarMode: "percent_only",
            notificationsEnabled: true,
            resetNotificationsEnabled: false,
            launchAtLogin: false
        )
        try ConfigDatabase.saveConfig(configuration)

        let loaded = try ConfigDatabase.loadConfig()
        XCTAssertEqual(loaded.providers?.map(\.name), ["DeepSeek", "Custom"])
        XCTAssertEqual(loaded.providers?.first?.token, "local-deepseek-token")
        XCTAssertEqual(loaded.providers?.last?.authStyle, "raw")
        XCTAssertEqual(
            loaded.providers?.last?.parser?.metrics?.first?.remainingPath,
            "data.remaining"
        )
        XCTAssertEqual(loaded.menuBarMode, "percent_only")
        XCTAssertEqual(loaded.resetNotificationsEnabled, false)
        XCTAssertEqual(loaded.thresholds?.green, 60)
        XCTAssertEqual(loaded.thresholds?.yellow, 25)
    }

    func testResetNotificationWindowAndDedupe() {
        let now = Date()
        let resetDate = now.addingTimeInterval(14 * 60)
        let leadTime: TimeInterval = 15 * 60

        XCTAssertFalse(AppStore.shouldSendResetNotification(
            remaining: 16 * 60,
            lastNotifiedReset: nil,
            resetDate: resetDate,
            leadTime: leadTime
        ))
        XCTAssertTrue(AppStore.shouldSendResetNotification(
            remaining: 14 * 60,
            lastNotifiedReset: nil,
            resetDate: resetDate,
            leadTime: leadTime
        ))
        XCTAssertFalse(AppStore.shouldSendResetNotification(
            remaining: 10 * 60,
            lastNotifiedReset: resetDate,
            resetDate: resetDate,
            leadTime: leadTime
        ))
        XCTAssertTrue(AppStore.shouldSendResetNotification(
            remaining: 10 * 60,
            lastNotifiedReset: resetDate,
            resetDate: resetDate.addingTimeInterval(5 * 3600),
            leadTime: leadTime
        ))
        XCTAssertFalse(AppStore.shouldSendResetNotification(
            remaining: -1,
            lastNotifiedReset: nil,
            resetDate: resetDate,
            leadTime: leadTime
        ))
    }
}
