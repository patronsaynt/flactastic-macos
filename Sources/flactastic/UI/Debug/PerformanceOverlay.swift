import SwiftUI
import Darwin

/// Settings → Debug → "Performance overlay": frames per second, the worst
/// frame time in the last second, and the app's memory, in the window's
/// bottom-left corner.
///
/// Measures the frames SwiftUI's animation timeline actually delivers, so a
/// hitch anywhere in the window shows up here as a long frame. The overlay
/// itself redraws every frame, which costs a little; it's off unless asked.
struct PerformanceOverlay: View {
    @State private var meter = FrameMeter()

    var body: some View {
        TimelineView(.animation) { context in
            let stats = meter.record(context.date)
            HStack(spacing: 12) {
                Text("\(stats.fps) fps")
                    .foregroundStyle(stats.fps >= 55 ? Color(red: 0.62, green: 0.94, blue: 0.65) : .orange)
                Text(String(format: "worst %.1f ms", stats.worstFrameMs))
                    .foregroundStyle(stats.worstFrameMs > 25 ? .orange : Color(white: 0.8))
                Text(stats.memory)
                    .foregroundStyle(Color(white: 0.8))
            }
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Frame timestamps over the last second, plus a memory reading refreshed
/// once a second. A class so recording a frame doesn't itself invalidate
/// the view.
private final class FrameMeter {
    struct Stats {
        var fps = 0
        var worstFrameMs = 0.0
        var memory = "—"
    }

    private var frames: [Date] = []
    private var stats = Stats()
    private var lastSummary = Date.distantPast

    func record(_ date: Date) -> Stats {
        frames.append(date)
        frames.removeAll { date.timeIntervalSince($0) > 1 }
        guard date.timeIntervalSince(lastSummary) >= 0.5 else { return stats }
        lastSummary = date
        var worst = 0.0
        for (a, b) in zip(frames, frames.dropFirst()) {
            worst = max(worst, b.timeIntervalSince(a))
        }
        stats = Stats(fps: frames.count, worstFrameMs: worst * 1000, memory: Self.residentMemory())
        return stats
    }

    private static func residentMemory() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
    }
}
