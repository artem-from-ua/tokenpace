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
    /// Segment label font. Defaults to the size every other row on these pages uses; the Bar style row
    /// overrides it so its wording matches the picture-based picker of the same setting on the Menu bar
    /// page, which sets its captions smaller than body text.
    var titleFont: Font = .callout

    /// Which segment's `inactiveHelp` popover is open (by value), or nil.
    @State private var helpShownFor: Value?

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
                        .font(titleFont)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        // Active: accent fill + white text. Inactive: no fill, normal/dimmed text.
                        .foregroundStyle(isActive ? AnyShapeStyle(.white)
                                                  : AnyShapeStyle(segment.selectable ? Color.primary : Color.secondary))
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isActive ? Color.accentColor : .clear)
                                .shadow(color: isActive ? .black.opacity(0.15) : .clear, radius: 0.5, y: 0.5)
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
