import SwiftUI
import Security
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var inputText: String = ""
}

struct ContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @FocusState private var isFocused: Bool
    @State private var isDraggingOver = false
    @State private var selectedImages: [URL] = []

    var body: some View {
        VStack {
            HStack {
                // Paperclip Icon Button
                Button(action: {
                    openFilePicker()
                }) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 24))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading)

                // Custom Non-Droppable Text Field
                NonDroppableTextField(text: $viewModel.inputText, placeholder: "Clear your head", onCommit: {
                    let trimmedText = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty || !selectedImages.isEmpty {
                        sendDataToNotion(text: trimmedText)
                        resetState()
                    }
                    hideWindow()
                })
                .focused($isFocused)
                .frame(height: 30)
            }
            .padding()
            .background(Color.clear)

            // Display Selected Images
            if !selectedImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(selectedImages, id: \.self) { imageURL in
                            ImageThumbnailView(imageURL: imageURL, removeAction: {
                                if let index = selectedImages.firstIndex(of: imageURL) {
                                    selectedImages.remove(at: index)
                                }
                            })
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(width: 600)
        .padding()
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .cornerRadius(12)
        )
        // Apply onDrop to the entire VStack
        .onDrop(of: [UTType.image], isTargeted: $isDraggingOver, perform: handleDrop)
        // Dotted line overlay
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDraggingOver ? Color.blue : Color.clear, style: StrokeStyle(lineWidth: 2, dash: [5]))
        )
        // Reset state when window disappears
        .onDisappear {
            resetState()
        }
        // Listen for ResetState notification
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ResetState"))) { _ in
            resetState()
        }
    }

    // Method to reset the state
    func resetState() {
        viewModel.inputText = ""
        selectedImages.removeAll()
    }

    // Open File Picker
    func openFilePicker() {
        guard let window = NSApplication.shared.windows.first else { return }
        window.orderOut(nil) // Hide the dialog box

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.image] // Accept images only

        panel.begin { response in
            if response == .OK {
                self.selectedImages.append(contentsOf: panel.urls)
            }
            window.makeKeyAndOrderFront(nil) // Show the dialog box again
            NSApp.activate(ignoringOtherApps: true)
            self.isFocused = true // Refocus the text field
        }
    }

    // Handle Image Drop
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (item, error) in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            self.selectedImages.append(url)
                        }
                    } else if let data = item as? Data,
                              let image = NSImage(data: data) {
                        // Save the image to a temporary location
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = UUID().uuidString + ".png"
                        let fileURL = tempDir.appendingPathComponent(filename)
                        let imageData = image.tiffRepresentation
                        do {
                            try imageData?.write(to: fileURL)
                            DispatchQueue.main.async {
                                self.selectedImages.append(fileURL)
                            }
                        } catch {
                            print("Error saving dropped image: \(error)")
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    func sendDataToNotion(text: String) {
        print("sendDataToNotion called with text: '\(text)'")
        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            print("Invalid URL")
            return
        }

        // Retrieve Notion API token and Database ID from Keychain
        guard let notionToken = getNotionAPIToken(),
              let databaseID = getNotionDatabaseID() else {
            DispatchQueue.main.async {
                showAlert(message: "Notion API Token or Database ID not found in Keychain. Please add them to your Keychain.")
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.addValue("Bearer \(notionToken)", forHTTPHeaderField: "Authorization")

        let dispatchGroup = DispatchGroup()
        var imageBlocks: [[String: Any]] = []

        // Upload images to Imgur and create image blocks
        for imageURL in selectedImages {
            dispatchGroup.enter()
            uploadImageToImgur(fileURL: imageURL) { publicURL in
                if let publicURL = publicURL {
                    let imageBlock: [String: Any] = [
                        "object": "block",
                        "type": "image",
                        "image": [
                            "type": "external",
                            "external": [
                                "url": publicURL
                            ]
                        ]
                    ]
                    imageBlocks.append(imageBlock)
                }
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            var json: [String: Any] = [
                "parent": ["database_id": databaseID],
                "properties": [
                    "Title": [
                        "title": [
                            ["text": ["content": text]]
                        ]
                    ]
                ],
                "children": imageBlocks
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
    }

    func uploadImageToImgur(fileURL: URL, completion: @escaping (String?) -> Void) {
        guard let clientID = getImgurClientID() else {
            print("Imgur Client ID not found in Keychain.")
            completion(nil)
            return
        }
        guard let imageData = try? Data(contentsOf: fileURL) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: URL(string: "https://api.imgur.com/3/image")!)
        request.httpMethod = "POST"
        request.addValue("Client-ID \(clientID)", forHTTPHeaderField: "Authorization")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Image data
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/\(fileURL.pathExtension)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Imgur upload error: \(error)")
                completion(nil)
                return
            }
            guard let data = data else {
                print("No data received from Imgur")
                completion(nil)
                return
            }
            do {
                let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
                if let json = jsonObject as? [String: Any],
                   let dataDict = json["data"] as? [String: Any],
                   let link = dataDict["link"] as? String {
                    completion(link)
                } else {
                    print("Invalid JSON response from Imgur")
                    completion(nil)
                }
            } catch {
                print("JSON parsing error: \(error)")
                completion(nil)
            }
        }
        task.resume()
    }

    func getNotionAPIToken() -> String? {
        return getPasswordFromKeychain(service: "NotionAPIToken", account: "Notion")
    }

    func getNotionDatabaseID() -> String? {
        return getPasswordFromKeychain(service: "NotionDatabaseID", account: "Notion")
    }

    func getImgurClientID() -> String? {
        return getPasswordFromKeychain(service: "ImgurClientID", account: "Imgur")
    }

    func getPasswordFromKeychain(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8) else {
            print("Error retrieving \(service) from Keychain")
            return nil
        }

        return password
    }

    func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

// View for displaying image thumbnails with a delete button
struct ImageThumbnailView: View {
    let imageURL: URL
    let removeAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: NSImage(contentsOf: imageURL) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 50)

            if isHovering {
                Button(action: {
                    removeAction()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .offset(x: -5, y: 5)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
