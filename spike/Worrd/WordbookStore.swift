import Foundation
import SQLite3

struct RecordInfo {
    var count: Int
    var previousLookup: Date?
    var isNew: Bool

    var summary: String {
        if isNew || previousLookup == nil {
            return "已加入单词本 · 第 1 次查询"
        }
        let days = Calendar.current.dateComponents([.day], from: previousLookup!, to: Date()).day ?? 0
        let when: String
        switch days {
        case ..<0: when = "刚刚"
        case 0: when = "今天"
        case 1: when = "昨天"
        default: when = "\(days) 天前"
        }
        return "已加入单词本 · 第 \(count) 次查询 · 上次 \(when)"
    }
}

struct WordRow: Identifiable {
    let id: Int64
    let headword: String
    let lang: String
    let phonetic: String
    let body: String
    let count: Int
    let firstLooked: Date
    let lastLooked: Date
    let note: String
    let source: String

    var gloss: String {
        let posTags: Set<String> = [
            "n.", "v.", "adj.", "adv.", "prep.", "pron.", "conj.", "interj.", "det.",
            "名", "动", "形", "副", "介", "代", "连", "叹", "量", "数",
        ]
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !posTags.contains($0) && !$0.hasPrefix("▸") }
        var line = lines.first(where: { $0.range(of: "\\p{Han}", options: .regularExpression) != nil })
            ?? lines.first
            ?? ""
        if let first = line.first, "①②③④⑤⑥⑦⑧⑨⑩".contains(first) {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return String(line.prefix(70))
    }
}

@MainActor
final class WordbookStore {
    static let shared = WordbookStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.renjun.worrd.db")

    private init() {
        open()
        migrate()
    }

    private var databaseURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Worrd", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("wordbook.sqlite")
    }

    private func open() {
        let path = databaseURL.path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            print("[Worrd] db open failed: \(String(cString: sqlite3_errmsg(db)))")
        } else {
            print("[Worrd] db: \(path)")
        }
    }

    private func migrate() {
        exec("PRAGMA journal_mode=WAL;")
        exec("""
        CREATE TABLE IF NOT EXISTS words (
          id INTEGER PRIMARY KEY,
          headword TEXT NOT NULL,
          lang TEXT NOT NULL,
          phonetic TEXT DEFAULT '',
          body TEXT DEFAULT '',
          lookup_count INTEGER NOT NULL DEFAULT 0,
          first_looked_at REAL NOT NULL,
          last_looked_at REAL NOT NULL,
          starred INTEGER NOT NULL DEFAULT 0,
          note TEXT DEFAULT '',
          UNIQUE(headword, lang)
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS lookups (
          id INTEGER PRIMARY KEY,
          word_id INTEGER NOT NULL,
          queried TEXT NOT NULL,
          entry_point TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_lookups_word ON lookups(word_id, created_at);")
        if !columnExists("words", "source") {
            exec("ALTER TABLE words ADD COLUMN source TEXT NOT NULL DEFAULT 'oxford';")
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            print("[Worrd] sql error: \(message)")
            sqlite3_free(err)
        }
    }

    // MARK: - Recording

    func record(_ result: LookupResult, entryPoint: String) -> RecordInfo {
        let now = Date().timeIntervalSince1970
        let lang = result.isChinese ? "zh" : "en"

        var existingID: Int64?
        var previous: Date?
        var previousCount = 0

        let findSQL = "SELECT id, lookup_count, last_looked_at FROM words WHERE headword = ? AND lang = ? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, findSQL, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, result.headword)
            bind(stmt, 2, lang)
            if sqlite3_step(stmt) == SQLITE_ROW {
                existingID = sqlite3_column_int64(stmt, 0)
                previousCount = Int(sqlite3_column_int(stmt, 1))
                previous = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            }
            sqlite3_finalize(stmt)
        }

        let isNew = existingID == nil
        let newCount = previousCount + 1

        if let id = existingID {
            let sql = "UPDATE words SET lookup_count = ?, last_looked_at = ?, body = ?, phonetic = ?, source = ? WHERE id = ?;"
            var update: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &update, nil) == SQLITE_OK {
                sqlite3_bind_int(update, 1, Int32(newCount))
                sqlite3_bind_double(update, 2, now)
                bind(update, 3, result.body)
                bind(update, 4, result.phonetic)
                bind(update, 5, result.source)
                sqlite3_bind_int64(update, 6, id)
                if sqlite3_step(update) != SQLITE_DONE {
                    print("[Worrd] update failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_finalize(update)
            }
        } else {
            let sql = "INSERT INTO words (headword, lang, phonetic, body, lookup_count, first_looked_at, last_looked_at, source) VALUES (?, ?, ?, ?, 1, ?, ?, ?);"
            var insert: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &insert, nil) == SQLITE_OK {
                bind(insert, 1, result.headword)
                bind(insert, 2, lang)
                bind(insert, 3, result.phonetic)
                bind(insert, 4, result.body)
                sqlite3_bind_double(insert, 5, now)
                sqlite3_bind_double(insert, 6, now)
                bind(insert, 7, result.source)
                if sqlite3_step(insert) != SQLITE_DONE {
                    print("[Worrd] insert failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                sqlite3_finalize(insert)
            }
            existingID = sqlite3_last_insert_rowid(db)
        }

        let lookupSQL = "INSERT INTO lookups (word_id, queried, entry_point, created_at) VALUES (?, ?, ?, ?);"
        var lookup: OpaquePointer?
        if sqlite3_prepare_v2(db, lookupSQL, -1, &lookup, nil) == SQLITE_OK {
            sqlite3_bind_int64(lookup, 1, existingID ?? 0)
            bind(lookup, 2, result.query)
            bind(lookup, 3, entryPoint)
            sqlite3_bind_double(lookup, 4, now)
            sqlite3_step(lookup)
            sqlite3_finalize(lookup)
        }

        return RecordInfo(count: newCount, previousLookup: previous, isNew: isNew)
    }

    // MARK: - Reading

    func allWords() -> [WordRow] {
        let sql = "SELECT id, headword, lang, phonetic, body, lookup_count, first_looked_at, last_looked_at, note, source FROM words ORDER BY last_looked_at DESC;"
        var stmt: OpaquePointer?
        var rows: [WordRow] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("[Worrd] allWords prepare failed")
            return []
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(row(from: stmt))
        }
        sqlite3_finalize(stmt)
        return rows
    }

    func updateNote(_ id: Int64, note: String) {
        let sql = "UPDATE words SET note = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, note)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func delete(_ id: Int64) {
        for sql in ["DELETE FROM lookups WHERE word_id = ?;", "DELETE FROM words WHERE id = ?;"] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    private func row(from stmt: OpaquePointer?) -> WordRow {
        WordRow(
            id: sqlite3_column_int64(stmt, 0),
            headword: string(from: stmt, 1),
            lang: string(from: stmt, 2),
            phonetic: string(from: stmt, 3),
            body: string(from: stmt, 4),
            count: Int(sqlite3_column_int(stmt, 5)),
            firstLooked: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            lastLooked: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            note: string(from: stmt, 8),
            source: string(from: stmt, 9)
        )
    }

    private func string(from stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    // MARK: - Helpers

    private func columnExists(_ table: String, _ column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if string(from: stmt, 1) == column { found = true; break }
        }
        sqlite3_finalize(stmt)
        return found
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
}
