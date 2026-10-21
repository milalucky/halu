import SwiftUI

/// Halu in an ordinary window: the same sidebar and tabs as the notch panel, with room to work.
struct WindowRootView: View {
    @ObservedObject var model: AppModel
    let services: Services

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HaluMark(size: 15, color: Theme.primary,
                         animating: model.tab == .claude && services.claude.rows.contains { $0.phase == .working })
                Text("Halu").font(Theme.title(14)).foregroundStyle(Theme.primary)
                Text(model.tab.title).font(Theme.title(14)).foregroundStyle(Theme.tertiary)
                Spacer()
                ClaudeUsagePill(requests: services.claudeRequests)
                SpeedLabel(speed: services.speed)
                ChatButton(model: model)
                PomodoroButton(pomodoro: services.pomodoro)
                VPNButton(vpn: services.vpn)
                AwakeButton(awake: services.awake)
            }
            // Room for the window's close / minimise / zoom buttons.
            .padding(.leading, 84)
            .padding(.trailing, 18)
            .frame(height: 40)

            HStack(spacing: 0) {
                Sidebar(model: model, claude: services.claude, media: services.media, messages: services.messages, gitlab: services.gitlab)
                Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 6)
                TabContent(model: model, services: services)
                    .padding(.leading, 18)
                    .padding(.trailing, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
