import HaluCore
import SwiftUI

/// Claude asking for permission or with a question, dropped out of the notch. Stays until answered.
struct ClaudeRequestView: View {
    let request: ClaudeRequest
    let top: CGFloat
    let requests: ClaudeRequests
    @State private var questionIndex = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.frame(height: top - 4)
            HStack(spacing: 8) {
                ClaudeMark()
                    .stroke(Theme.orange, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 14, height: 14)
                Text(request.kind == .question ? "Claude asks" : "Claude wants to use \(request.toolName)")
                    .font(Theme.body(13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(request.project).font(Theme.caption(11, weight: .regular)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button("Answer in terminal") { requests.answer(request, .terminal) }
                    .buttonStyle(.plain)
                    .font(Theme.caption(11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            if request.kind == .permission {
                permission
            } else if request.questions.indices.contains(questionIndex) {
                question(request.questions[questionIndex])
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
        .id(request.id)
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(request.summary)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 56)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
            HStack(spacing: 8) {
                Spacer()
                PillButton(title: "Deny", tint: Theme.red, prominent: false) { requests.answer(request, .deny) }
                if request.canAlwaysAllow {
                    PillButton(title: "Always allow", tint: Theme.accent, prominent: false) { requests.answer(request, .always) }
                }
                PillButton(title: "Allow", icon: "checkmark", tint: Theme.green) { requests.answer(request, .allow) }
            }
        }
    }

    private func question(_ question: ClaudeRequest.Question) -> some View {
        let multi = question.multiSelect == true
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let header = question.header {
                    Text(header.uppercased()).font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.orange)
                }
                Text(question.question).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(2)
                Spacer()
                if request.questions.count > 1 {
                    Text("\(questionIndex + 1)/\(request.questions.count)").font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(question.options, id: \.label) { option in
                        OptionRow(option: option, selected: picked.contains(option.label), multi: multi) {
                            if multi {
                                if picked.contains(option.label) { picked.remove(option.label) } else { picked.insert(option.label) }
                            } else {
                                commit(question, [option.label])
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 92)
            if multi {
                HStack {
                    Spacer()
                    PillButton(title: "Done", tint: Theme.orange) {
                        commit(question, question.options.map(\.label).filter(picked.contains))
                    }
                    .disabled(picked.isEmpty)
                }
            }
        }
    }

    /// Saves this question's answer and moves on; the last one sends everything.
    private func commit(_ question: ClaudeRequest.Question, _ labels: [String]) {
        answers[question.question] = labels.joined(separator: ", ")
        picked = []
        if questionIndex + 1 < request.questions.count {
            withAnimation(.easeOut(duration: 0.2)) { questionIndex += 1 }
        } else {
            requests.answer(request, .allow, answers: answers)
        }
    }
}

private struct OptionRow: View {
    let option: ClaudeRequest.Option
    let selected: Bool
    let multi: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square") : "arrow.right.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected || hovering ? Theme.orange : Theme.tertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(Theme.body(12, weight: .semibold)).foregroundStyle(Theme.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || selected ? Theme.cardHover : Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
