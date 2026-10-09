import SwiftUI

/// Centred symbol, title, one line of detail, at most one action.
public struct EmptyState: View {
    public struct Action {
        let title: String
        let perform: () -> Void
        public init(_ title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let symbol: String
    let title: String
    let detail: String
    let action: Action?

    public init(symbol: String, title: String, detail: String, action: Action? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.inkTertiary)
                .padding(.bottom, Theme.Space.xs)
            Text(title).textRole(.heading)
            Text(detail).textRole(.body, Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(HoursButtonStyle())
                    .padding(.top, Theme.Space.s)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
    }

    // MARK: Canned variants

    public static func trackerNotRunning(start: Action? = nil) -> EmptyState {
        EmptyState(symbol: "pause.circle", title: "Tracker isn't running",
                   detail: "No time is being recorded. Start the tracker to resume.", action: start)
    }

    public static func permissionMissing(openSettings: Action? = nil) -> EmptyState {
        EmptyState(symbol: "lock.shield", title: "Accessibility access needed",
                   detail: "Hours reads window titles through Accessibility. Grant access in System Settings.",
                   action: openSettings)
    }

    public static func noData() -> EmptyState {
        EmptyState(symbol: "calendar", title: "Nothing tracked",
                   detail: "There's no recorded time in this range.")
    }

    public static func filteredToNothing(clear: Action? = nil) -> EmptyState {
        EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No matches",
                   detail: "The current filters hide everything in this range.", action: clear)
    }
}
