import Foundation
import HealthKit
import WearLink

/// Writes watch samples into Apple Health. Writes are idempotent: each sample carries a
/// sync identifier, so a batch re-sent after a lost ack replaces rather than duplicates.
@MainActor
final class HealthSync: ObservableObject {
    @Published private(set) var authorized = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var savedCount = 0
    @Published private(set) var lastError: String?
    /// Summary for the dashboard only (Apple Health remains the source of truth).
    @Published private(set) var summary = DaySummary.load()

    private let store = HKHealthStore()

    private static func type(for kind: SampleKind) -> HKQuantityType {
        switch kind {
        case .heartRate: return HKQuantityType(.heartRate)
        case .steps: return HKQuantityType(.stepCount)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        }
    }

    private static func unit(for kind: SampleKind) -> HKUnit {
        switch kind {
        case .heartRate: return .count().unitDivided(by: .minute())
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .distance: return .meter()
        }
    }

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Apple Health isn't available on this device"
            return
        }
        // Write-only: this app never reads anyone's existing health data.
        let types = Set(SampleKind.allCases.map(Self.type(for:)))
        do {
            try await store.requestAuthorization(toShare: types, read: [])
            authorized = SampleKind.allCases.allSatisfy {
                store.authorizationStatus(for: Self.type(for: $0)) == .sharingAuthorized
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns true only when every sample in the batch was stored.
    func save(batchId: String, _ items: [HealthSample]) async -> Bool {
        let device = HKDevice(name: "Galaxy Watch", manufacturer: "Samsung", model: nil,
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        let samples = items.compactMap { item -> HKQuantitySample? in
            let type = Self.type(for: item.kind)
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
            return HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: Self.unit(for: item.kind), doubleValue: item.value),
                start: item.startDate,
                end: item.endDate,
                device: device,
                metadata: [
                    HKMetadataKeySyncIdentifier: "gb-\(item.kind.rawValue)-\(item.start)-\(item.end)",
                    HKMetadataKeySyncVersion: 1,
                ])
        }
        guard samples.count == items.count else {
            lastError = "Allow Galaxy Bridge to write to Apple Health in Settings → Health"
            return false
        }
        if samples.isEmpty { return true }
        do {
            try await store.save(samples)
            summary.add(batchId: batchId, items)
            summary.save()
            savedCount += samples.count
            lastSync = Date()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

/// Today's totals and the latest heart rate, kept small and on-device.
/// Remembers recent batch IDs so a batch re-sent after a lost ack isn't counted twice.
struct DaySummary: Codable, Equatable {
    var day: String
    var heartRate: Double?
    var heartRateAt: Date?
    var steps: Double = 0
    var distance: Double = 0
    var energy: Double = 0
    var countedBatches: [String] = []

    private static let key = "daySummary"

    static func today() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    static func load() -> DaySummary {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(DaySummary.self, from: data) {
            return s.rolled()
        }
        return DaySummary(day: today())
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Keeps the last heart rate but resets daily totals at midnight.
    func rolled() -> DaySummary {
        guard day != Self.today() else { return self }
        var fresh = DaySummary(day: Self.today())
        fresh.heartRate = heartRate
        fresh.heartRateAt = heartRateAt
        fresh.countedBatches = countedBatches
        return fresh
    }

    mutating func add(batchId: String, _ items: [HealthSample]) {
        self = rolled()
        guard !countedBatches.contains(batchId) else { return }
        countedBatches.append(batchId)
        if countedBatches.count > 500 { countedBatches.removeFirst(countedBatches.count - 500) }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        for item in items {
            switch item.kind {
            case .heartRate:
                if heartRateAt.map({ item.endDate > $0 }) ?? true {
                    heartRate = item.value
                    heartRateAt = item.endDate
                }
            case .steps where item.startDate >= startOfDay: steps += item.value
            case .distance where item.startDate >= startOfDay: distance += item.value
            case .activeEnergy where item.startDate >= startOfDay: energy += item.value
            default: break
            }
        }
    }
}
