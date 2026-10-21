import AppKit
import CoreLocation
import SwiftUI

/// Current weather for the header, from Open-Meteo (free, no key). The place is a city you type in
/// Settings, or else where the Mac is (asked once through Location Services). Coordinates are rounded
/// to about a kilometre before they're sent.
@MainActor
final class WeatherStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Now: Equatable {
        var temperature: Double
        var feelsLike: Double
        var code: Int
        var isDay: Bool
        var high: Double?
        var low: Double?
        var wind: Double
    }

    @Published private(set) var now: Now?
    @Published private(set) var place: String = UserDefaults.standard.string(forKey: "weather.place") ?? ""
    @Published private(set) var problem: String?
    /// A city typed in Settings; empty means "where I am".
    @Published var city = UserDefaults.standard.string(forKey: "weather.city") ?? "" {
        didSet { UserDefaults.standard.set(city, forKey: "weather.city") }
    }

    private let locator = CLLocationManager()
    private var coordinate: CLLocationCoordinate2D?
    private var timer: Timer?

    func start() {
        locator.delegate = self
        locator.desiredAccuracy = kCLLocationAccuracyKilometer
        let timer = Timer(timeInterval: 20 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// Looks up the place again and fetches the weather.
    func refresh() {
        let typed = city.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            Task { await geocode(typed) }
        } else if let coordinate {
            Task { await fetch(coordinate) }
        } else {
            switch locator.authorizationStatus {
            case .notDetermined: locator.requestWhenInUseAuthorization()
            case .denied, .restricted: problem = "Type your city in Settings → Weather."
            default: locator.requestLocation()
            }
        }
    }

    func useMyLocation() {
        city = ""
        coordinate = nil
        refresh()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized { manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        MainActor.assumeIsolated {
            self.coordinate = coordinate
            CLGeocoder().reverseGeocodeLocation(location) { [weak self] marks, _ in
                let name = marks?.first?.locality ?? ""
                DispatchQueue.main.async { MainActor.assumeIsolated { if !name.isEmpty { self?.setPlace(name) } } }
            }
            Task { await self.fetch(coordinate) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.problem = "Location isn't available. Type your city in Settings → Weather." }
    }

    // MARK: Open-Meteo

    private func setPlace(_ name: String) {
        place = name
        UserDefaults.standard.set(name, forKey: "weather.place")
    }

    private func geocode(_ name: String) async {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?count=1&language=en&name=\(query)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let latitude = first["latitude"] as? Double, let longitude = first["longitude"] as? Double else {
            problem = "Couldn't find “\(name)”."
            return
        }
        setPlace(first["name"] as? String ?? name)
        await fetch(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private func fetch(_ coordinate: CLLocationCoordinate2D) async {
        let lat = String(format: "%.2f", coordinate.latitude), lon = String(format: "%.2f", coordinate.longitude)
        let address = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m"
            + "&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto"
        guard let url = URL(string: address), let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double else {
            problem = "Weather isn't available right now."
            return
        }
        let daily = json["daily"] as? [String: Any]
        now = Now(temperature: temperature, feelsLike: current["apparent_temperature"] as? Double ?? temperature,
                  code: current["weather_code"] as? Int ?? 0, isDay: (current["is_day"] as? Int ?? 1) == 1,
                  high: (daily?["temperature_2m_max"] as? [Double])?.first, low: (daily?["temperature_2m_min"] as? [Double])?.first,
                  wind: current["wind_speed_10m"] as? Double ?? 0)
        problem = nil
    }

    // MARK: Codes

    /// WMO weather code → SF Symbol and words.
    static func describe(_ code: Int, day: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: return (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1, 2: return (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly cloudy")
        case 3: return ("cloud.fill", "Overcast")
        case 45, 48: return ("cloud.fog.fill", "Fog")
        case 51...57: return ("cloud.drizzle.fill", "Drizzle")
        case 61...67, 80...82: return ("cloud.rain.fill", "Rain")
        case 71...77, 85, 86: return ("cloud.snow.fill", "Snow")
        case 95...99: return ("cloud.bolt.rain.fill", "Thunderstorm")
        default: return ("cloud.fill", "Cloudy")
        }
    }
}

/// Header: weather symbol and temperature; details in the tooltip.
struct WeatherPill: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        if let now = weather.now {
            let look = WeatherStore.describe(now.code, day: now.isDay)
            HStack(spacing: 3) {
                Image(systemName: look.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 11))
                Text("\(Int(now.temperature.rounded()))°")
                    .font(Theme.caption(11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            .fixedSize()
            .help(help(now, look.text))
        }
    }

    private func help(_ now: WeatherStore.Now, _ text: String) -> String {
        var lines = ["\(weather.place.isEmpty ? "Weather" : weather.place): \(text), \(Int(now.temperature.rounded()))°",
                     "Feels like \(Int(now.feelsLike.rounded()))° · wind \(Int(now.wind.rounded())) km/h"]
        if let high = now.high, let low = now.low { lines.append("Today \(Int(low.rounded()))° … \(Int(high.rounded()))°") }
        return lines.joined(separator: "\n")
    }
}
