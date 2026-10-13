import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step = 0
    private let titles = ["Welcome to Reprise", "Your Permissions", "Your AI", "Ready"]
    var body: some View {
        VStack(spacing: 0) {
            HStack { RepriseIcon(size: 36); Spacer(); Text("\(step + 1) of 4").repriseFont(.caption).foregroundStyle(.secondary) }.padding(22)
            Text(titles[step]).repriseFont(.title).padding(.bottom, 16)
            Group {
                switch step {
                case 0:
                    VStack(spacing: 20) {
                        RepriseIcon(size: 164)
                        Text("Your memory, on this Mac.").repriseFont(.heading)
                        Text("Screen and audio recording stay off until you start them. AI search shares only the selected text with your chosen provider.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case 1:
                    Form {
                        Section("Screen & Audio") { PermissionSettings(center: model.permissions) }
                        Section("Meeting Audio") {
                            Toggle("Include system audio", isOn: $model.preferences.includeSystemAudio)
                            Toggle("Transcribe on this Mac", isOn: $model.preferences.transcribeMeetings)
                        }
                    }.formStyle(.grouped)
                case 2: Form { AISettings(model: model) }.formStyle(.grouped)
                default:
                    Form {
                        Section("Reprise") {
                            Picker("Show in", selection: $model.preferences.iconPlacement) { ForEach(IconPlacement.allCases) { Text($0.title).tag($0) } }
                            Toggle("Open memory on launch", isOn: $model.preferences.showOnLaunch)
                            Toggle("Detect meeting windows", isOn: $model.preferences.detectMeetings)
                        }
                        AppearanceSettings(model: model)
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 3 ? "Open Reprise" : "Continue") {
                    if step == 3 { model.finishOnboarding() } else { step += 1 }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(22)
        }.frame(width: 640, height: 610).repriseAppearance(model.preferences).interactiveDismissDisabled()
    }
}
