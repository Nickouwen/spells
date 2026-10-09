import SwiftUI
import HoursCore

/// `‹ [16–30 Sep 2026 ▾] ›` — period label with a preset menu and step buttons.
struct RangePeriodBar: View {
    @Binding var period: RangePeriod
    let today: LocalDate

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            stepButton("chevron.left", -1, "Previous period")
            Menu {
                ForEach(RangePeriod.presets, id: \.self) { p in
                    Button {
                        period = p
                    } label: {
                        Text("\(p.name)  ·  \(RangePeriod.label(p.bounds(today: today)))")
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Text(RangePeriod.label(period.bounds(today: today))).textRole(.heading)
                    Image(systemName: "chevron.down").font(TextRole.label.font).foregroundStyle(Theme.inkTertiary)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            stepButton("chevron.right", 1, "Next period")
            Text(period.name).textRole(.label, Theme.inkTertiary).padding(.leading, Theme.Space.s)
        }
    }

    private func stepButton(_ symbol: String, _ delta: Int, _ help: String) -> some View {
        Button {
            period = period.stepped(delta, today: today)
        } label: {
            Image(systemName: symbol)
                .font(TextRole.bodyEmph.font)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 26, height: 26)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Flat segmented control: selected segment = `surface` + hairline on a `surfaceRaised` track.
/// Pure SwiftUI so it matches the content surfaces (no system accent).
struct RangeSegmented<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.xxs) {
            ForEach(options) { o in
                let on = o == selection
                Button {
                    withAnimation(Theme.Motion.animation(Theme.Motion.hover, reduceMotion: reduceMotion)) { selection = o }
                } label: {
                    Text(title(o))
                        .textRole(.label, on ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 22)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: Theme.Radius.chip - Theme.Space.xxs, style: .continuous)
                                    .fill(Theme.surface)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip - Theme.Space.xxs, style: .continuous)
                                        .strokeBorder(Theme.hairline, lineWidth: Theme.Stroke.hairline))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xxs)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

/// `±` glyph for totals that include edits. Tooltip carries the raw delta.
struct RangeEditedMark: View {
    let deltaMs: Int64
    var body: some View {
        Text(verbatim: "±")
            .textRole(.label, Theme.inkSecondary)
            .padding(.horizontal, Theme.Space.xs)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: Theme.Space.xs, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
            .help("Adjusted \(RangeEditedMark.signed(deltaMs)) vs raw tracker record")
            .accessibilityLabel("Edited, \(RangeEditedMark.signed(deltaMs)) versus raw")
    }

    /// `+25m`, `−1h 5m`, `±0m`.
    static func signed(_ ms: Int64) -> String {
        if ms == 0 { return "±0m" }
        return (ms > 0 ? "+" : "\u{2212}") + Fmt.duration(ms: abs(ms))
    }
}

/// 6 pt category mark (rounded square). `slot == nil` + `!isCategory` → no mark.
struct RangeMark: View {
    let slot: Int?
    var size: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.Palette.swatch(slot: slot))
            .frame(width: size, height: size)
    }
}

/// Thin monochrome proportion bar (share of a total) on a `surfaceRaised` track.
struct RangeShareBar: View {
    let fraction: Double
    var fill: Swatch = Theme.inkSecondary
    var body: some View {
        Canvas { ctx, size in
            let r = size.height / 2
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r), with: .style(Theme.surfaceRaised))
            let w = max(size.height, size.width * min(1, max(0, fraction)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: size.height), cornerRadius: r), with: .style(fill))
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
