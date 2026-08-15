import SwiftUI

// MARK: - RadioGroup

/// A vertical radio group where every option carries a **second line explaining what it does**.
///
/// The native `Picker(.radioGroup)` takes one `Text` per option and nothing else, so an option cannot
/// say more than its name. That is exactly the gap here: `Chill` / `Work harder!` / `Control freak`
/// read as moods, and the question a user actually has — *which signals does this make loudest?* — has
/// no room to be answered. Segments had the same problem in less space.
///
/// Anatomy, following System Settings' own explained-radio rows (Displays' colour-profile list,
/// Battery's power modes): the button, the option's name, and one secondary line beneath it. The
/// **whole row** is the hit target, not just the button.
///
/// The radio itself is drawn with SF Symbols (`largecircle.fill.circle` / `circle`) rather than by
/// hosting an `NSButton`: a real radio would bring its own label layout, which is the thing being
/// replaced. The accent colour is applied explicitly, since a plain template symbol renders in the
/// label colour rather than in the selection tint a radio is expected to have.
///
/// An option may be **shown but not selectable** (``Option/selectable``) — the same requirement that
/// shaped `SegmentedControl`: "Custom" has to be visible and highlightable while there is nothing
/// stashed to restore, without becoming pickable. Its description stays put either way — the line
/// describes the option, not the option's current reachability, so nothing under the pointer reflows
/// when a click does or does not take.
struct RadioGroup<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        /// The line under the title: what this option does, in the user's terms.
        let summary: String
        /// Whether clicking this option selects it. `false` = visible, highlightable, inert.
        ///
        /// It changes only whether the click lands and how the **title** is weighted — never the
        /// description. An option whose second line rewrote itself on selection would make the list
        /// reflow under the pointer, and the line stops being a stable description of the option.
        ///
        /// The dimming it drives is suppressed on the **active** row: a grey title means "clicking this
        /// does nothing", which on the option you are already on is both wrong and alarming. See
        /// ``RadioGroup/row(_:)``.
        var selectable: Bool = true
        var id: Value { value }
    }

    let options: [Option]
    /// The active option. May be one that is not selectable.
    let active: Value
    let onSelect: (Value) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(options) { option in
                row(option)
            }
        }
    }

    private func row(_ option: Option) -> some View {
        let isActive = option.value == active
        // A real Button, for the same reason `SegmentedControl` uses one: a bare tap gesture is eaten
        // by window activation, so the first click on an inactive Settings window would do nothing.
        return Button {
            if option.selectable { onSelect(option.value) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.buttonTextGap) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: Metrics.button))
                    // The unselected ring is a hairline in the system control; `.secondary` is what
                    // keeps it from reading as a filled-but-grey button.
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: Metrics.titleSummaryGap) {
                    Text(option.title)
                        // Dimmed only when the option is both **inert and not the current one**. The
                        // grey says "clicking this does nothing"; on the selected row that message is
                        // both wrong and confusing, since selecting it is exactly what already
                        // happened. "Custom" hit this: `canRestoreCustom` is false once Custom *is*
                        // the active preset (there is nothing left to restore), so choosing it dimmed
                        // its own title while every other option stayed bright.
                        .foregroundStyle(option.selectable || isActive ? .primary : .secondary)
                    Text(.init(option.summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // The whole row, including the gap right of the text, is clickable — it is what looks
            // clickable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

}

/// `RadioGroup`'s metrics, outside the type because a generic one cannot hold static storage.
private enum Metrics {
    /// Between rows. Wider than the 4 pt inside a row, so each option reads as one block rather
    /// than four evenly spaced lines.
    static let rowGap: CGFloat = 10
    /// Between the radio button and the text block.
    static let buttonTextGap: CGFloat = 6
    /// Title to its description — the same 4 pt every explained control in these panes uses
    /// between a row and its `SettingsHint`.
    static let titleSummaryGap: CGFloat = 4
    /// The radio glyph, sized to sit with body text rather than with the description under it.
    static let button: CGFloat = 14
}
