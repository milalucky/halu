import HaluCore
import SwiftUI

struct FinanceView: View {
    @ObservedObject var store: FinanceStore
    @Namespace private var modes

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickEntry(store: store)
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(FinanceStore.Mode.allCases) { mode in
                        Button {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.mode = mode }
                        } label: {
                            Text(mode.rawValue)
                                .font(Theme.caption(11.5, weight: .semibold))
                                .foregroundStyle(store.mode == mode ? Theme.onPrimary : Theme.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background {
                                    if store.mode == mode { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "mode", in: modes) }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Theme.card))
                Spacer()
                MonthSwitcher(store: store)
                PillButton(title: "Import", icon: "square.and.arrow.down", prominent: false, action: store.chooseStatement)
                    .help("Load bank statements: CSV or Excel. Already loaded rows are skipped.")
            }
            if let note = store.importNote {
                Text(note).font(Theme.caption(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            switch store.mode {
            case .overview: Overview(store: store)
            case .transactions: Transactions(store: store)
            case .budget: BudgetView(store: store)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.importNote)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            // Statements dropped on the tab are imported.
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { store.importStatements([url]) } }
                }
            }
            return true
        }
    }
}

enum Money {
    static func format(_ value: Double, _ currency: String = "RUB", sign: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        let number = formatter.string(from: NSNumber(value: abs(value))) ?? "\(value)"
        let symbol = ["RUB": "₽", "USD": "$", "EUR": "€", "KZT": "₸", "GBP": "£"][currency] ?? currency
        return (sign ? (value < 0 ? "−" : "+") : "") + number + " " + symbol
    }
}

/// "350 coffee" and Return: the amount, a note, and the category it guessed (click to change).
private struct QuickEntry: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        let parsed = store.parsedDraft
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { store.draftIncome.toggle() }
            } label: {
                Image(systemName: store.draftIncome ? "plus" : "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(store.draftIncome ? Theme.green : Theme.red)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill((store.draftIncome ? Theme.green : Theme.red).opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(store.draftIncome ? "Income · click for spending" : "Spending · click for income")
            InputField(placeholder: store.draftIncome ? "85000 salary" : "350 coffee · 1200 taxi · 4500 groceries", icon: "rublesign",
                       text: $store.draft, onSubmit: store.addDraft)
            if let parsed {
                let category = store.book.category(parsed.category)
                Menu {
                    ForEach(store.book.categories.filter { ($0.kind == .income) == store.draftIncome }) { item in
                        Button("\(item.emoji)  \(item.name)") { store.draftCategory = item.id }
                    }
                } label: {
                    Text("\(category?.emoji ?? "•") \(category?.name ?? "Other")")
                        .font(Theme.caption(11.5, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.card))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.scale.combined(with: .opacity))
                PillButton(title: "Add", icon: "return", tint: store.draftIncome ? Theme.green : Theme.accent, action: store.addDraft)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: parsed?.category)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: parsed == nil)
    }
}

private struct MonthSwitcher: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        HStack(spacing: 2) {
            IconButton(icon: "chevron.left", help: "Previous month", size: 10) { withAnimation { store.shiftMonth(-1) } }
            Text(Self.title.string(from: store.month))
                .font(Theme.caption(12, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 96)
                .contentTransition(.numericText())
            IconButton(icon: "chevron.right", help: "Next month", size: 10) { withAnimation { store.shiftMonth(1) } }
        }
    }

    private static let title: DateFormatter = { let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f }()
}

// MARK: Overview

private struct Overview: View {
    @ObservedObject var store: FinanceStore
    @State private var appeared = false

    var body: some View {
        let spent = store.spent, earned = store.earned
        let budget = store.book.monthlyBudget
        let categories = store.byCategory
        if store.monthTransactions.isEmpty {
            EmptyState(icon: "chart.pie", title: "Nothing this month yet",
                       subtitle: "Type an amount above (350 coffee) or import a bank statement: CSV or Excel, from any bank. Drop the file right here.")
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    SummaryCard(title: "Spent", value: Money.format(spent, store.currency), tint: Theme.red,
                                progress: budget.map { spent / $0 }, footnote: budget.map { "of \(Money.format($0, store.currency)) budget" })
                    SummaryCard(title: "Income", value: Money.format(earned, store.currency), tint: Theme.green, progress: nil, footnote: nil)
                    if let budget {
                        let left = budget - spent
                        SummaryCard(title: left >= 0 ? "Left" : "Over budget", value: Money.format(abs(left), store.currency),
                                    tint: left >= 0 ? Theme.accent : Theme.red, progress: nil, footnote: dailyHint(left))
                    } else {
                        SummaryCard(title: "Balance", value: Money.format(earned - spent, store.currency, sign: true),
                                    tint: earned >= spent ? Theme.green : Theme.orange, progress: nil, footnote: "income − spending")
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Donut(slices: categories.prefix(6).map { ($0.category, $0.total) }, total: spent, currency: store.currency, appeared: appeared)
                        .frame(width: 128, height: 128)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(categories.prefix(6).enumerated()), id: \.element.category.id) { index, item in
                            HStack(spacing: 6) {
                                Circle().fill(Self.sliceColor(index)).frame(width: 7, height: 7)
                                Text("\(item.category.emoji) \(item.category.name)").font(Theme.body(12)).foregroundStyle(Theme.primary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Money.format(item.total, store.currency)).font(Theme.caption(11.5, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 230)
                    DayChart(values: store.byDay, appeared: appeared)
                        .frame(maxWidth: .infinity, maxHeight: 128)
                }
            }
            .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appeared = true } }
            .onChange(of: store.month) { appeared = false; withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) { appeared = true } }
        }
    }

    /// How much a day is left for the rest of the month.
    private func dailyHint(_ left: Double) -> String? {
        guard left > 0, store.monthRange.contains(Date()) else { return nil }
        let calendar = Calendar.current
        let daysLeft = (calendar.range(of: .day, in: .month, for: Date())?.count ?? 30) - calendar.component(.day, from: Date()) + 1
        return "\(Money.format(left / Double(max(daysLeft, 1)), store.currency)) a day"
    }

    static func sliceColor(_ index: Int) -> Color {
        [Theme.accent, Theme.orange, Theme.blue, Theme.green, Color(red: 1, green: 0.55, blue: 0.75), Color(red: 0.95, green: 0.85, blue: 0.4)][index % 6]
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let tint: Color
    let progress: Double?
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(tint)
            Text(value).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.card)
                        Capsule().fill(progress > 1 ? Theme.red : tint).frame(width: geo.size.width * min(1, progress))
                    }
                }
                .frame(height: 4)
            }
            if let footnote { Text(footnote).font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: tint.opacity(0.3))
    }
}

/// Spending by category; the slices sweep in.
private struct Donut: View {
    let slices: [(MoneyCategory, Double)]
    let total: Double
    let currency: String
    let appeared: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Theme.card, lineWidth: 16)
            ForEach(Array(slices.enumerated()), id: \.offset) { index, slice in
                let start = slices.prefix(index).reduce(0) { $0 + $1.1 } / max(total, 1)
                let end = start + slice.1 / max(total, 1)
                Circle()
                    .trim(from: start, to: appeared ? end : start)
                    .stroke(Overview.sliceColor(index), style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.8, dampingFraction: 0.85).delay(Double(index) * 0.06), value: appeared)
            }
            VStack(spacing: 0) {
                Text(Money.format(total, currency)).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("spent").font(Theme.caption(10, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            .padding(20)
        }
    }
}

/// Spending per day, as bars that grow in; today is lit.
private struct DayChart: View {
    let values: [Double]
    let appeared: Bool

    var body: some View {
        let top = max(values.max() ?? 1, 1)
        let today = Calendar.current.component(.day, from: Date()) - 1
        VStack(alignment: .leading, spacing: 4) {
            Text("BY DAY").font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.tertiary)
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(values.indices, id: \.self) { day in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(day == today ? Theme.accent : Theme.accent.opacity(0.45))
                            .frame(height: appeared ? max(2, geo.size.height * values[day] / top) : 2)
                            .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(day) * 0.01), value: appeared)
                            .help(values[day] > 0 ? "\(day + 1): \(Money.format(values[day]))" : "\(day + 1)")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

// MARK: Transactions

private struct Transactions: View {
    @ObservedObject var store: FinanceStore

    private var groups: [(day: Date, items: [MoneyTransaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: store.searchResults) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InputField(placeholder: "Search all transactions by shop, note or category", icon: "magnifyingglass", text: $store.query)
            if groups.isEmpty {
                EmptyState(icon: "list.bullet.rectangle", title: "No transactions", subtitle: "Add one above or import a statement.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(groups, id: \.day) { group in
                            HStack {
                                SmallCaps(Fmt.dayTitle(group.day))
                                Spacer()
                                let spent = group.items.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }
                                if spent > 0 {
                                    Text(Money.format(spent, store.currency)).font(Theme.caption(10.5, weight: .semibold))
                                        .foregroundStyle(Theme.tertiary).padding(.top, 8).padding(.trailing, 10)
                                }
                            }
                            ForEach(group.items) { TransactionRow(transaction: $0, store: store) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct TransactionRow: View {
    let transaction: MoneyTransaction
    @ObservedObject var store: FinanceStore

    var body: some View {
        let category = store.book.category(transaction.categoryID)
        HoverRow { hovering in
            HStack(spacing: 10) {
                Text(category?.emoji ?? "•").font(.system(size: 15)).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transaction.note.isEmpty ? (category?.name ?? "") : transaction.note)
                        .font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                    Menu {
                        ForEach(store.book.categories.filter { ($0.kind == .income) == transaction.isIncome }) { item in
                            Button("\(item.emoji)  \(item.name)") { withAnimation { store.recategorize(transaction, to: item.id) } }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(category?.name ?? "Other")
                            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                        }
                        .font(Theme.caption(10.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Change the category; Halu remembers it for this shop")
                }
                Spacer()
                if hovering {
                    IconButton(icon: "trash", help: "Delete") { withAnimation { store.delete(transaction) } }
                }
                Text(Money.format(transaction.isIncome ? transaction.amount : -transaction.amount, transaction.currency, sign: true))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(transaction.isIncome ? Theme.green : Theme.primary)
            }
        }
    }
}

// MARK: Budget

private struct BudgetView: View {
    @ObservedObject var store: FinanceStore
    @State private var total = ""

    var body: some View {
        let spentBy = Dictionary(uniqueKeysWithValues: store.byCategory.map { ($0.category.id, $0.total) })
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Monthly budget").font(Theme.body(13, weight: .semibold)).foregroundStyle(Theme.primary)
                AmountField(value: store.book.monthlyBudget, placeholder: "No limit") { store.setBudget($0) }
                    .frame(width: 140)
                Spacer()
                Text("Spent \(Money.format(store.spent, store.currency)) this month").font(Theme.caption(11.5, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.book.categories.filter { $0.kind == .expense }) { category in
                        let spent = spentBy[category.id] ?? 0
                        HStack(spacing: 10) {
                            Text(category.emoji).frame(width: 22)
                            Text(category.name).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary).frame(width: 130, alignment: .leading)
                            GeometryReader { geo in
                                let share = category.budget.map { spent / $0 } ?? 0
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.card)
                                    Capsule().fill(share > 1 ? Theme.red : share > 0.8 ? Theme.orange : Theme.accent)
                                        .frame(width: geo.size.width * min(1, share))
                                        .animation(.spring(response: 0.6), value: share)
                                }
                            }
                            .frame(height: 6)
                            Text(Money.format(spent, store.currency)).font(Theme.caption(11.5, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.secondary).frame(width: 90, alignment: .trailing)
                            AmountField(value: category.budget, placeholder: "limit") { store.setBudget($0, for: category.id) }
                                .frame(width: 90)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// A number field that saves on Return or when it loses focus.
private struct AmountField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
            .textFieldStyle(.plain)
            .font(Theme.body(12.5))
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card))
            .focused($focused)
            .onAppear { text = value.map { String(Int($0)) } ?? "" }
            .onSubmit { onCommit(StatementParser.parseNumber(text)) }
            .onChange(of: focused) { if !focused { onCommit(StatementParser.parseNumber(text)) } }
    }
}
