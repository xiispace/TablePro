import Foundation
import os
import TableProPluginKit

public actor MCPConnectionBridge {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPConnectionBridge")

    public init() {}

    func listConnections() async -> JsonValue {
        let (connections, activeSessions) = await MainActor.run {
            let conns = ConnectionStorage.shared.loadConnections()
                .filter { $0.resolvedExternalAccess != .blocked }
            let sessions = DatabaseManager.shared.activeSessions
            return (conns, sessions)
        }

        let items: [JsonValue] = connections.map { conn in
            let session = activeSessions[conn.id]
            let isConnected = session?.status.isConnected ?? false
            let policy = conn.aiPolicy ?? AIConnectionPolicy.askEachTime

            return .object([
                "id": .string(conn.id.uuidString),
                "name": .string(conn.name),
                "type": .string(conn.type.rawValue),
                "host": .string(conn.host),
                "port": .int(conn.port),
                "database": .string(session?.activeDatabase ?? conn.database),
                "username": .string(conn.username),
                "is_connected": .bool(isConnected),
                "ai_policy": .string(policy.rawValue),
                "safe_mode": .string(conn.safeModeLevel.rawValue)
            ])
        }

        return .object(["connections": .array(items)])
    }

    func connect(connectionId: UUID) async throws -> JsonValue {
        let connection = try await resolveConnection(connectionId)

        let existingSession = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId]
        }

        if let existing = existingSession, existing.driver != nil {
            let serverVersion = existing.driver?.serverVersion
            let currentDatabase = existing.activeDatabase
            let currentSchema = existing.currentSchema

            var result: [String: JsonValue] = [
                "status": "connected",
                "current_database": .string(currentDatabase)
            ]
            if let version = serverVersion {
                result["server_version"] = .string(version)
            }
            if let schema = currentSchema {
                result["current_schema"] = .string(schema)
            }
            return .object(result)
        }

        try await DatabaseManager.shared.ensureConnected(connection)

        let (serverVersion, currentDatabase, currentSchema) = await MainActor.run {
            let session = DatabaseManager.shared.activeSessions[connectionId]
            return (
                session?.driver?.serverVersion,
                session?.activeDatabase,
                session?.currentSchema
            )
        }

        var result: [String: JsonValue] = [
            "status": "connected",
            "current_database": .string(currentDatabase ?? "")
        ]
        if let version = serverVersion {
            result["server_version"] = .string(version)
        }
        if let schema = currentSchema {
            result["current_schema"] = .string(schema)
        }

        return .object(result)
    }

    func disconnect(connectionId: UUID) async throws {
        let sessionExists = await MainActor.run {
            DatabaseManager.shared.activeSessions[connectionId] != nil
        }
        guard sessionExists else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        await DatabaseManager.shared.disconnectSession(connectionId)
    }

    func getConnectionStatus(connectionId: UUID) async throws -> JsonValue {
        let core = await MainActor.run {
            () -> (status: ConnectionStatus, database: String, schema: String?)? in
            guard let session = DatabaseManager.shared.activeSessions[connectionId] else {
                return nil
            }
            return (session.status, session.activeDatabase, session.currentSchema)
        }

        guard let core else {
            throw MCPDataLayerError.notConnected(connectionId)
        }

        let meta = await MainActor.run {
            () -> (version: String?, connectedAt: Date, lastActiveAt: Date) in
            let session = DatabaseManager.shared.activeSessions[connectionId]
            return (
                session?.driver?.serverVersion,
                session?.connectedAt ?? Date(),
                session?.lastActiveAt ?? Date()
            )
        }

        let statusString: String
        var errorDetail: JsonValue?
        switch core.status {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnected: statusString = "disconnected"
        case .error(let msg):
            statusString = "error"
            errorDetail = .object([
                "message": .string(msg)
            ])
        }

        var result: [String: JsonValue] = [
            "status": .string(statusString),
            "current_database": .string(core.database),
            "connected_at": .string(ISO8601DateFormatter().string(from: meta.connectedAt)),
            "last_active_at": .string(ISO8601DateFormatter().string(from: meta.lastActiveAt))
        ]
        if let schema = core.schema {
            result["current_schema"] = .string(schema)
        }
        if let version = meta.version {
            result["server_version"] = .string(version)
        }
        if let errorDetail {
            result["error"] = errorDetail
        }

        return .object(result)
    }

    func executeQuery(
        connectionId: UUID,
        query: String,
        maxRows: Int,
        timeoutSeconds: Int
    ) async throws -> JsonValue {
        let (driver, databaseType) = try await resolveDriver(connectionId)
        let normalizedQuery = Self.stripTrailingSemicolons(query)
        let isWrite = QueryClassifier.isWriteQuery(normalizedQuery, databaseType: databaseType)
        let hasReturning = normalizedQuery.range(of: #"\bRETURNING\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let shouldCap = !isWrite || hasReturning

        let startTime = CFAbsoluteTimeGetCurrent()

        let result: QueryResult = try await DatabaseManager.shared.trackOperation(
            sessionId: connectionId
        ) {
            try await withThrowingTaskGroup(of: QueryResult.self) { group in
                group.addTask {
                    if shouldCap {
                        return try await driver.executeUserQuery(
                            query: normalizedQuery,
                            rowCap: maxRows,
                            parameters: nil
                        )
                    }
                    return try await driver.execute(query: normalizedQuery)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    try? driver.cancelQuery()
                    throw MCPDataLayerError.timeout("Query timed out after \(timeoutSeconds) seconds")
                }
                guard let first = try await group.next() else {
                    throw MCPDataLayerError.dataSourceError("No result from query execution")
                }
                group.cancelAll()
                return first
            }
        }

        let executionTimeMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1_000
        let isTruncated = result.isTruncated

        let jsonColumns: [JsonValue] = result.columns.map { .string($0) }
        let jsonRows: [JsonValue] = result.rows.map { row in
            .array(row.map { cell in
                switch cell {
                case .null: return .null
                case .text(let s): return .string(s)
                case .bytes(let d): return .string(d.base64EncodedString())
                }
            })
        }

        var response: [String: JsonValue] = [
            "columns": .array(jsonColumns),
            "rows": .array(jsonRows),
            "row_count": .int(result.rows.count),
            "rows_affected": .int(result.rowsAffected),
            "execution_time_ms": .double(executionTimeMs),
            "is_truncated": .bool(isTruncated)
        ]
        if let statusMessage = result.statusMessage {
            response["status_message"] = .string(statusMessage)
        }

        return .object(response)
    }

    func listTables(connectionId: UUID, includeRowCounts: Bool) async throws -> JsonValue {
        let cachedTables = await MainActor.run {
            SchemaService.shared.tables(for: connectionId)
        }

        let tables: [TableInfo]
        if !cachedTables.isEmpty {
            tables = cachedTables
        } else {
            let (driver, _) = try await resolveDriver(connectionId)
            tables = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
                try await driver.fetchTables()
            }
        }

        let jsonTables: [JsonValue] = tables.map { table in
            var obj: [String: JsonValue] = [
                "name": .string(table.name),
                "type": .string(table.type.rawValue)
            ]
            if includeRowCounts, let rowCount = table.rowCount {
                obj["row_count"] = .int(rowCount)
            }
            return .object(obj)
        }

        return .object(["tables": .array(jsonTables)])
    }

    func describeTable(connectionId: UUID, table: String, schema: String?) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)

        return try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            let columns = try await driver.fetchColumns(table: table, schema: schema)
            let indexes = try await driver.fetchIndexes(table: table)
            let foreignKeys = try await driver.fetchForeignKeys(table: table)
            let approxRowCount = try await driver.fetchApproximateRowCount(table: table)
            let ddl = try? await driver.fetchTableDDL(table: table)

            let jsonColumns: [JsonValue] = columns.map { col in
                var obj: [String: JsonValue] = [
                    "name": .string(col.name),
                    "data_type": .string(col.dataType),
                    "is_nullable": .bool(col.isNullable),
                    "is_primary_key": .bool(col.isPrimaryKey)
                ]
                if let def = col.defaultValue { obj["default_value"] = .string(def) }
                if let extra = col.extra { obj["extra"] = .string(extra) }
                if let comment = col.comment, !comment.isEmpty { obj["comment"] = .string(comment) }
                return .object(obj)
            }

            let jsonIndexes: [JsonValue] = indexes.map { idx in
                .object([
                    "name": .string(idx.name),
                    "columns": .array(idx.columns.map { .string($0) }),
                    "is_unique": .bool(idx.isUnique),
                    "is_primary": .bool(idx.isPrimary),
                    "type": .string(idx.type)
                ])
            }

            let jsonFKs: [JsonValue] = foreignKeys.map { fk in
                var obj: [String: JsonValue] = [
                    "name": .string(fk.name),
                    "column": .string(fk.column),
                    "referenced_table": .string(fk.referencedTable),
                    "referenced_column": .string(fk.referencedColumn),
                    "on_delete": .string(fk.onDelete),
                    "on_update": .string(fk.onUpdate)
                ]
                if let refSchema = fk.referencedSchema {
                    obj["referenced_schema"] = .string(refSchema)
                }
                return .object(obj)
            }

            var result: [String: JsonValue] = [
                "columns": .array(jsonColumns),
                "indexes": .array(jsonIndexes),
                "foreign_keys": .array(jsonFKs)
            ]
            if let ddl {
                result["ddl"] = .string(ddl)
            }
            if let count = approxRowCount {
                result["approximate_row_count"] = .int(count)
            }

            return .object(result)
        }
    }

    func listDatabases(connectionId: UUID) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        let databases = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.fetchDatabases()
        }
        return .object(["databases": .array(databases.map { .string($0) })])
    }

    func listSchemas(connectionId: UUID) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        let schemas = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.fetchSchemas()
        }
        return .object(["schemas": .array(schemas.map { .string($0) })])
    }

    func getTableDDL(connectionId: UUID, table: String, schema: String?) async throws -> JsonValue {
        let (driver, _) = try await resolveDriver(connectionId)
        let ddl = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
            try await driver.fetchTableDDL(table: table)
        }
        return .object(["ddl": .string(ddl)])
    }

    func switchDatabase(connectionId: UUID, database: String) async throws -> JsonValue {
        try await DatabaseManager.shared.switchDatabase(to: database, for: connectionId)
        return .object([
            "status": "switched",
            "current_database": .string(database)
        ])
    }

    func switchSchema(connectionId: UUID, schema: String) async throws -> JsonValue {
        try await DatabaseManager.shared.switchSchema(to: schema, for: connectionId)
        return .object([
            "status": "switched",
            "current_schema": .string(schema)
        ])
    }

    func fetchSchemaResource(connectionId: UUID) async throws -> JsonValue {
        let cachedTables = await MainActor.run {
            SchemaService.shared.tables(for: connectionId)
        }
        let tables: [TableInfo]
        if !cachedTables.isEmpty {
            tables = cachedTables
        } else {
            let (driver, _) = try await resolveDriver(connectionId)
            tables = try await DatabaseManager.shared.trackOperation(sessionId: connectionId) {
                try await driver.fetchTables()
            }
        }

        let resources = tables.map { table in
            JsonValue.object([
                "uri": .string("tablepro://connection/\(connectionId.uuidString)/schema/\(table.name)"),
                "name": .string(table.name),
                "mimeType": .string("application/json")
            ])
        }
        return .object(["resources": .array(resources)])
    }

    private func resolveConnection(_ connectionId: UUID) async throws -> DatabaseConnection {
        let connection = await MainActor.run {
            DatabaseManager.shared.connectionState(connectionId).connection
        }
        guard let connection else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        return connection
    }

    private func resolveDriver(_ connectionId: UUID) async throws -> (any DatabaseDriver, DatabaseType) {
        let state = await MainActor.run {
            DatabaseManager.shared.connectionState(connectionId)
        }
        guard let connection = state.connection else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        guard let session = state.session, let driver = session.driver else {
            throw MCPDataLayerError.notConnected(connectionId)
        }
        return (driver, connection.type)
    }

    private static func stripTrailingSemicolons(_ sql: String) -> String {
        var result = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(";") {
            result.removeLast()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
