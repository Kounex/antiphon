#if DEBUG
import AntiphonDesign
import SwiftUI

/// Shows the self-test as it runs and keeps the screen awake meanwhile.
struct SelfTestView: View {
    @State var runner: SelfTestRunner

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(runner.lines) { line in
                    Text(line.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.isFailure ? Color.statusFailed : Color.ink)
                        .id(line.id)
                }
                .onChange(of: runner.lines.count) {
                    if let last = runner.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .navigationTitle(runner.isRunning ? "Self-test running" : "Self-test \(runner.passed) ✓ \(runner.failed) ✗")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            await runner.run()
            // `-AntiphonSelfTestExit YES`: end the process so `devicectl --console` returns.
            if UserDefaults.standard.bool(forKey: "AntiphonSelfTestExit") {
                try? await Task.sleep(for: .seconds(1))
                exit(runner.failed == 0 ? 0 : 1)
            }
        }
    }
}
#endif
