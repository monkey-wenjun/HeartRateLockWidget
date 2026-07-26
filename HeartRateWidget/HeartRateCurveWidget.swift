import WidgetKit
import SwiftUI

struct HeartRateCurveEntry: TimelineEntry {
    let date: Date
    /// 最近 HeartRateHistory windowSeconds 内的样本，按时间升序
    let samples: [(date: Date, hr: Int)]
    let currentHeartRate: Int?
    let isConnected: Bool
}

struct CurveProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeartRateCurveEntry {
        let now = Date()
        let samples = (0..<60).map { i in
            (now.addingTimeInterval(Double(i - 60) * 10), 70 + Int(10 * sin(Double(i) / 6)))
        }
        return HeartRateCurveEntry(date: now, samples: samples, currentHeartRate: 75, isConnected: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (HeartRateCurveEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartRateCurveEntry>) -> Void) {
        let entry = readEntry()
        // 与实时心率小组件一致：每秒请求刷新，实际频率由系统调度
        let nextUpdate = entry.date.addingTimeInterval(1)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func readEntry() -> HeartRateCurveEntry {
        let hr = SharedStore.object(forKey: SharedConfig.Keys.heartRate) as? Int
        let connected = SharedStore.bool(forKey: SharedConfig.Keys.isConnected)
        return HeartRateCurveEntry(
            date: Date(),
            samples: SharedConfig.heartRateHistory(),
            currentHeartRate: hr,
            isConnected: connected
        )
    }
}

struct HeartRateCurveEntryView: View {
    var entry: CurveProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: entry.isConnected ? "heart.fill" : "heart.slash")
                    .foregroundColor(entry.isConnected ? .red : .gray)
                if let hr = entry.currentHeartRate, entry.isConnected {
                    Text("\(hr)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("--")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let range = hrRange {
                    Text("\(range.min)~\(range.max)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if entry.samples.count > 1 {
                CurveView(samples: entry.samples, windowEnd: entry.date)
            } else {
                Spacer()
                Text(entry.isConnected ? "等待心率数据…" : "未连接手表")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var hrRange: (min: Int, max: Int)? {
        guard let min = entry.samples.map(\.hr).min(),
              let max = entry.samples.map(\.hr).max() else { return nil }
        return (min, max)
    }
}

/// 心率曲线：X 轴为时间（铺满整个时间窗口），Y 轴为 BPM
private struct CurveView: View {
    let samples: [(date: Date, hr: Int)]
    let windowEnd: Date

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                curvePath(in: rect, closeToBottom: true)
                    .fill(LinearGradient(
                        colors: [.red.opacity(0.3), .red.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                curvePath(in: rect, closeToBottom: false)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func curvePath(in rect: CGRect, closeToBottom: Bool) -> Path {
        let windowStart = windowEnd.addingTimeInterval(-SharedConfig.History.windowSeconds)
        let hrs = samples.map { Double($0.hr) }
        let minHR = (hrs.min() ?? 60) - 5
        let maxHR = (hrs.max() ?? 100) + 5
        let hrSpan = max(maxHR - minHR, 1)
        let timeSpan = max(windowEnd.timeIntervalSince(windowStart), 1)

        func point(for sample: (date: Date, hr: Int)) -> CGPoint {
            let x = sample.date.timeIntervalSince(windowStart) / timeSpan * rect.width
            let y = (1 - (Double(sample.hr) - minHR) / hrSpan) * rect.height
            return CGPoint(x: min(max(x, 0), rect.width), y: min(max(y, 0), rect.height))
        }

        var path = Path()
        let points = samples.map(point)
        guard let first = points.first else { return path }
        if closeToBottom {
            path.move(to: CGPoint(x: first.x, y: rect.height))
            path.addLine(to: first)
        } else {
            path.move(to: first)
        }
        for p in points.dropFirst() {
            path.addLine(to: p)
        }
        if closeToBottom, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}

struct HeartRateCurveWidget: Widget {
    let kind: String = "HeartRateCurveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CurveProvider()) { entry in
            HeartRateCurveEntryView(entry: entry)
        }
        .configurationDisplayName("心率曲线")
        .description("展示最近 15 分钟的心率变化曲线。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if DEBUG
#Preview(as: .systemMedium) {
    HeartRateCurveWidget()
} timeline: {
    let now = Date()
    HeartRateCurveEntry(
        date: now,
        samples: (0..<90).map { i in (now.addingTimeInterval(Double(i - 90) * 10), 65 + Int(20 * abs(sin(Double(i) / 9)))) },
        currentHeartRate: 82,
        isConnected: true
    )
    HeartRateCurveEntry(date: now, samples: [], currentHeartRate: nil, isConnected: false)
}
#endif
