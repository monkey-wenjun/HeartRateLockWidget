import WidgetKit
import SwiftUI

struct HeartRateEntry: TimelineEntry {
    let date: Date
    let heartRate: Int?
    let isConnected: Bool
    let lastUpdated: Date?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> HeartRateEntry {
        HeartRateEntry(date: Date(), heartRate: 72, isConnected: true, lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (HeartRateEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartRateEntry>) -> Void) {
        let entry = readEntry()
        // 每秒刷新一次，让小组件尽可能接近实时；系统实际刷新频率会受其调度限制
        let nextUpdate = Calendar.current.date(byAdding: .second, value: 1, to: entry.date) ?? entry.date.addingTimeInterval(1)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func readEntry() -> HeartRateEntry {
        let hr = SharedStore.object(forKey: SharedConfig.Keys.heartRate) as? Int
        let connected = SharedStore.bool(forKey: SharedConfig.Keys.isConnected)
        let updatedTimestamp = SharedStore.object(forKey: SharedConfig.Keys.lastUpdated) as? Double ?? 0
        let updated = updatedTimestamp > 0 ? Date(timeIntervalSince1970: updatedTimestamp) : nil
        return HeartRateEntry(
            date: Date(),
            heartRate: hr,
            isConnected: connected,
            lastUpdated: updated
        )
    }
}

struct HeartRateWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: entry.isConnected ? "heart.fill" : "heart.slash")
                    .foregroundColor(entry.isConnected ? .red : .gray)
                    .font(.title3)

                if let hr = entry.heartRate, entry.isConnected {
                    Text("\(hr)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                } else {
                    Text("--")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }

            if let updated = entry.lastUpdated, entry.isConnected {
                Text("更新于 \(timeString(from: updated))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("未连接手表")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct HeartRateWidget: Widget {
    let kind: String = "HeartRateWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HeartRateWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("实时心率")
        .description("展示华为手表心率广播数据，断开后自动锁屏。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if DEBUG
#Preview(as: .systemSmall) {
    HeartRateWidget()
} timeline: {
    HeartRateEntry(date: Date(), heartRate: 88, isConnected: true, lastUpdated: Date())
    HeartRateEntry(date: Date(), heartRate: nil, isConnected: false, lastUpdated: nil)
}
#endif
