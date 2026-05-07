import SwiftUI
import Charts

// MARK: - Main Popover View

struct PopoverView: View {
    @ObservedObject var store: TemperatureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !store.smcAvailable {
                Label("SMC not available", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.secondary)
            } else {
                // Temperature rows
                TempRow(label: "CPU", temp: store.cpuTemperature)
                TempRow(label: "GPU", temp: store.gpuTemperature)

                // Chart
                if !store.cpuHistory.isEmpty || !store.gpuHistory.isEmpty {
                    chartSection
                }

                // Fan
                if store.fanCount > 0 {
                    Divider()
                    fanSection
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.primary)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Chart

    private var chartSection: some View {
        VStack(spacing: 6) {
            chartView
                .frame(height: 160)

            // Legend
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(.blue).frame(width: 8, height: 8)
                    Text("CPU").font(.caption)
                }
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("GPU").font(.caption)
                }
                Spacer()
                Text("5 min")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var chartView: some View {
        Chart {
            ForEach(store.cpuHistory) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("°C", sample.value)
                )
                .foregroundStyle(by: .value("Sensor", "CPU"))
                .interpolationMethod(.catmullRom)
            }
            ForEach(store.gpuHistory) { sample in
                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("°C", sample.value)
                )
                .foregroundStyle(by: .value("Sensor", "GPU"))
                .interpolationMethod(.catmullRom)
            }
        }
        .chartForegroundStyleScale(["CPU": Color.blue, "GPU": Color.orange])
        .chartYScale(domain: yAxisRange)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let temp = value.as(Double.self) {
                        Text("\(Int(temp))°")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }

    private var yAxisRange: ClosedRange<Double> {
        let all = store.cpuHistory.map(\.value) + store.gpuHistory.map(\.value)
        guard let minVal = all.min(), let maxVal = all.max() else {
            return 30...100
        }
        let lower = floor((minVal - 5) / 10) * 10
        let upper = ceil((maxVal + 5) / 10) * 10
        return max(lower, 0)...min(upper, 120)
    }

    // MARK: - Fan

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundColor(.blue)
                Text("Fan")
                    .font(.system(.body, weight: .medium))
                Spacer()
                Text("\(store.fanRPM) RPM")
                    .font(.system(.body, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.blue)
            }
            ProgressView(value: Double(store.fanRPM), total: Double(store.fanMaxRPM))
                .tint(.blue)
        }
    }
}

// MARK: - Temperature Row

struct TempRow: View {
    let label: String
    let temp: Double

    private var barColor: Color {
        if temp < 50 { return .green }
        if temp < 65 { return .yellow }
        if temp < 80 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(.title3, weight: .medium))
                    .frame(width: 44, alignment: .leading)
                Text(temp > 0 ? String(format: "%.0f°C", temp) : "—")
                    .font(.system(.title3, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(barColor)
                            .frame(width: geo.size.width * CGFloat(min(max(temp, 0), 110) / 110.0))
                    }
                }
                .frame(height: 16)
            }
        }
    }
}
