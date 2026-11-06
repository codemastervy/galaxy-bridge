import Foundation
import CoreLocation
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
    @Published var lastWorkout: String?

    private let store = HKHealthStore()

    private static func type(for kind: SampleKind) -> HKQuantityType {
        switch kind {
        case .heartRate: return HKQuantityType(.heartRate)
        case .steps: return HKQuantityType(.stepCount)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .distance: return HKQuantityType(.distanceWalkingRunning)
        case .floors: return HKQuantityType(.flightsClimbed)
        }
    }

    private static func unit(for kind: SampleKind) -> HKUnit {
        switch kind {
        case .heartRate: return .count().unitDivided(by: .minute())
        case .steps: return .count()
        case .activeEnergy: return .kilocalorie()
        case .distance: return .meter()
        case .floors: return .count()
        }
    }

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Apple Health isn't available on this device"
            return
        }
        // Write-only: this app never reads anyone's existing health data.
        var types: Set<HKSampleType> = Set(SampleKind.allCases.map(Self.type(for:)))
        types.insert(HKObjectType.workoutType())
        types.insert(HKSeriesType.workoutRoute())
        do {
            try await store.requestAuthorization(toShare: types, read: [])
            authorized = SampleKind.allCases.allSatisfy {
                store.authorizationStatus(for: Self.type(for: $0)) == .sharingAuthorized
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns true once the batch is settled: every sample is stored, or belongs to a type the
    /// user chose not to share. Returns false (so the watch keeps it) if Health hasn't been set up.
    func save(batchId: String, _ items: [HealthSample]) async -> Bool {
        let device = HKDevice(name: "Galaxy Watch", manufacturer: "Samsung", model: nil,
                              hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                              localIdentifier: nil, udiDeviceIdentifier: nil)
        var samples: [HKQuantitySample] = []
        for item in items {
            let type = Self.type(for: item.kind)
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized: break
            case .sharingDenied: continue // The user's choice; drop rather than retry forever.
            default:
                lastError = "Allow Wear OS Bridge to write to Apple Health"
                return false
            }
            samples.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: Self.unit(for: item.kind), doubleValue: item.value),
                start: item.startDate,
                end: item.endDate,
                device: device,
                metadata: [
                    HKMetadataKeySyncIdentifier: "gb-\(item.kind.rawValue)-\(item.start)-\(item.end)",
                    HKMetadataKeySyncVersion: 1,
                ]))
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

// MARK: Workouts

extension HealthSync {
    /// Saves a workout recorded on the watch, with its GPS route. Heart rate, energy and distance
    /// during the workout already arrive through the normal sync, so the workout carries only
    /// its totals (adding samples here would count them twice). Idempotent by workout id.
    func saveWorkout(_ w: [String: Any]) async -> Bool {
        guard let id = w["id"] as? String, UUID(uuidString: id) != nil,
              let start = (w["start"] as? NSNumber)?.int64Value, let end = (w["end"] as? NSNumber)?.int64Value,
              end > start, end - start < 24 * 3600 * 1000 else { return true } // malformed: drop it
        let kind = w["kind"] as? String ?? "other"
        let kcal = min(max((w["kcal"] as? NSNumber)?.doubleValue ?? 0, 0), 20_000)
        let dist = min(max((w["dist"] as? NSNumber)?.doubleValue ?? 0, 0), 500_000)
        let type: HKWorkoutActivityType = switch kind {
        case "run": .running
        case "walk": .walking
        case "cycle": .cycling
        case "hike": .hiking
        default: .other
        }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
            lastError = "Allow Wear OS Bridge to save workouts in Apple Health"
            return false
        }
        let startDate = Date(timeIntervalSince1970: Double(start) / 1000)
        let endDate = Date(timeIntervalSince1970: Double(end) / 1000)
        let device = HKDevice(name: "Galaxy Watch", manufacturer: "Samsung", model: nil, hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        let metadata: [String: Any] = [HKMetadataKeySyncIdentifier: "gb-workout-\(id)", HKMetadataKeySyncVersion: 1]
        let workout = HKWorkout(activityType: type, start: startDate, end: endDate, duration: endDate.timeIntervalSince(startDate),
                                totalEnergyBurned: kcal > 0 ? HKQuantity(unit: .kilocalorie(), doubleValue: kcal) : nil,
                                totalDistance: dist > 0 ? HKQuantity(unit: .meter(), doubleValue: dist) : nil,
                                device: device, metadata: metadata)
        do {
            try await store.save(workout)
            let points = (w["route"] as? [[NSNumber]] ?? []).compactMap { p -> CLLocation? in
                guard p.count >= 3 else { return nil }
                let lat = p[1].doubleValue, lon = p[2].doubleValue
                guard (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
                return CLLocation(coordinate: .init(latitude: lat, longitude: lon),
                                  altitude: p.count > 3 ? p[3].doubleValue : 0, horizontalAccuracy: 10, verticalAccuracy: 15,
                                  timestamp: Date(timeIntervalSince1970: p[0].doubleValue / 1000))
            }
            if !points.isEmpty, store.authorizationStatus(for: HKSeriesType.workoutRoute()) == .sharingAuthorized {
                let route = HKWorkoutRouteBuilder(healthStore: store, device: device)
                try await route.insertRouteData(points)
                _ = try await route.finishRoute(with: workout, metadata: nil)
            }
            lastWorkout = workout.workoutActivityType == .other ? "Workout" : kind.capitalized
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
            case .floors: break
            default: break
            }
        }
    }
}
