import SwiftUI

// MARK: - RadioGroup

/// A vertical radio group where every option carries a **second line explaining what it does**, and may
/// carry an action of its own at the trailing edge.
///
/// The native `Picker(.radioGroup)` takes one `Text` per option and nothing else, so an option cannot
/// say more than its name. That is exactly the gap here: `Chill` / `Work harder!` / `Control freak`
/// read as moods, and the question a user actually has — *which signals does this make loudest?* — has
/// no room to be answered. Segments had the same problem in less space.
///
/// Anatomy, following System Settings' own explained-radio rows (Displays' colour-profile list,
/// Battery's power modes): the button, the option's name, and one secondary line beneath it, with an
/// optional control at the far right.
///
/// The radio itself is drawn with SF Symbols (`largecircle.fill.circle` / `circle`) rather than by
/// hosting an `NSButton`: a real radio would bring its own label layout, which is the thing being
/// replaced. The accent colour is applied explicitly, since a plain template symbol renders in the
/// label colour rather than in the selection tint a radio is expected to have.
///
/// An option may be **shown but not selectable** (``Option/selectable``). Its description stays put
/// either way — the line describes the option, not the option's current reachability, so nothing under
/// the pointer reflows when a click does or does not take.
struct RadioGroup<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        /// A note appended to the title in **secondary ink** — "· same as *Chill* preset" on the row
        /// that names the saved config.
        ///
        /// Separate from ``title`` rather than concatenated into it because the two carry different
        /// weight: the title names the option and never changes, while this reports state and comes and
        /// goes. Rendering it in the same ink would make a passing observation look like part of the
        /// option's name.
        ///
        /// Rendered through `Text(.init(_:))`, so inline markdown works — `*Chill*` italicises the
        /// preset's name inside the note, marking it as a name being quoted rather than a word in the
        /// sentence. Same mechanism `SettingsHint` uses for its own emphasis.
        var titleNote: String?
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
        ///
        /// Every option passes `true` today. The row this existed for — the old "Custom" — was
        /// selectable only in some states, which is exactly the ambiguity the preview model removed:
        /// all four rows are now real options that always do something.
        var selectable: Bool = true
        /// A control at the row's trailing edge — the `Apply` button on a previewed preset, the copy
        /// button on "My setup".
        ///
        /// Built lazily so the closure can read state that changes while the list is on screen. It is
        /// rendered **beside** the row's own button rather than inside it: a `Button` nested in another
        /// `Button` does not reliably receive clicks on macOS, and the outer one would also fire, so a
        /// click meant for `Apply` would additionally re-select the row.
        var trailing: (() -> AnyView)?
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
        return HStack(alignment: .firstTextBaseline, spacing: Metrics.buttonTextGap) {
            // A real Button, for the same reason `SegmentedControl` uses one: a bare tap gesture is
            // eaten by window activation, so the first click on an inactive Settings window would do
            // nothing.
            Button {
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
                        // The note trails the name inside one `Text`, so a long pair wraps as a single
                        // run rather than as two blocks that can break apart mid-row.
                        (Text(option.title)
                            // Dimmed only when the option is both **inert and not the current one**. The
                            // grey says "clicking this does nothing"; on the selected row that message is
                            // both wrong and confusing, since selecting it is exactly what already
                            // happened.
                            .foregroundStyle(option.selectable || isActive ? .primary : .secondary)
                         + Text(.init(option.titleNote.map { " \($0)" } ?? ""))
                            .foregroundStyle(.secondary))
                        Text(.init(option.summary))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                // The row's text block, including the gap right of it, is clickable — it is what looks
                // clickable. The trailing control sits outside this shape.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)

            if let trailing = option.trailing {
                trailing()
            }
        }
        // Every row reserves the height a trailing control needs, whether or not it has one. Without
        // it, the `Apply` button appearing on whichever preset is being previewed would grow that row
        // and shove the rows below it down — moving them under the pointer mid-comparison, which is
        // precisely when the user is clicking through the list.
        .frame(minHeight: Metrics.rowMinHeight, alignment: .center)
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
    /// The height every row reserves, sized to a `.bordered` button so rows do not change height as the
    /// trailing control comes and goes.
    static let rowMinHeight: CGFloat = 40
}
