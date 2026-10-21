import SwiftUI

/// The forecast, opened from the weather in the header: now, the next 12 hours and the week.
struct WeatherView: View {
    @ObservedObject var weather: WeatherStore
    @State private var appeared = false

    var body: some View {
        if let now = weather.now {
            let look = WeatherStore.describe(now.code, day: now.isDay)
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Self.sky(code: now.code, day: now.isDay))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(now, look)
                        hourly
                        daily
                    }
                    .padding(16)
                }
                .scrollIndicators(.never)
            }
            .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true } }
            .onDisappear { appeared = false }
        } else {
            EmptyState(icon: "cloud.sun", title: "No weather yet",
                       subtitle: weather.problem ?? "Halu is looking up the weather. You can set your city in Settings → Weather.")
        }
    }

    private func header(_ now: WeatherStore.Now, _ look: (symbol: String, text: String)) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weather.place.isEmpty ? "Here" : weather.place)
                    .font(Theme.body(14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                Text("\(Int(now.temperature.rounded()))°")
                    .font(.system(size: 48, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(look.text).font(Theme.body(13, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 8) {
                    if let high = now.high, let low = now.low { Text("H:\(Int(high.rounded()))°  L:\(Int(low.rounded()))°") }
                    Text("Feels \(Int(now.feelsLike.rounded()))°")
                    Text("Wind \(Int(now.wind.rounded())) km/h")
                }
                .font(Theme.caption(11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            AnimatedSymbol(code: now.code, day: now.isDay, size: 56)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
        }
    }

    private var hourly: some View {
        HStack(spacing: 0) {
            ForEach(Array(weather.hours.enumerated()), id: \.element.id) { index, hour in
                VStack(spacing: 5) {
                    Text(index == 0 ? "Now" : Self.hour.string(from: hour.time))
                        .font(Theme.caption(10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    Image(systemName: WeatherStore.describe(hour.code, day: hour.isDay).symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 15))
                        .frame(height: 18)
                    Text(hour.rainChance >= 20 ? "\(hour.rainChance)%" : " ")
                        .font(Theme.caption(9, weight: .bold)).foregroundStyle(Color(red: 0.55, green: 0.8, blue: 1))
                    Text("\(Int(hour.temperature.rounded()))°")
                        .font(Theme.caption(12, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .offset(y: appeared ? 0 : 10)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.03 * Double(index)), value: appeared)
            }
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    private var daily: some View {
        let low = weather.days.map(\.low).min() ?? 0, high = weather.days.map(\.high).max() ?? 1
        return VStack(spacing: 2) {
            ForEach(Array(weather.days.enumerated()), id: \.element.id) { index, day in
                HStack(spacing: 10) {
                    Text(index == 0 ? "Today" : Self.weekday.string(from: day.date))
                        .font(Theme.body(12.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 46, alignment: .leading)
                    VStack(spacing: 0) {
                        Image(systemName: WeatherStore.describe(day.code, day: true).symbol)
                            .symbolRenderingMode(.multicolor).font(.system(size: 13))
                        if day.rainChance >= 30 {
                            Text("\(day.rainChance)%").font(Theme.caption(8.5, weight: .bold)).foregroundStyle(Color(red: 0.55, green: 0.8, blue: 1))
                        }
                    }
                    .frame(width: 30)
                    Text("\(Int(day.low.rounded()))°").font(Theme.caption(12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 30, alignment: .trailing)
                    RangeBar(low: day.low, high: day.high, weekLow: low, weekHigh: high, appeared: appeared, delay: 0.04 * Double(index))
                    Text("\(Int(day.high.rounded()))°").font(Theme.caption(12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 30, alignment: .leading)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.4).delay(0.15 + 0.04 * Double(index)), value: appeared)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    private static let hour: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH"; return f }()
    private static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()

    /// A sky to match: blue days, deep nights, grey clouds, dark storms.
    static func sky(code: Int, day: Bool) -> LinearGradient {
        let colors: [Color]
        switch (code, day) {
        case (95...99, _): colors = [Color(red: 0.18, green: 0.2, blue: 0.3), Color(red: 0.08, green: 0.09, blue: 0.14)]
        case (_, false): colors = [Color(red: 0.08, green: 0.12, blue: 0.3), Color(red: 0.02, green: 0.03, blue: 0.1)]
        case (45...86, true): colors = [Color(red: 0.42, green: 0.5, blue: 0.6), Color(red: 0.24, green: 0.3, blue: 0.4)]
        case (3, true): colors = [Color(red: 0.45, green: 0.55, blue: 0.68), Color(red: 0.28, green: 0.36, blue: 0.48)]
        default: colors = [Color(red: 0.25, green: 0.55, blue: 0.92), Color(red: 0.12, green: 0.33, blue: 0.7)]
        }
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }
}

/// The big condition symbol, alive: rain and snow fall, the sun pulses, clouds drift.
private struct AnimatedSymbol: View {
    let code: Int
    let day: Bool
    let size: CGFloat
    @State private var drift = false

    var body: some View {
        let symbol = WeatherStore.describe(code, day: day).symbol
        Image(systemName: symbol)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: (51...99).contains(code))
            .symbolEffect(.pulse, options: .repeating, isActive: code == 0)
            .offset(x: drift ? 4 : -4)
            .animation((1...3).contains(code) ? .easeInOut(duration: 3).repeatForever(autoreverses: true) : .default, value: drift)
            .onAppear { drift = true }
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// Where today's range sits within the week's, coloured from cool to warm, like Apple's Weather.
private struct RangeBar: View {
    let low: Double, high: Double, weekLow: Double, weekHigh: Double
    let appeared: Bool
    let delay: Double

    var body: some View {
        GeometryReader { geo in
            let span = max(1, weekHigh - weekLow)
            let start = (low - weekLow) / span * geo.size.width
            let width = max(6, (high - low) / span * geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [Self.tint(low), Self.tint(high)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: appeared ? width : 6)
                    .offset(x: start)
                    .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.2 + delay), value: appeared)
            }
        }
        .frame(height: 5)
    }

    static func tint(_ t: Double) -> Color {
        switch t {
        case ..<(-10): Color(red: 0.55, green: 0.65, blue: 1)
        case ..<0: Color(red: 0.4, green: 0.8, blue: 1)
        case ..<10: Color(red: 0.45, green: 0.9, blue: 0.75)
        case ..<20: Color(red: 0.95, green: 0.85, blue: 0.35)
        case ..<28: Color(red: 1, green: 0.62, blue: 0.3)
        default: Color(red: 1, green: 0.4, blue: 0.35)
        }
    }
}
