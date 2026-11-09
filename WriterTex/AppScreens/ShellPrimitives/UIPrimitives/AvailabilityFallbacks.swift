//
//  AvailabilityFallbacks.swift
//  WriterTex
//

import SwiftUI

/// macOS 26 modifiers with macOS 15 stand-ins, so call sites stay one line.
/// Liquid Glass falls back to materials and bordered buttons; scroll-edge
/// effects and drag-container selection have no older equivalent and are skipped.
extension View {
    /// `glassEffect(.regular, in:)`, or a regular material in the same shape.
    @ViewBuilder
    func glassOrMaterial(in shape: some Shape) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    /// `glassEffect()` with its default capsule, or a regular material capsule.
    @ViewBuilder
    func glassOrMaterial() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect()
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// `.glass` / `.glassProminent`, or `.bordered` / `.borderedProminent`.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// A soft scroll-edge effect; older systems draw no edge effect at all.
    @ViewBuilder
    func softScrollEdge(for edges: Edge.Set) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }

    /// `safeAreaBar`, or `safeAreaInset`. Both inset the safe area by the
    /// bar's height, which `FileViewer` reads to pad the editor's last line.
    @ViewBuilder
    func safeAreaBarOrInset<V: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> V
    ) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: edge, alignment: alignment, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: edge, alignment: alignment, spacing: spacing, content: content)
        }
    }

    /// `dragContainerSelection`, or nothing: older systems drag one item at a time.
    @ViewBuilder
    func dragContainerSelectionIfAvailable<ItemID: Hashable & Sendable>(
        _ selection: @autoclosure @escaping () -> [ItemID]
    ) -> some View {
        if #available(macOS 26.0, *) {
            dragContainerSelection(selection())
        } else {
            self
        }
    }
}
