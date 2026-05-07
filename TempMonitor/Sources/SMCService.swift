import Foundation
import IOKit

// MARK: - SMC Data Structures (must match AppleSMC kernel driver layout, 80 bytes total)

struct SMCKeyData {
    typealias SMCBytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers: Vers = Vers()
    var pLimitData: PLimitData = PLimitData()
    var keyInfo: KeyInfo = KeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMC Service

class SMCService {
    private var connection: io_connect_t = 0

    // SMC command selectors
    private static let kSMCGetKeyInfo: UInt8 = 9
    private static let kSMCReadKey: UInt8 = 5

    // Temperature keys to try (Intel + Apple Silicon)
    private static let cpuTempKeys = [
        "TC0P", "TC0D", "TC0E", "TC0F",           // Intel
        "Tp09", "Tp01", "Tp05", "Tp0D", "Tp0T",   // Apple Silicon P-cores
        "Tp0j", "Tp0n",                             // M3/M4
    ]
    private static let gpuTempKeys = [
        "TG0P", "TG0D", "TG0E",                    // Intel
        "Tg05", "Tg0D", "Tg0f", "Tg0j",           // Apple Silicon
    ]

    private(set) var cpuKey: String?
    private(set) var gpuKey: String?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else {
            print("[SMC] AppleSMC service not found")
            return nil
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard result == kIOReturnSuccess else {
            print("[SMC] Failed to open connection: \(result)")
            return nil
        }

        print("[SMC] Connected. SMCKeyData size: \(MemoryLayout<SMCKeyData>.size) (expected 80)")
        detectWorkingKeys()
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Public API

    func getCPUTemperature() -> Double? {
        guard let key = cpuKey else { return nil }
        return readTemperature(key: key)
    }

    func getGPUTemperature() -> Double? {
        guard let key = gpuKey else { return nil }
        return readTemperature(key: key)
    }

    func getFanCount() -> Int {
        guard let value = readRawValue(key: "FNum") else { return 0 }
        return Int(value)
    }

    func getFanRPM(index: Int) -> Int {
        let key = "F\(index)Ac"
        guard let value = readRawValue(key: key) else { return 0 }
        return Int(value)
    }

    func getFanMaxRPM(index: Int) -> Int {
        let key = "F\(index)Mx"
        guard let value = readRawValue(key: key) else { return 0 }
        return Int(value)
    }

    // MARK: - Key Detection

    private func detectWorkingKeys() {
        for key in SMCService.cpuTempKeys {
            if let temp = readTemperature(key: key), temp > 0, temp < 130 {
                cpuKey = key
                print("[SMC] CPU temp key: \(key) (\(temp)°C)")
                break
            }
        }

        for key in SMCService.gpuTempKeys {
            if let temp = readTemperature(key: key), temp > 0, temp < 130 {
                gpuKey = key
                print("[SMC] GPU temp key: \(key) (\(temp)°C)")
                break
            }
        }

        if cpuKey == nil {
            print("[SMC] Warning: no CPU temperature key found")
        }
        if gpuKey == nil {
            print("[SMC] Warning: no GPU temperature key found")
        }
    }

    // MARK: - SMC Reading

    private func readTemperature(key: String) -> Double? {
        return readRawValue(key: key)
    }

    private func readRawValue(key: String) -> Double? {
        // Step 1: Get key info (data type and size)
        var input = SMCKeyData()
        var output = SMCKeyData()

        input.key = fourCharCode(key)
        input.data8 = SMCService.kSMCGetKeyInfo

        guard callSMC(&input, &output) else { return nil }

        let dataType = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize

        // Step 2: Read the value
        input = SMCKeyData()
        output = SMCKeyData()

        input.key = fourCharCode(key)
        input.keyInfo.dataSize = dataSize
        input.data8 = SMCService.kSMCReadKey

        guard callSMC(&input, &output) else { return nil }

        // Step 3: Parse based on data type
        return parseValue(bytes: output.bytes, type: dataType, size: dataSize)
    }

    private func callSMC(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let result = IOConnectCallStructMethod(
            connection,
            2, // KERNEL_INDEX_SMC
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )

        return result == kIOReturnSuccess
    }

    // MARK: - Value Parsing

    private func parseValue(bytes: SMCKeyData.SMCBytes, type: UInt32, size: UInt32) -> Double? {
        let raw = extractBytes(bytes, count: Int(size))
        let typeStr = fourCharCodeToString(type)

        switch typeStr {
        case "flt ":
            // 32-bit IEEE float (big-endian) — common on Apple Silicon
            guard raw.count >= 4 else { return nil }
            let bits = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
            let value = Double(Float(bitPattern: bits))
            guard value > -50 && value < 200 else { return nil }
            return value

        case "sp78":
            // Signed fixed-point 7.8 — common on Intel
            guard raw.count >= 2 else { return nil }
            let value = Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1]))
            return Double(value) / 256.0

        case "sp87":
            guard raw.count >= 2 else { return nil }
            let value = Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1]))
            return Double(value) / 128.0

        case "fpe2":
            // Unsigned fixed-point 14.2 — common for fan speed
            guard raw.count >= 2 else { return nil }
            let value = UInt16(raw[0]) << 8 | UInt16(raw[1])
            return Double(value) / 4.0

        case "ui8 ":
            guard raw.count >= 1 else { return nil }
            return Double(raw[0])

        case "ui16":
            guard raw.count >= 2 else { return nil }
            return Double(UInt16(raw[0]) << 8 | UInt16(raw[1]))

        case "ui32":
            guard raw.count >= 4 else { return nil }
            let v = UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3])
            return Double(v)

        default:
            print("[SMC] Unknown data type: \(typeStr)")
            return nil
        }
    }

    // MARK: - Helpers

    private func fourCharCode(_ key: String) -> UInt32 {
        var code: UInt32 = 0
        for byte in key.utf8.prefix(4) {
            code = (code << 8) | UInt32(byte)
        }
        return code
    }

    private func fourCharCodeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func extractBytes(_ bytes: SMCKeyData.SMCBytes, count: Int) -> [UInt8] {
        withUnsafePointer(to: bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { bytePtr in
                Array(UnsafeBufferPointer(start: bytePtr, count: min(count, 32)))
            }
        }
    }
}
