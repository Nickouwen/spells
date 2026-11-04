import SwiftUI

/// 26 pt borderless icon button, ink glyph.
public struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    public init(symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.disabled = disabled; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                // Quiet at rest (a column of full-ink ×s outweighed the rows); ink while hovered.
                .foregroundStyle(disabled ? Theme.inkDisabled : (hovering ? Theme.ink : Theme.inkTertiary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(disabled)
        .help(help)
    }
}

