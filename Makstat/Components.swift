import SwiftUI

struct StatSection<Content: View>: View {
    let title: String
    var trailing: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            content
        }
    }
}

/// Horizontal bar made of coloured segments (fractions of the full width).
struct SegmentBar: View {
    var segments: [(Double, Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: max(0, geo.size.width * min(1, max(0, seg.0))))
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    var values: [Double]   // 0...100
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(values.count, 2)
            let step = w / CGFloat(Monitor.historyLength - 1)
            let start = w - step * CGFloat(n - 1)
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = start + step * CGFloat(i)
                    let y = h - h * CGFloat(min(100, max(0, v)) / 100)
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, lineWidth: 1.2)
            Path { p in
                guard !values.isEmpty else { return }
                p.move(to: CGPoint(x: start, y: h))
                for (i, v) in values.enumerated() {
                    p.addLine(to: CGPoint(x: start + step * CGFloat(i), y: h - h * CGFloat(min(100, max(0, v)) / 100)))
                }
                p.addLine(to: CGPoint(x: start + step * CGFloat(values.count - 1), y: h))
                p.closeSubpath()
            }
            .fill(color.opacity(0.15))
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct Stat: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption).lineLimit(1).fixedSize()
    }
}

extension Color {
    static let cpuUser = Color.accentColor
    static let cpuSystem = Color.orange
    static let memApp = Color.accentColor
    static let memWired = Color.purple
    static let memCompressed = Color.orange
    static let diskUsed = Color.teal

    static func usage(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.7 ? .orange : .accentColor
    }
}
