import Foundation

/// Rize category key → Hours seed category id. Explicit and closed: a key not listed here is
/// Uncategorized (nil) and shows up in the dry run's "unmapped" list. Keys from Rize's built-in
/// set (seen in exported Rize tracking rules) plus the documented extras.
public enum RizeCategoryMap {
    public static let table: [String: Int64?] = [
        "code": ClassifySeed.coding,
        "cloud_hosting": ClassifySeed.coding,
        "testing": ClassifySeed.coding,
        "design": ClassifySeed.coding,           // UI/design work in this stack is part of building; no Design category in Hours
        "data_analysis": ClassifySeed.research,
        "research": ClassifySeed.research,
        "learning": ClassifySeed.research,
        "writing": ClassifySeed.writing,
        "documenting": ClassifySeed.writing,
        "productivity": ClassifySeed.planning,
        "project_management": ClassifySeed.planning,
        "task_management": ClassifySeed.planning,
        "messaging": ClassifySeed.communication,
        "email": ClassifySeed.communication,
        "communication": ClassifySeed.communication,
        "hiring": ClassifySeed.communication,
        "video_conferencing": ClassifySeed.meetings,
        "meetings": ClassifySeed.meetings,
        "admin": ClassifySeed.system,
        "utility": ClassifySeed.system,
        "scheduling": ClassifySeed.system,       // Calendar is System & Admin in the seed
        "finance": ClassifySeed.system,
        "personal": ClassifySeed.personal,
        "social_media": ClassifySeed.social,
        "entertainment": ClassifySeed.entertainment,
        "gaming": ClassifySeed.entertainment,
        "news": ClassifySeed.entertainment,      // news sites are Entertainment in the seed
        // Deliberately Uncategorized (PLAN: no Browsing catch-all; unmatched goes to review).
        "browsing": nil,
        "miscellaneous": nil,
        "uncategorized": nil,
    ]

    /// (Hours category id or nil, whether the key is in the table).
    public static func map(_ rizeKey: String) -> (categoryId: Int64?, mapped: Bool) {
        guard let v = table[rizeKey] else { return (nil, false) }
        return (v, true)
    }
}
