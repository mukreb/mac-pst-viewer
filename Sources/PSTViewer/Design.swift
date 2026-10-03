import SwiftUI

// Native macOS 26 ("Liquid Glass") styling where available, with the closest classic look as fallback.
// The macOS 26 APIs only exist in the macOS 26 SDK (Swift 6.2+), hence the compiler check on top
// of the run-time availability check: older Xcode versions still build the classic look.

extension View {
    #if compiler(>=6.2)
    /// A floating panel: Liquid Glass on macOS 26, a material background before.
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Glass buttons on macOS 26, bordered buttons before.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
    #else
    func glassPanel<S: Shape>(in shape: S) -> some View {
        self.background(.regularMaterial, in: shape)
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
    }
    #endif
}

enum Corner {
    /// macOS 26 uses larger, continuous corner radii than earlier versions.
    static let panel: CGFloat = 18
    static let card: CGFloat = 14
}
