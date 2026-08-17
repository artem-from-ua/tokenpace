import SwiftUI

// MARK: - SegmentedControl (#224)

/// A segmented control that allows a segment to be **shown-and-selectable OR shown-active-but-disabled**
/// — something the native `Picker(.pickerStyle(.segmented))` cannot do (its `.disabled` dims the whole
/// control, and it offers no per-segment disable). We need exactly that for the Appearance preset row:
/// the "Custom" segment must light up when the live config matches no preset, yet never be pickable.
///
/// A segment whose ``Segment/selectable`` is `false` renders like any other segment (and highlights when
/// it is the active one) but ignores selection taps. Selectable segments call ``onSelect`` with their
/// value. An unselectable segment carrying ``Segment/inactiveHelp`` shows that text in a **popover on
/// click** while it isn't the active one — so "Custom" can explain how to reach it.
///
/// Styled to sit next to the native `.segmented` pickers in the same pane: a rounded capsule track with the
/// active segment filled in the **system accent colour**. Not pixel-identical to AppKit's control, but
/// close enough to read as the same affordance.
struct SegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        /// Whether tapping this segment selects it. `false` = an indicator-only segment (e.g. "Custom").
        var selectable: Bool = true
        /// Optional explanation, shown in a **popover on click** while this segment is not the active
        /// one — e.g. the "Custom" indicator explains how to reach it while some preset is active.
        var inactiveHelp: String? = nil
        var id: Value { value }
    }

    let segments: [Segment]
    /// The currently active segment (highlighted). May be an unselectable one.
    let active: Value
    /// Called when the user taps a **selectable** segment.
    let onSelect: (Value) -> Void

    /// Which segment's `inactiveHelp` popover is open (by value), or nil.
    @State private var helpShownFor: Value?

    /// Whether the control is interactive — `.disabled(…)` from an enclosing view (#381).
    ///
    /// Read explicitly because this control paints its own colours: the active segment is a hard-coded
    /// accent fill with white text, and SwiftUI dims neither. Without this a disabled control would look
    /// exactly like a live one and only reveal itself by ignoring clicks — the worst of both.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isActive = segment.value == active
                // A real Button (not `.onTapGesture`) so a click lands on the FIRST press even when the
                // Settings window isn't yet key — a raw tap gesture would be swallowed by window
                // activation, which is what made the control need multiple clicks.
                Button {
                    if segment.selectable {
                        onSelect(segment.value)
                    } else if !isActive, segment.inactiveHelp != nil {
                        // Unselectable indicator (e.g. "Custom"): a click explains how to reach it.
                        helpShownFor = segment.value
                    }
                } label: {
                    Text(segment.title)
                        .font(.callout)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        // Active: accent fill + white text. Inactive: no fill, normal/dimmed text.
                        //
                        // Disabled keeps the *shape* — the highlight stays where it is, because a
                        // disabled control still has to report which value is in force (#381: under
                        // Pressure the row shows `Slow down`, which is what the bar actually draws). Only
                        // the ink drops: secondary text on a grey fill, so it reads as "this is the
                        // state, and you cannot change it here" rather than as an empty control.
                        .foregroundStyle(
                            isActive ? AnyShapeStyle(isEnabled ? Color.white : Color.secondary)
                                     : AnyShapeStyle(segment.selectable && isEnabled ? Color.primary : Color.secondary))
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isActive
                                      ? (isEnabled ? Color.accentColor
                                                   : Color(nsColor: .quaternaryLabelColor))
                                      : .clear)
                                .shadow(color: isActive && isEnabled ? .black.opacity(0.15) : .clear,
                                        radius: 0.5, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(
                    get: { helpShownFor == segment.value },
                    set: { if !$0 { helpShownFor = nil } })) {
                    if let help = segment.inactiveHelp {
                        // `.init(help)` forces the LocalizedStringKey initializer so inline markdown
                        // (`*italic*`) renders — used to italicise option-name/value references.
                        Text(.init(help))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)   // wrap, grow down
                            .multilineTextAlignment(.leading)
                            .frame(width: 220)
                            .padding(12)
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
        )
        .fixedSize()
    }
}
