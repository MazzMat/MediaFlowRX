import SwiftUI

/// The CEA-608 screen over the video: a grid of 15 rows by 32 columns inside the caption safe
/// area, 80% of a 4:3 picture centered on the video, as a television draws it.
struct CaptionOverlay: View {
    let screen: CaptionScreen
    /// Pixel size of the video, to find where the preview draws it. Zero when not known yet.
    let videoSize: CGSize
    /// Text size relative to the television grid. The rows in use grow in place, move back inside
    /// the picture when they would leave it, and shrink only when they cannot fit at all.
    var scale: Double = 1
    var backgroundOpacity: Double = 0.8

    var body: some View {
        GeometryReader { proxy in
            let picture = Self.pictureRect(in: proxy.size, video: videoSize)
            let area = Self.captionArea(in: picture)
            let rowHeight = area.height / CGFloat(CaptionScreen.rows)
            let cell = area.width / CGFloat(CaptionScreen.columns)
            // A monospaced glyph is about 0.6 of the font size wide.
            let base = min(rowHeight * 0.82, cell / 0.6)
            let layout = Self.layout(of: screen, scale: scale, area: area, picture: picture, rowHeight: rowHeight, cell: cell, pad: base * 0.25)
            let size = base * layout.scale
            let pad = size * 0.25
            ZStack(alignment: .topLeading) {
                ForEach(screen.rows) { row in
                    Text(Self.text(of: row, size: size))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, pad)
                        .frame(height: rowHeight * layout.scale)
                        .background(Color.black.opacity(backgroundOpacity))
                        .offset(
                            x: layout.x(CGFloat(row.column) * cell) - pad,
                            y: layout.y(CGFloat(row.row) * rowHeight)
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(screen.rows.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n"))
    }

    /// Where the preview draws the video: aspect fit, centered.
    static func pictureRect(in container: CGSize, video: CGSize) -> CGRect {
        let source = video.width > 0 && video.height > 0 ? video : CGSize(width: 16, height: 9)
        let fit = min(container.width / source.width, container.height / source.height)
        let size = CGSize(width: source.width * fit, height: source.height * fit)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func captionArea(in picture: CGRect) -> CGRect {
        let width = min(picture.width, picture.height * 4 / 3) * 0.8
        let height = picture.height * 0.8
        return CGRect(x: picture.midX - width / 2, y: picture.midY - height / 2, width: width, height: height)
    }

    /// Maps grid offsets to the view, scaled around the center of the safe area.
    struct Layout {
        var scale: CGFloat
        var origin: CGPoint
        var center: CGPoint
        var shift: CGSize

        func x(_ offset: CGFloat) -> CGFloat { center.x + (origin.x + offset - center.x) * scale + shift.width }
        func y(_ offset: CGFloat) -> CGFloat { center.y + (origin.y + offset - center.y) * scale + shift.height }
    }

    static func layout(of screen: CaptionScreen, scale: Double, area: CGRect, picture: CGRect, rowHeight: CGFloat, cell: CGFloat, pad: CGFloat) -> Layout {
        var layout = Layout(scale: CGFloat(scale), origin: area.origin, center: CGPoint(x: area.midX, y: area.midY), shift: .zero)
        guard let top = screen.rows.map(\.row).min(), let bottom = screen.rows.map(\.row).max(),
              let left = screen.rows.map(\.column).min(),
              let right = screen.rows.map({ $0.column + $0.text.count }).max() else { return layout }
        let blockHeight = CGFloat(bottom - top + 1) * rowHeight
        let blockWidth = CGFloat(right - left) * cell + pad * 2
        // The text grows or shrinks in place, around the center of the rows in use.
        layout.center = CGPoint(
            x: area.minX + CGFloat(left + right) / 2 * cell,
            y: area.minY + CGFloat(top + bottom + 1) / 2 * rowHeight
        )
        guard scale > 1 else { return layout }
        layout.scale = min(layout.scale, picture.height / blockHeight, picture.width / blockWidth)
        let minY = layout.y(CGFloat(top) * rowHeight)
        let maxY = layout.y(CGFloat(bottom + 1) * rowHeight)
        let minX = layout.x(CGFloat(left) * cell) - pad * layout.scale
        let maxX = layout.x(CGFloat(right) * cell) + pad * layout.scale
        layout.shift.height = minY < picture.minY ? picture.minY - minY : min(0, picture.maxY - maxY)
        layout.shift.width = minX < picture.minX ? picture.minX - minX : min(0, picture.maxX - maxX)
        return layout
    }

    private static func text(of row: CaptionScreen.Row, size: CGFloat) -> AttributedString {
        let font = Font.system(size: size, weight: .medium, design: .monospaced)
        var out = AttributedString()
        for run in row.runs {
            var part = AttributedString(run.text)
            part.font = run.italic ? font.italic() : font
            part.foregroundColor = color(run.color)
            if run.underline { part.underlineStyle = .single }
            out += part
        }
        return out
    }

    private static func color(_ value: CaptionScreen.Color) -> Color {
        switch value {
        case .white: .white
        case .green: .green
        case .blue: Color(red: 0.35, green: 0.55, blue: 1)
        case .cyan: .cyan
        case .red: .red
        case .yellow: .yellow
        case .magenta: Color(red: 1, green: 0.3, blue: 1)
        }
    }
}
