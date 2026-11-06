import AppKit
import Foundation
import SQLite3

/// Unread chats, read from WhatsApp Desktop's local database. Read-only, kept in memory only and
/// never sent anywhere. It only sees what the desktop app has synced, so it needs to have run.
enum WhatsAppProvider {
    static let bundleID = "net.whatsapp.WhatsApp"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// `-KodisleDebugWhatsAppDB <path>` points at a sample database for end-to-end tests.
    private static var database: String {
        UserDefaults.standard.string(forKey: "KodisleDebugWhatsAppDB")
            ?? NSHomeDirectory() + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"
    }

    /// Session types 0 and 1 are 1:1 and group chats; the rest are broadcast lists and statuses
    /// (unseen statuses also carry an unread count). The preview comes from the message itself:
    /// `ZLASTMESSAGETEXT` holds base64 protobuf metadata, not text.
    private static let query = """
        SELECT s.ZCONTACTJID, s.ZPARTNERNAME, s.ZUNREADCOUNT, s.ZLASTMESSAGEDATE, s.ZSESSIONTYPE,
               (SELECT MAX(p.ZMUTEDUNTIL) FROM ZWACHATPUSHCONFIG p WHERE p.ZJID = s.ZCONTACTJID),
               m.ZMESSAGETYPE, m.ZTEXT, i.ZTITLE
        FROM ZWACHATSESSION s
        LEFT JOIN ZWAMESSAGE m ON m.Z_PK = s.ZLASTMESSAGE
        LEFT JOIN ZWAMEDIAITEM i ON i.Z_PK = m.ZMEDIAITEM
        WHERE s.ZUNREADCOUNT <> 0 AND s.ZSESSIONTYPE IN (0, 1)
          AND COALESCE(s.ZARCHIVED, 0) = 0 AND COALESCE(s.ZHIDDEN, 0) = 0 AND COALESCE(s.ZREMOVED, 0) = 0
        ORDER BY s.ZLASTMESSAGEDATE DESC
        LIMIT 30
        """

    /// Blocking: call off the main thread (macOS may show a privacy prompt on first access).
    static func fetch() -> WhatsAppSnapshot {
        guard appURL != nil || UserDefaults.standard.string(forKey: "KodisleDebugWhatsAppDB") != nil else {
            return WhatsAppSnapshot(state: .notInstalled)
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return WhatsAppSnapshot(state: .noAccess)
        }
        sqlite3_busy_timeout(db, 500)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return WhatsAppSnapshot(state: .noAccess)
        }
        let now = Date.now.timeIntervalSinceReferenceDate
        var chats: [WhatsAppChat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            guard let jid = text(0) else { continue }
            chats.append(WhatsAppChat(id: jid, name: text(1).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown",
                                      preview: preview(type: sqlite3_column_int(statement, 6), text: text(7), caption: text(8)),
                                      unread: Int(sqlite3_column_int(statement, 2)),
                                      date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
                                      isGroup: sqlite3_column_int(statement, 4) == 1,
                                      isMuted: sqlite3_column_double(statement, 5) > now))
        }
        return WhatsAppSnapshot(state: .ready, chats: chats)
    }

    /// One line for a `ZMESSAGETYPE`. Empty for system events and unknown types, whose fields aren't
    /// meant for display; the views show a generic label instead.
    private static func preview(type: Int32, text: String?, caption: String?) -> String {
        func labeled(_ label: String, _ detail: String?) -> String {
            let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return detail.isEmpty ? label : detail
        }
        let line = switch type {
        case 0, 7: text ?? "" // Text, and text with a link
        case 1: "📷 " + labeled("Photo", caption)
        case 2: "🎥 " + labeled("Video", caption)
        case 3: "🎤 Voice message"
        case 4: "👤 Contact"
        case 5: "📍 Location"
        case 8: "📄 " + labeled("Document", text ?? caption)
        case 11: "GIF"
        case 14: "Deleted message"
        case 15: "Sticker"
        default: ""
        }
        return line.replacingOccurrences(of: "\n", with: " ")
    }

    /// Opens the chat when its JID is a phone number; WhatsApp has no deep link for the others.
    @MainActor
    static func open(_ chat: WhatsAppChat?) {
        if let chat, chat.id.hasSuffix("@s.whatsapp.net"), let phone = chat.id.split(separator: "@").first,
           let url = URL(string: "whatsapp://send?phone=\(phone)") {
            NSWorkspace.shared.open(url)
        } else if let appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
