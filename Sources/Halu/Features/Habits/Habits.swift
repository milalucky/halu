import SwiftUI

/// A habit to tick off each day, or a counter with a daily goal (water, push-ups, pages).
struct Habit: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var emoji: String
    /// 1 means a yes/no habit; more makes it a counter.
    var goal: Int
    var unit: String
    /// Count per day, keyed "yyyy-MM-dd".
    var log: [String: Int] = [:]
}

@MainActor
final class HabitStore: ObservableObject {
    @Published private(set) var habits: [Habit]
    @Published var editing: Habit?
    private let file = JSONFile<[Habit]>("habits.json")

    init() {
        habits = file.load() ?? [
            Habit(name: "Water", emoji: "💧", goal: 8, unit: "glasses"),
            Habit(name: "Workout", emoji: "🏃", goal: 1, unit: ""),
        ]
    }

    static func key(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func count(_ habit: Habit, on date: Date = .now) -> Int { habit.log[Self.key(date)] ?? 0 }

    func bump(_ habit: Habit, by step: Int) {
        update(habit.id) { $0.log[Self.key(.now), default: 0] = max(0, ($0.log[Self.key(.now)] ?? 0) + step) }
    }

    /// Days in a row the goal was met, counting today only if it's already met.
    func streak(_ habit: Habit) -> Int {
        let calendar = Calendar.current
        var day = Date()
        if count(habit, on: day) < habit.goal { day = calendar.date(byAdding: .day, value: -1, to: day)! }
        var streak = 0
        while count(habit, on: day) >= habit.goal {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    func save(_ habit: Habit) {
        var habit = habit
        habit.name = habit.name.trimmingCharacters(in: .whitespaces)
        guard !habit.name.isEmpty else { return }
        habit.goal = max(1, habit.goal)
        if let index = habits.firstIndex(where: { $0.id == habit.id }) { habits[index] = habit } else { habits.append(habit) }
        file.save(habits)
    }

    func delete(_ habit: Habit) {
        habits.removeAll { $0.id == habit.id }
        file.save(habits)
    }

    private func update(_ id: UUID, _ change: (inout Habit) -> Void) {
        guard let index = habits.firstIndex(where: { $0.id == id }) else { return }
        change(&habits[index])
        file.save(habits)
    }
}

struct HabitsView: View {
    @ObservedObject var store: HabitStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Today", detail: "\(store.habits.filter { store.count($0) >= $0.goal }.count) of \(store.habits.count) done")
                Spacer()
                IconButton(icon: "plus", help: "New habit or counter", size: 12) {
                    withAnimation { store.editing = Habit(name: "", emoji: "✨", goal: 1, unit: "") }
                }
            }
            if let habit = store.editing {
                HabitEditor(habit: Binding(get: { store.editing ?? habit }, set: { store.editing = $0 })) {
                    store.save($0)
                    withAnimation { store.editing = nil }
                } onCancel: { withAnimation { store.editing = nil } }
            }
            if store.habits.isEmpty && store.editing == nil {
                EmptyState(icon: "repeat", title: "No habits yet", subtitle: "Add something to do every day, or a counter like glasses of water.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.habits) { HabitRow(habit: $0, store: store) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct HabitRow: View {
    let habit: Habit
    @ObservedObject var store: HabitStore
    @State private var hovering = false

    var body: some View {
        let count = store.count(habit)
        let done = count >= habit.goal
        HStack(spacing: 12) {
            // The ring fills as the day's goal gets closer; a click adds one.
            Button { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { store.bump(habit, by: done && habit.goal == 1 ? -1 : 1) } } label: {
                ZStack {
                    Circle().stroke(Theme.card, lineWidth: 4)
                    Circle().trim(from: 0, to: min(1, Double(count) / Double(habit.goal)))
                        .stroke(done ? Theme.green : Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(habit.emoji).font(.system(size: 17))
                }
                .frame(width: 40, height: 40)
                .scaleEffect(done ? 1.05 : 1)
                .overlay { if done { Burst(tint: Theme.green) } }
            }
            .buttonStyle(.plain)
            .help(habit.goal == 1 ? (done ? "Undo" : "Done today") : "Add one")
            VStack(alignment: .leading, spacing: 3) {
                Text(habit.name).font(Theme.body(13.5, weight: .semibold)).foregroundStyle(done ? Theme.secondary : Theme.primary)
                HStack(spacing: 6) {
                    if habit.goal > 1 {
                        Text("\(count) / \(habit.goal) \(habit.unit)").font(Theme.caption(11.5, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(done ? Theme.green : Theme.secondary)
                    }
                    let streak = store.streak(habit)
                    if streak > 0 { Text("🔥 \(streak) day\(streak == 1 ? "" : "s")").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.orange) }
                }
            }
            Spacer()
            // The last seven days, today on the right.
            HStack(spacing: 3) {
                ForEach((0..<7).reversed(), id: \.self) { back in
                    let day = Calendar.current.date(byAdding: .day, value: -back, to: .now)!
                    let value = store.count(habit, on: day)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(value >= habit.goal ? Theme.green : value > 0 ? Theme.accent.opacity(0.5) : Theme.card)
                        .frame(width: 10, height: 10)
                }
            }
            if habit.goal > 1 {
                IconButton(icon: "minus", help: "One less", size: 10) { withAnimation { store.bump(habit, by: -1) } }
                    .disabled(count == 0)
            }
            if hovering {
                IconButton(icon: "pencil", help: "Edit", size: 10) { withAnimation { store.editing = habit } }
                IconButton(icon: "trash", help: "Delete", size: 10) { withAnimation { store.delete(habit) } }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(done ? Theme.green.opacity(0.08) : Theme.card))
        .onHover { hovering = $0 }
    }
}

private struct HabitEditor: View {
    @Binding var habit: Habit
    let onSave: (Habit) -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $habit.emoji).textFieldStyle(.plain).font(.system(size: 18)).multilineTextAlignment(.center).frame(width: 30)
            TextField("", text: $habit.name, prompt: Text("Read, Water, Stretch…").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain).font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.primary)
                .onSubmit { onSave(habit) }
            Stepper(value: $habit.goal, in: 1...100) {
                Text(habit.goal == 1 ? "Once a day" : "\(habit.goal) a day").font(Theme.caption(11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .fixedSize()
            if habit.goal > 1 {
                TextField("", text: $habit.unit, prompt: Text("unit").foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain).font(Theme.caption(11.5, weight: .regular)).frame(width: 60)
            }
            PillButton(title: "Save") { onSave(habit) }
            IconButton(icon: "xmark", help: "Cancel", size: 10, action: onCancel)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardHover))
    }
}
