import SwiftUI

// MARK: - Shared radio button

struct RadioButton: View {
    let isOn: Bool
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "circle.inset.filled" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(label)
                    .foregroundStyle(disabled ? Color.secondary : Color.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

extension View {
    func instantTooltip(_ text: String, maxWidth: CGFloat = 240) -> some View {
        self.modifier(InstantTooltipModifier(label: Text(text), maxWidth: maxWidth))
    }

    func instantTooltip(_ text: AttributedString, maxWidth: CGFloat = 240) -> some View {
        self.modifier(InstantTooltipModifier(label: Text(text), maxWidth: maxWidth))
    }

    /// Clamps a `String` binding to `limit` Characters (grapheme clusters) on change.
    /// Use on text inputs that drive persisted names so over-long entries are truncated
    /// at the source rather than stored and re-truncated everywhere they're displayed.
    func maxLength(_ binding: Binding<String>, _ limit: Int) -> some View {
        self.onChange(of: binding.wrappedValue) { _, new in
            if new.count > limit { binding.wrappedValue = String(new.prefix(limit)) }
        }
    }
}

private struct InstantTooltipModifier: ViewModifier {
    let label: Text
    let maxWidth: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .popover(isPresented: $isHovering, arrowEdge: .bottom) {
                label
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .interactiveDismissDisabled()
            }
    }
}
