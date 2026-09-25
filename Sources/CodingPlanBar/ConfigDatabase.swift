import CryptoKit
import Foundation
import SQLite3

/// 本地 SQLite 配置库。
///
/// 设计要点：
/// - `settings` 保存全局显示配置；
/// - `providers` 保存渠道结构化配置；
/// - `credentials` 单独保存 Token，避免把鉴权信息混在普通配置字段里；
/// - 数据库文件权限固定为 0600；
/// - 旧版 `config.json` 只在 SQLite 尚无渠道时自动导入一次。
enum ConfigDatabase {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Value {
        case text(String)
        case int(Int)
    }

    static func loadConfig() throws -> FileConfig {
        try withDatabase { db in
            try setUpDatabase(db)
            try importLegacyConfigIfNeeded(db)
            return try readConfig(db)
        }
    }

    static func saveConfig(_ config: FileConfig) throws {
        try withDatabase { db in
            try setUpDatabase(db)
            try writeConfig(db, config: config)
        }
    }

    static func setValue(key: String, value: String) throws {
        try withDatabase { db in
            try setUpDatabase(db)
            try upsertSetting(db, key: key, value: value)
        }
    }

    /// 进程内一致的数据库摘要，用于区分自身写入和外部修改。
    static func digest() -> String {
        guard let data = try? Data(contentsOf: ConfigLoader.databaseFile) else { return "" }
        let hash = SHA256.hash(data: data)
        return "\(data.count)-\(hash.map { String(format: "%02x", $0) }.joined())"
    }

    // MARK: - SQLite lifecycle

    private static func withDatabase<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        let path = ConfigLoader.databaseFile.path
        let directory = ConfigLoader.databaseFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close_v2(db)
            throw DatabaseError(message: "无法打开 SQLite 数据库：\(message)")
        }

        db = nil
        defer { sqlite3_close_v2(handle) }
        chmod(path, 0o600)
        return try body(handle)
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw DatabaseError(message: "SQLite 执行失败：\(message)")
        }
    }

    private static func prepare(_ db: OpaquePointer?, sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: "SQLite 预处理失败：\(String(cString: sqlite3_errmsg(db)))")
        }
        return statement
    }

    private static func bind(_ statement: OpaquePointer?, values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, transientDestructor)
            case .int(let int):
                result = sqlite3_bind_int64(statement, index, Int64(int))
            }
            guard result == SQLITE_OK else {
                throw DatabaseError(message: "SQLite 绑定参数失败：\(result)")
            }
        }
    }

    private static func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError(message: "SQLite 写入失败")
        }
    }

    private static func text(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func int(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    // MARK: - Schema and migration

    private static func setUpDatabase(_ db: OpaquePointer?) throws {
        try execute(db, """
        PRAGMA foreign_keys = ON;
        PRAGMA journal_mode = DELETE;
        PRAGMA synchronous = FULL;
        PRAGMA busy_timeout = 3000;

        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS providers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            type TEXT NOT NULL,
            icon TEXT,
            base_url TEXT,
            endpoint TEXT,
            auth_style TEXT,
            parser_json TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS credentials (
            provider_id INTEGER PRIMARY KEY
                REFERENCES providers(id) ON DELETE CASCADE ON UPDATE CASCADE,
            token TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        );
        """)
    }

    private static func importLegacyConfigIfNeeded(_ db: OpaquePointer?) throws {
        let marker = try prepare(db, sql: "SELECT value FROM settings WHERE key = 'legacy_imported';")
        defer { sqlite3_finalize(marker) }
        guard sqlite3_step(marker) != SQLITE_ROW else { return }

        let statement = try prepare(db, sql: "SELECT COUNT(*) FROM providers;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError(message: "SQLite 读取渠道数量失败")
        }
        guard Int(sqlite3_column_int64(statement, 0)) == 0 else { return }

        guard let legacy = ConfigLoader.loadLegacyFileConfig() else { return }
        let config = normalizeLegacy(legacy)
        guard !(config.providers ?? []).isEmpty else { return }
        try writeConfig(db, config: config)
        try upsertSetting(db, key: "legacy_imported", value: "true")
        markLegacyJSONAsMigrated()
    }

    private static func normalizeLegacy(_ config: FileConfig) -> FileConfig {
        var providers = config.providers ?? []
        if providers.isEmpty,
           let token = config.token, !token.isEmpty {
            providers.append(ProviderConfig(
                name: "Kimi",
                type: "kimi",
                token: token,
                icon: nil,
                baseURL: config.baseURL,
                endpoint: config.endpoint,
                authStyle: nil,
                parser: nil
            ))
        }
        return FileConfig(
            providers: providers,
            thresholds: config.thresholds,
            token: nil,
            baseURL: nil,
            endpoint: nil,
            menuBarMode: config.menuBarMode,
            notificationsEnabled: config.notificationsEnabled,
            launchAtLogin: config.launchAtLogin
        )
    }

    /// 迁移成功后清空旧 JSON 中的明文 Token，避免鉴权信息同时存在于两处。
    private static func markLegacyJSONAsMigrated() {
        let marker: [String: String] = [
            "storage": "sqlite",
            "database": ConfigLoader.databaseFile.path,
            "migrated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: ConfigLoader.configFile, options: .atomic)
            chmod(ConfigLoader.configFile.path, 0o600)
        } catch {
            NSLog("[CPB] 旧 JSON 配置已迁移，但清理明文 Token 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Read / write

    private static func readConfig(_ db: OpaquePointer?) throws -> FileConfig {
        var settings: [String: String] = [:]
        let settingStatement = try prepare(db, sql: "SELECT key, value FROM settings;")
        defer { sqlite3_finalize(settingStatement) }
        var settingResult = sqlite3_step(settingStatement)
        while settingResult == SQLITE_ROW {
            if let key = text(settingStatement, index: 0), let value = text(settingStatement, index: 1) {
                settings[key] = value
            }
            settingResult = sqlite3_step(settingStatement)
        }
        guard settingResult == SQLITE_DONE else {
            throw DatabaseError(message: "SQLite 读取设置失败：\(String(cString: sqlite3_errmsg(db)))")
        }

        let providerStatement = try prepare(db, sql: """
        SELECT p.name, p.type, p.icon, p.base_url, p.endpoint, p.auth_style, p.parser_json, c.token
        FROM providers p
        LEFT JOIN credentials c ON c.provider_id = p.id
        ORDER BY p.sort_order, p.id;
        """)
        defer { sqlite3_finalize(providerStatement) }

        var providers: [ProviderConfig] = []
        var providerResult = sqlite3_step(providerStatement)
        while providerResult == SQLITE_ROW {
            let parserJSON = text(providerStatement, index: 6)
            let parser = parserJSON.flatMap { json in
                try? JSONDecoder().decode(CustomParser.self, from: Data(json.utf8))
            }
            providers.append(ProviderConfig(
                name: text(providerStatement, index: 0) ?? "",
                type: text(providerStatement, index: 1) ?? "",
                token: text(providerStatement, index: 7),
                icon: text(providerStatement, index: 2),
                baseURL: text(providerStatement, index: 3),
                endpoint: text(providerStatement, index: 4),
                authStyle: text(providerStatement, index: 5),
                parser: parser
            ))
            providerResult = sqlite3_step(providerStatement)
        }
        guard providerResult == SQLITE_DONE else {
            throw DatabaseError(message: "SQLite 读取渠道失败：\(String(cString: sqlite3_errmsg(db)))")
        }

        let green = settings["thresholds.green"].flatMap(Int.init)
        let yellow = settings["thresholds.yellow"].flatMap(Int.init)
        return FileConfig(
            providers: providers,
            thresholds: .init(green: green, yellow: yellow),
            token: nil,
            baseURL: nil,
            endpoint: nil,
            menuBarMode: settings["menu_bar_mode"],
            notificationsEnabled: settings["notifications_enabled"].flatMap { $0 == "true" },
            launchAtLogin: settings["launch_at_login"].flatMap { $0 == "true" }
        )
    }

    private static func writeConfig(_ db: OpaquePointer?, config: FileConfig) throws {
        try execute(db, "BEGIN IMMEDIATE;")
        var committed = false
        defer {
            if !committed { try? execute(db, "ROLLBACK;") }
        }

        try execute(db, "DELETE FROM providers;")

        let now = Int(Date().timeIntervalSince1970)
        if let green = config.thresholds?.green {
            try upsertSetting(db, key: "thresholds.green", value: String(green), now: now)
        }
        if let yellow = config.thresholds?.yellow {
            try upsertSetting(db, key: "thresholds.yellow", value: String(yellow), now: now)
        }
        if let mode = config.menuBarMode {
            try upsertSetting(db, key: "menu_bar_mode", value: mode, now: now)
        }
        if let notifications = config.notificationsEnabled {
            try upsertSetting(db, key: "notifications_enabled", value: notifications ? "true" : "false", now: now)
        }
        if let launch = config.launchAtLogin {
            try upsertSetting(db, key: "launch_at_login", value: launch ? "true" : "false", now: now)
        }

        for (offset, provider) in (config.providers ?? []).enumerated() {
            let parserData = provider.parser.flatMap { try? JSONEncoder().encode($0) }
            let parserJSON = parserData.flatMap { String(data: $0, encoding: .utf8) }
            let insert = try prepare(db, sql: """
            INSERT INTO providers
                (name, type, icon, base_url, endpoint, auth_style, parser_json, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            defer { sqlite3_finalize(insert) }
            try bind(insert, values: [
                .text(provider.name),
                .text(provider.type),
                .text(provider.icon ?? ""),
                .text(provider.baseURL ?? ""),
                .text(provider.endpoint ?? ""),
                .text(provider.authStyle ?? ""),
                .text(parserJSON ?? ""),
                .int(offset),
                .int(now),
                .int(now),
            ])
            try step(insert)

            let providerID = Int(sqlite3_last_insert_rowid(db))
            let credential = try prepare(db, sql: """
            INSERT INTO credentials (provider_id, token, updated_at) VALUES (?, ?, ?);
            """)
            defer { sqlite3_finalize(credential) }
            try bind(credential, values: [
                .int(providerID),
                .text(provider.token ?? ""),
                .int(now),
            ])
            try step(credential)
        }

        try execute(db, "COMMIT;")
        committed = true
    }

    private static func upsertSetting(
        _ db: OpaquePointer?,
        key: String,
        value: String,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws {
        let statement = try prepare(db, sql: """
        INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, values: [.text(key), .text(value), .int(now)])
        try step(statement)
    }
}
