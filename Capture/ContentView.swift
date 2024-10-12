import SwiftUI

class ContentViewModel: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var inputText: String = "" // Added inputText here
}

struct ContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack {
            TextField("Enter your note", text: $viewModel.inputText, onCommit: {
                let trimmedText = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    sendDataToNotion(text: trimmedText)
                    viewModel.inputText = "" // Clear the input for next time
                }
                hideWindow()
            })
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 24))
            .padding()
            .foregroundColor(.primary)
            .background(Color.clear)
            .focused($isFocused)
            .onChange(of: viewModel.isFocused) { newValue in
                if newValue {
                    isFocused = true
                    viewModel.isFocused = false // Reset to avoid repeated focusing
                }
            }
        }
        .frame(width: 600, height: 70)
        .padding()
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .cornerRadius(12)
        )
    }

    func sendDataToNotion(text: String) {
        print("sendDataToNotion called with text: '\(text)'")
        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            print("Invalid URL")
            return
        }
        // Retrieve Notion API token and Database ID from environment variables
        guard let notionToken = ProcessInfo.processInfo.environment["NOTION_API_TOKEN"],
              let databaseID = ProcessInfo.processInfo.environment["NOTION_DATABASE_ID"] else {
            print("Error: Notion API Token or Database ID not found in environment variables")
            return
        }

        // Replace with your actual Notion API token and database ID
        //let notionToken = "NOTION_API_TOKEN"
        //let databaseID = "NOTION_DABATASE_ID"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.addValue("Bearer \(notionToken)", forHTTPHeaderField: "Authorization")

        let json: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": [
                "Title": [
                    "title": [
                        ["text": ["content": text]]
                    ]
                ]
            ]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: json, options: [])
            request.httpBody = jsonData
        } catch {
            print("Error: Cannot create JSON from input")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Error: \(error.localizedDescription)")
                return
            }
            guard data != nil else {
                print("Error: No data received")
                return
            }
            print("Success: Data sent to Notion")
        }
        task.resume()
    }

    func hideWindow() {
        if let window = NSApplication.shared.windows.first {
            window.orderOut(nil)
        }
    }
}

// Helper for visual effect (blur background)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
