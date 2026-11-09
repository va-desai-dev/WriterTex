//
//  NSColor+Hex.swift
//  WriterTex
//

import AppKit

extension NSColor {

    /// Builds a color from a hex color code, for pasting swatches straight
    /// out of Xcode's color picker or a published theme.
    ///
    /// Accepts `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`; the leading `#` is
    /// optional. The components are sRGB, which is what Xcode's picker,
    /// `.xccolortheme` files, and every web tool mean by a hex triplet.
    ///
    /// Traps on a malformed code instead of silently substituting a default, so
    /// a typo surfaces the first time the theme is built. Only use this for
    /// literals compiled into the app; codes read back from user defaults go
    /// through `sRGB(colorCode:)`, which returns nil instead.
    ///
    /// - Parameters:
    ///   - colorCode: The color code to parse.
    ///   - alpha: An opacity to apply on top of the parsed color.
    static func hex(_ colorCode: String, alpha: CGFloat = 1) -> NSColor {
        guard let color = sRGB(colorCode: colorCode, alpha: alpha) else {
            preconditionFailure("Invalid color code “\(colorCode)” in the WriterTex theme.")
        }
        return color
    }

    /// The non-trapping form of `hex(_:alpha:)`, for codes read back from user
    /// defaults, where a bad value should fall back rather than crash.
    static func sRGB(colorCode: String, alpha: CGFloat = 1) -> NSColor? {
        var digits = colorCode.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        // Short forms repeat each digit: #F80 is #FF8800.
        if digits.count == 3 || digits.count == 4 {
            digits = String(digits.flatMap { [$0, $0] })
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }

        let hasAlpha = digits.count == 8
        func component(_ shift: UInt64) -> CGFloat {
            CGFloat((value >> shift) & 0xFF) / 255
        }
        return NSColor(srgbRed: component(hasAlpha ? 24 : 16),
                       green: component(hasAlpha ? 16 : 8),
                       blue: component(hasAlpha ? 8 : 0),
                       alpha: (hasAlpha ? component(0) : 1) * alpha)
    }

    /// This color as an sRGB `#RRGGBBAA` code — the inverse of
    /// `sRGB(colorCode:)`, used to store theme overrides.
    var sRGBColorCode: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        // Extended-range components can fall outside 0...1; clamp before encoding.
        return "#" + components
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
