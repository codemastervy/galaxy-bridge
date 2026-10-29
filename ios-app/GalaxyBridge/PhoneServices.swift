import AudioToolbox
import CoreLocation
import EventKit
import Foundation
import UIKit
import UserNotifications
import WearLink

/// Things the iPhone shares with the watch: its battery, the weather, and today's calendar.
/// Each one is opt-in from the app's settings and only leaves the phone over the bonded link,
/// except weather, which asks Open-Meteo for a forecast at a rounded (~1 km) location.
@MainActor
final class PhoneServices: NSObject, ObservableObject {
    @Published var shareWeather = UserDefaults.standard.object(forKey: "shareWeather") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shareWeather, forKey: "shareWeather"); refresh() }
    }
    @Published var shareCalendar = UserDefaults.standard.object(forKey: "shareCalendar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(shareCalendar, forKey: "shareCalendar"); refresh() }
    }
    @Published private(set) var weather: WeatherReport?
    @Published private(set) var calendarAllowed = false
    @Published private(set) var findingPhone = false

    var send: ((GBMessage) -> Void)?

    private let location = CLLocationManager()
    private let events = EKEventStore()
    private var timer: Timer?
    private var lastWeatherFetch: Date?
    private var findTimer: Timer?

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        UIDevice.current.isBatteryMonitoringEnabled = true
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendBattery() }
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendCalendar() }
        }
        calendarAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Ask for the permissions these features need. Called from the app, not at launch.
    func requestPermissions() async {
        if shareCalendar, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            calendarAllowed = (try? await events.requestFullAccessToEvents()) ?? false
        }
        if shareWeather, location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// Pushes everything to the watch; called on every (re)connection.
    func refresh() {
        sendBattery()
        sendCalendar()
        if let weather, shareWeather { send?(.weather(weather)) }
        if shareWeather, lastWeatherFetch.map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
            location.requestLocation()
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    private func sendBattery() {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return }
        let state = UIDevice.current.batteryState
        send?(.phoneBattery(percent: Int((level * 100).rounded()), charging: state == .charging || state == .full))
    }

    private func sendCalendar() {
        calendarAllowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard shareCalendar, calendarAllowed else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: 36, to: now)!
        let found = events.events(matching: events.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(GBMessage.maxEvents)
        send?(.events(found.map {
            CalendarItem(title: String(($0.title ?? "").prefix(64)),
                         start: Int64($0.startDate.timeIntervalSince1970 * 1000),
                         end: Int64($0.endDate.timeIntervalSince1970 * 1000),
                         allDay: $0.isAllDay)
        }))
    }

    private func fetchWeather(at loc: CLLocation) async {
        // Round to ~1 km before it leaves the phone.
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: "\(lat)"),
            .init(name: "longitude", value: "\(lon)"),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url.url!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let r = try JSONDecoder().decode(Response.self, from: data)
            let place = (try? await CLGeocoder().reverseGeocodeLocation(loc).first)
                .flatMap { $0.locality ?? $0.subAdministrativeArea } ?? ""
            let report = WeatherReport(
                place: String(place.prefix(32)), tempC: r.current.temperature_2m,
                highC: r.daily.temperature_2m_max.first ?? r.current.temperature_2m,
                lowC: r.daily.temperature_2m_min.first ?? r.current.temperature_2m,
                code: r.current.weather_code, at: Int64(Date().timeIntervalSince1970 * 1000))
            guard [report.tempC, report.highC, report.lowC].allSatisfy({ (-90...60).contains($0) }) else { return }
            weather = report
            lastWeatherFetch = Date()
            send?(.weather(report))
        } catch {
            // Weather is best-effort; try again on the next refresh.
        }
    }

    // MARK: Find my phone

    /// The watch asked the phone to ring. Plays an alert now and posts a notification so it's
    /// audible even when the app is in the background.
    func findPhone(_ on: Bool) {
        findingPhone = on
        findTimer?.invalidate()
        findTimer = nil
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["find"])
        guard on else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your watch is looking for this iPhone"
        content.body = "Tap to stop."
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "find", content: content, trigger: nil))
        var rings = 0
        findTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            AudioServicesPlayAlertSound(SystemSoundID(1005))
            rings += 1
            if rings >= 15 { t.invalidate(); MainActor.assumeIsolated { self?.findingPhone = false } }
        }
        findTimer?.fire()
    }
}

extension PhoneServices: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in await fetchWeather(at: loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in if shareWeather { refresh() } }
    }
}
