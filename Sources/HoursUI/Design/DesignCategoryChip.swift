import SwiftUI
import HoursCore

/// 22 pt chip: category mark + ink name on `surfaceRaised`. Filter-on = ink border, not fill —
/// the colour stays on the mark, never the text.
public struct CategoryChip: View {
    let name: String
    let slot: Int?
    let isOn: Bool

    public init(name: String, slot: Int?, isOn: Bool = false) {
        self.name = name
        self.slot = slot
        self.isOn = isOn
    }

    public init(_ category: HoursCore.Category, isOn: Bool = false) {
        self.init(name: category.name, slot: category.colorSlot, isOn: isOn)
    }

    public var body: some View {
        HStack(spacing: Theme.Space.xs + Theme.Space.xxs) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.Palette.swatch(slot: slot))
                .frame(width: 6, height: 6)
            Text(name).textRole(.label).lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 22)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        .overlay {
            if isOn {
                RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: Theme.Stroke.selection)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
