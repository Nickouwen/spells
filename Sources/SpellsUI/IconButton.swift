import SwiftUI

/// 26 pt borderless icon button, ink glyph.
public struct IconButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void

    public init(symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.disabled = disabled; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.inkDisabled : Theme.ink)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

