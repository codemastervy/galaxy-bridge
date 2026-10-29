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
