import AppKit
import SwiftUI

/// Shared shape language: one outer radius for the panel, inner cards concentric
/// with it (inner radius = outer radius - padding), continuous corners like macOS.
enum Shape {
    static let panelRadius: CGFloat = 26
    static let panelPadding: CGFloat = 14
    static let cardRadius: CGFloat = panelRadius - panelPadding  // 12
    static let cardPadding: CGFloat = 12
    /// Extra space under the footer, clear of the bottom corners.
    static let footerInset: CGFloat = 8

    static func card() -> RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
}

/// Rounds the menu bar panel itself. MenuBarExtra gives no API for its window,
/// so this reaches it once the view is on screen.
struct PanelChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { style(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { style(view.window) }
    }

    private func style(_ window: NSWindow?) {
        guard let window, let content = window.contentView else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        content.wantsLayer = true
        content.layer?.cornerRadius = Shape.panelRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        window.hasShadow = true
        fit(window, content)
        window.invalidateShadow()
    }

    /// MenuBarExtra sizes its window once, when it first shows. Lines that
    /// appear later (running AI clients, warnings, the time zone hint) then
    /// spill past the bottom corners and hide the footer. Follow the content's
    /// height, keeping the top edge under the menu bar.
    private func fit(_ window: NSWindow, _ content: NSView) {
        content.layoutSubtreeIfNeeded()
        let want = content.fittingSize.height
        guard want > 1, abs(window.frame.height - want) > 0.5 else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = want
        frame.origin.y = top - want
        window.setFrame(frame, display: true)
    }
}

/// The panel's room below the menu bar, so a tall panel scrolls instead of
/// running off a small screen.
@MainActor
func panelMaxHeight() -> CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 800
    return max(320, screen - 16)
}

/// The on/off control: a large pill with a lock in the knob. Green and closed
/// lock when on, grey and open lock when off; a spinner while switching.
struct PowerSwitchStyle: ToggleStyle {
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(on
                          ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.20, green: 0.80, blue: 0.42),
                                                                  Color(red: 0.11, green: 0.62, blue: 0.32)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(0.14)))
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(on ? 0.12 : 0.06), lineWidth: 0.5))
                    .frame(width: 64, height: 34)
                ZStack {
                    Circle().fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1.5)
                    if busy {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: on ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(on ? Color(red: 0.11, green: 0.62, blue: 0.32) : Color.secondary)
                    }
                }
                .frame(width: 28, height: 28)
                .padding(3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Tunlock"))
        .accessibilityValue(Text(on ? L("On", "Включён") : L("Off", "Выключен")))
        .accessibilityAddTraits(.isButton)
    }
}
