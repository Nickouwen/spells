import Foundation

/// Draft rules for "apply to all similar" and project auto-rules. Drafts have `id = 0`,
/// `origin = .user`; the UI persists them via the config store, which assigns the id.
public enum ClassifyRuleSuggester {
    public enum Field: Hashable, Sendable {
        /// Bundle id (app name when the bundle id is unknown).
        case app
        /// URL host, any app.
        case host
        /// Bundle id (or app name) + URL host.
        case appAndHost
        /// Title contains this literal text (case-insensitive).
        case titleContains(String)
    }

    /// nil when the span lacks the needed field (e.g. `.host` with no URL) or no target is given.
    public static func rule(from span: EffectiveSpan, field: Field,
                            categoryId: Int64? = nil, projectId: Int64? = nil) -> Rule? {
        guard categoryId != nil || projectId != nil else { return nil }
        var r = Rule(id: 0, origin: .user, categoryId: categoryId, projectId: projectId)
        switch field {
        case .app:
            setApp(&r, span)
        case .host:
            guard let h = ClassifyURL.host(span.url) else { return nil }
            r.host = h
        case .appAndHost:
            guard let h = ClassifyURL.host(span.url) else { return nil }
            setApp(&r, span)
            r.host = h
        case .titleContains(let text):
            guard !text.isEmpty else { return nil }
            r.titleRegex = NSRegularExpression.escapedPattern(for: text)
        }
        return r
    }

    /// Auto-rule on project create: title contains `match` (default: the project name) as a whole token.
    public static func projectRule(for project: Project, match: String? = nil) -> Rule {
        Rule(id: 0, origin: .user, titleRegex: projectTitleRegex(match ?? project.name), projectId: project.id)
    }

    /// `(?<![\w-])<escaped>(?![\w-])`: `operations-dashboard` matches "outreach-systems/operations-dashboard"
    /// but not "operations-dashboard-old".
    public static func projectTitleRegex(_ match: String) -> String {
        #"(?<![\w-])"# + NSRegularExpression.escapedPattern(for: match) + #"(?![\w-])"#
    }

    private static func setApp(_ r: inout Rule, _ span: EffectiveSpan) {
        if let b = span.bundleId { r.bundleId = b } else { r.appName = span.appName }
    }
}
