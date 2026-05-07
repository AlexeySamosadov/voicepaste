import Foundation
import Combine

struct TempSample: Identifiable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    let date: Date
    let value: Double
}

class TemperatureStore: ObservableObject {
    @Published var cpuTemperature: Double = 0
    @Published var gpuTemperature: Double = 0
    @Published var cpuHistory: [TempSample] = []
    @Published var gpuHistory: [TempSample] = []
    @Published var fanRPM: Int = 0
    @Published var fanMaxRPM: Int = 6000
    @Published var fanCount: Int = 0
    @Published var smcAvailable: Bool = false

    private var smc: SMCService?
    private var timer: Timer?
    private let historyWindow: TimeInterval = 300 // 5 minutes

    init() {
        smc = SMCService()
        smcAvailable = smc != nil
    }

    func start() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func update() {
        guard let smc = smc else { return }

        let now = Date()

        if let cpu = smc.getCPUTemperature() {
            cpuTemperature = cpu
            cpuHistory.append(TempSample(date: now, value: cpu))
        }

        if let gpu = smc.getGPUTemperature() {
            gpuTemperature = gpu
            gpuHistory.append(TempSample(date: now, value: gpu))
        }

        // Trim old history
        let cutoff = now.addingTimeInterval(-historyWindow)
        cpuHistory.removeAll { $0.date < cutoff }
        gpuHistory.removeAll { $0.date < cutoff }

        // Fan info
        fanCount = smc.getFanCount()
        if fanCount > 0 {
            fanRPM = smc.getFanRPM(index: 0)
            fanMaxRPM = max(smc.getFanMaxRPM(index: 0), 1)
        }
    }
}
