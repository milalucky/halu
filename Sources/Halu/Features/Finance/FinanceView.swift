import HaluCore
import SwiftUI

struct FinanceView: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickEntry(store: store)
            FinanceToolbar(store: store)
            if let note = store.importNote {
                Text(note).font(Theme.caption(11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            content
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.importNote)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: importDropped)
    }

    @ViewBuilder
    private var content: some View {
        switch store.mode {
        case .overview: Overview(store: store)
        case .transactions: Transactions(store: store)
        case .plan: PlanView(store: store)
        case .categories: CategoriesView(store: store)
        }
    }

    /// Statements dropped on the tab are imported.
    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { store.importStatements([url]) } }
            }
        }
        return true
    }
}

private struct FinanceToolbar: View {
    @ObservedObject var store: FinanceStore
    @Namespace private var modes

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(FinanceStore.Mode.allCases) { mode in
                    ModeChip(title: mode.rawValue, selected: store.mode == mode, namespace: modes) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.mode = mode }
                    }
                }
            }
            .padding(2)
            .background(Capsule().fill(Theme.card))
            Spacer(minLength: 4)
            MonthSwitcher(store: store)
            PillButton(title: "Import", icon: "square.and.arrow.down", prominent: false, action: store.chooseStatement)
                .help("Load bank statements: CSV or Excel. Already loaded rows are skipped.")
        }
    }
}

private struct ModeChip: View {
    let title: String
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(11.5, weight: .semibold))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if selected { Capsule().fill(Theme.accent).matchedGeometryEffect(id: "mode", in: namespace) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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

/// Spending or income, then "350 coffee" (or "$100 salary") and Return. The category is guessed;
/// the chips below pick another in one click.
private struct QuickEntry: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        let parsed = store.parsedDraft
        let income = store.isIncomeDraft
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                KindSwitch(income: income) { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        store.draftIncome = value
                        store.draftCategory = nil
                    }
                }
                InputField(placeholder: income ? "85000 salary · $100 freelance" : "350 coffee · 1200 taxi · €20 lunch",
                           icon: income ? "arrow.down.left" : "arrow.up.right", text: $store.draft, onSubmit: store.addDraft)
                if let parsed {
                    Text(Money.format(parsed.amount, parsed.currency))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(income ? Theme.green : Theme.primary)
                        .transition(.scale.combined(with: .opacity))
                    PillButton(title: "Add", icon: "return", tint: income ? Theme.green : Theme.accent, action: store.addDraft)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            CategoryChips(store: store, income: income, selected: parsed?.category)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: parsed == nil)
    }
}

/// Spending | Income, said in words.
private struct KindSwitch: View {
    let income: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            option("Spending", icon: "minus", tint: Theme.red, on: !income) { onChange(false) }
            option("Income", icon: "plus", tint: Theme.green, on: income) { onChange(true) }
        }
        .padding(2)
        .background(Capsule().fill(Theme.card))
    }

    private func option(_ title: String, icon: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .black))
                Text(title).font(Theme.caption(11.5, weight: .semibold))
            }
            .foregroundStyle(on ? .white : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(on ? tint.opacity(0.85) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The most used categories as chips; the guessed or chosen one is lit. "More" lists the rest.
private struct CategoryChips: View {
    @ObservedObject var store: FinanceStore
    let income: Bool
    let selected: String?

    var body: some View {
        let frequent = store.frequent(income: income)
        HStack(spacing: 4) {
            // Scrolls sideways on a narrow panel instead of pushing the whole tab wider.
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(frequent) { category in
                        chip(category, on: category.id == selected)
                    }
                    if let selected, !frequent.contains(where: { $0.id == selected }), let category = store.book.category(selected) {
                        chip(category, on: true)
                    }
                }
            }
            .scrollIndicators(.never)
            .fixedSize(horizontal: false, vertical: true)
            Menu {
                ForEach(store.choices(income: income)) { item in
                    Button("\(item.emoji)  \(item.name)") { store.draftCategory = item.id }
                }
            } label: {
                Text("More").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 8).frame(height: 22)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 0)
        }
    }

    private func chip(_ category: MoneyCategory, on: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { store.draftCategory = on && store.draftCategory == category.id ? nil : category.id }
        } label: {
            Text("\(category.emoji) \(category.name)")
                .font(Theme.caption(11, weight: .semibold))
                .foregroundStyle(on ? Theme.onPrimary : Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(on ? Theme.accent : Theme.card))
                .scaleEffect(on ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .fixedSize()
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

// MARK: Plan

/// The month planned against what happened: expected income and regular payments, a savings goal,
/// the overall budget and limits per category.
private struct PlanView: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PlanSummary(store: store)
                PlanList(store: store, income: true)
                PlanList(store: store, income: false)
                LimitsList(store: store)
            }
        }
        .scrollIndicators(.never)
    }
}

private struct PlanSummary: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        let income = max(store.plannedIncome, store.earned)
        let spending = store.plannedSpending
        let saving = income - spending
        HStack(spacing: 8) {
            PlanStat(title: "Income", plan: store.plannedIncome, fact: store.earned, tint: Theme.green, currency: store.currency)
            PlanStat(title: "Spending", plan: spending, fact: store.spent, tint: Theme.red, currency: store.currency)
            VStack(alignment: .leading, spacing: 4) {
                Text("SAVINGS").font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.accent)
                Text(Money.format(saving, store.currency, sign: true)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 4) {
                    Text("Goal").font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                    AmountField(value: store.book.savingsGoal, placeholder: "set") { store.setSavingsGoal($0) }.frame(width: 80)
                }
                if let goal = store.book.savingsGoal {
                    Text(saving >= goal ? "On track" : "\(Money.format(goal - saving, store.currency)) short")
                        .font(Theme.caption(10.5, weight: .semibold)).foregroundStyle(saving >= goal ? Theme.green : Theme.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: Theme.accent.opacity(0.3))
        }
    }
}

private struct PlanStat: View {
    let title: String
    let plan: Double
    let fact: Double
    let tint: Color
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(tint)
            Text(Money.format(fact, currency)).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.card)
                    Capsule().fill(tint).frame(width: plan > 0 ? geo.size.width * min(1, fact / plan) : 0)
                        .animation(.spring(response: 0.6), value: fact)
                }
            }
            .frame(height: 4)
            Text(plan > 0 ? "of \(Money.format(plan, currency)) planned" : "nothing planned")
                .font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: tint.opacity(0.3))
    }
}

/// Expected income or regular payments, each with amount, day and category; done ones are ticked.
private struct PlanList: View {
    @ObservedObject var store: FinanceStore
    let income: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SmallCaps(income ? "Expected income" : "Regular payments")
                Spacer()
                Button { withAnimation { store.addPlanItem(income: income) } } label: {
                    Label("Add", systemImage: "plus").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).padding(.top, 8).padding(.trailing, 8)
            }
            ForEach(store.book.plan.filter { $0.isIncome == income }) { item in
                PlanRow(item: item, store: store)
            }
            if !store.book.plan.contains(where: { $0.isIncome == income }) {
                Text(income ? "Salary, side income: add what you expect each month." : "Rent, subscriptions, loans: add what you pay each month.")
                    .font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary).padding(.leading, 10)
            }
        }
    }
}

private struct PlanRow: View {
    let item: PlanItem
    @ObservedObject var store: FinanceStore
    @State private var title = ""
    @State private var hovering = false

    var body: some View {
        let done = store.isDone(item)
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Theme.green : Theme.tertiary)
                .help(done ? "Already happened this month" : "Not yet this month")
            TextField("", text: $title)
                .textFieldStyle(.plain).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary)
                .onAppear { title = item.title }
                .onSubmit { var copy = item; copy.title = title; store.update(copy) }
            Menu {
                ForEach(store.choices(income: item.isIncome)) { category in
                    Button("\(category.emoji)  \(category.name)") { var copy = item; copy.categoryID = category.id; store.update(copy) }
                }
            } label: {
                Text(store.book.category(item.categoryID).map { "\($0.emoji) \($0.name)" } ?? "Category")
                    .font(Theme.caption(11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            Text("day").font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
            AmountField(value: item.day.map(Double.init), placeholder: "–") { value in
                var copy = item; copy.day = value.map { min(31, max(1, Int($0))) }; store.update(copy)
            }
            .frame(width: 36)
            AmountField(value: item.amount > 0 ? item.amount : nil, placeholder: "amount") { value in
                var copy = item; copy.amount = value ?? 0; store.update(copy)
            }
            .frame(width: 96)
            IconButton(icon: "trash", help: "Remove", size: 10) { withAnimation { store.deletePlanItem(item) } }
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
        .onHover { hovering = $0 }
    }
}

/// The monthly budget and a limit per spending category, with how much went there.
private struct LimitsList: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        let spentBy = Dictionary(uniqueKeysWithValues: store.byCategory.map { ($0.category.id, $0.total) })
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SmallCaps("Limits")
                Spacer()
                Text("Whole month").font(Theme.caption(11, weight: .medium)).foregroundStyle(Theme.tertiary).padding(.top, 8)
                AmountField(value: store.book.monthlyBudget, placeholder: "no limit") { store.setBudget($0) }
                    .frame(width: 110).padding(.top, 8)
            }
            ForEach(store.choices(income: false)) { category in
                LimitRow(category: category, spent: spentBy[category.id] ?? 0, store: store)
            }
        }
    }
}

private struct LimitRow: View {
    let category: MoneyCategory
    let spent: Double
    @ObservedObject var store: FinanceStore

    var body: some View {
        let share = category.budget.map { spent / $0 } ?? 0
        HStack(spacing: 10) {
            Text(category.emoji).frame(width: 22)
            Text(category.name).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary).frame(width: 130, alignment: .leading)
            GeometryReader { geo in
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

// MARK: Categories

/// Rename, re-emoji, hide, delete or add categories, and see the words that sort transactions into them.
private struct CategoriesView: View {
    @ObservedObject var store: FinanceStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section(income: false)
                section(income: true)
            }
        }
        .scrollIndicators(.never)
    }

    private func section(income: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SmallCaps(income ? "Income" : "Spending")
                Spacer()
                Button { withAnimation { _ = store.addCategory(income: income) } } label: {
                    Label("New category", systemImage: "plus").font(Theme.caption(11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).padding(.top, 8).padding(.trailing, 8)
            }
            ForEach(store.book.categories.filter { ($0.kind == .income) == income }) { category in
                CategoryRow(category: category, store: store)
            }
        }
    }
}

private struct CategoryRow: View {
    let category: MoneyCategory
    @ObservedObject var store: FinanceStore
    @State private var name = ""
    @State private var emoji = ""
    @State private var words = ""
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $emoji)
                .textFieldStyle(.plain).font(.system(size: 15)).multilineTextAlignment(.center).frame(width: 28)
                .onSubmit(save)
            TextField("", text: $name)
                .textFieldStyle(.plain).font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(category.hidden ? Theme.tertiary : Theme.primary)
                .frame(width: 140)
                .onSubmit(save)
            TextField("", text: $words, prompt: Text("words that mean this category, comma-separated").foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.secondary)
                .onSubmit(save)
            Text("\(store.usage(of: category.id))").font(Theme.caption(10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
                .help("Transactions in this category")
            Toggle("", isOn: Binding(get: { !category.hidden }, set: { on in var copy = category; copy.hidden = !on; store.update(copy) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
                .help(category.hidden ? "Hidden: not offered for new entries" : "Offered for new entries")
            if !["other", "income-other"].contains(category.id) {
                IconButton(icon: "trash", help: "Delete; its transactions move to Other", size: 10) {
                    withAnimation { store.deleteCategory(category.id) }
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
        .onHover { hovering = $0 }
        .onAppear(perform: load)
        .onChange(of: category) { load() }
    }

    private func load() {
        name = category.name
        emoji = category.emoji
        words = category.keywords.joined(separator: ", ")
    }

    private func save() {
        var copy = category
        copy.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? category.name : name
        copy.emoji = emoji.isEmpty ? category.emoji : String(emoji.prefix(2))
        copy.keywords = words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        store.update(copy)
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
