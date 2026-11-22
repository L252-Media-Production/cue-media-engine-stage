import SwiftUI

@main
struct CueMEStageApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("CueME Stage")
                .font(.largeTitle)
            Text("Operator UI placeholder. The engine spike runs in StageEngine.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 280)
    }
}
