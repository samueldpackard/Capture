import SwiftUI
import Security
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject {
    @Published var isFocused: Bool = false
    @Published var inputText: String = ""
    @Published var selectedImages: [URL] = [] // Moved selectedImages here
}

struct ContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @FocusState private var isFocused: Bool
    @State private var isDraggingOver = false

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

                // Standard TextField
                TextField("Clear your head", text: $viewModel.inputText, onCommit: {
                    let trimmedText = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedText.isEmpty || !viewModel.selectedImages.isEmpty {
                        sendDataToNotion(text: trimmedText)
                        resetState()
                    }
                    hideWindow()
                })
                .focused($isFocused)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 24))
                .padding(.leading, 5)
                .frame(height: 30)
            }
            .padding()
            .background(Color.clear)

            // Display Selected Images using a separate view
            if !viewModel.selectedImages.isEmpty {
                ImageThumbnailsView(selectedImages: viewModel.selectedImages, removeAction: { imageURL in
                    if let index = viewModel.selectedImages.firstIndex(of: imageURL) {
                        viewModel.selectedImages.remove(at: index)
                    }
                })
            }
        }
        .frame(width: 600)
        .padding()
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .cornerRadius(12)
        )
        // Apply onDrop to the entire VStack
        .onDrop(of: [UTType.fileURL], isTargeted: $isDraggingOver, perform: handleDrop)
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
        viewModel.selectedImages.removeAll()
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
                viewModel.selectedImages.append(contentsOf: panel.urls)
            }
            window.makeKeyAndOrderFront(nil) // Show the dialog box again
            NSApp.activate(ignoringOtherApps: true)
            self.isFocused = true // Refocus the text field
        }
    }

    // Handle Image Drop
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (item, error) in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            viewModel.selectedImages.append(url)
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
                                viewModel.selectedImages.append(fileURL)
                            }
                        } catch {
                            print("Error saving dropped image: \(error)")
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    func sendDataToNotion(text: String) {
        print("sendDataToNotion called with text: '\(text)'")
        guard let url = URL(string: "https://api.notion.com/v1/pages") else {
            print("Invalid URL")
            return
        }

        // Retrieve Notion API token and Database ID from Keychain
        guard let notionToken = getPasswordFromKeychain(service: "NotionAPIToken", account: "Notion"),
              let databaseID = getPasswordFromKeychain(service: "NotionDatabaseID", account: "Notion") else {
            // Credentials are being requested asynchronously; wait and retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.sendDataToNotion(text: text)
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
        for imageURL in viewModel.selectedImages {
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
        guard let clientID = getPasswordFromKeychain(service: "ImgurClientID", account: "Imgur") else {
            // Prompt for Imgur Client ID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.uploadImageToImgur(fileURL: fileURL, completion: completion)
            }
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
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: image/\(fileURL.pathExtension)\r\n\r\n")
        body.append(imageData)
        body.append("\r\n")

        // Close boundary
        body.append("--\(boundary)--\r\n")

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

    // MARK: - Keychain Access Functions

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

        if status == errSecSuccess,
           let data = item as? Data,
           let password = String(data: data, encoding: .utf8) {
            return password
        } else {
            // Prompt for input and store in Keychain
            promptForKeychainEntry(service: service, account: account)
            return nil
        }
    }

    func promptForKeychainEntry(service: String, account: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Enter \(service)"
            alert.informativeText = "Please enter your \(service) for \(account):"
            alert.alertStyle = .informational

            let inputField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            alert.accessoryView = inputField
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let input = inputField.stringValue
                // Store in Keychain
                self.storePasswordInKeychain(service: service, account: account, password: input)
            }
        }
    }

    func storePasswordInKeychain(service: String, account: String, password: String) {
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("Error storing \(service) in Keychain: \(status)")
        }
    }

    func showAlert(message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
struct ImageThumbnailsView: View {
    let selectedImages: [URL]
    let removeAction: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack {
                ForEach(selectedImages, id: \.self) { imageURL in
                    ImageThumbnailView(imageURL: imageURL, removeAction: {
                        removeAction(imageURL)
                    })
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 60)
    }
}

// Optimized Image Thumbnail View
struct ImageThumbnailView: View {
    let imageURL: URL
    let removeAction: () -> Void
    @State private var isHovering = false
    @State private var thumbnailImage: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = thumbnailImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 50)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .onAppear {
                        loadThumbnail()
                    }
            }

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

    func loadThumbnail() {
        DispatchQueue.global(qos: .background).async {
            if let image = NSImage(contentsOf: imageURL) {
                let resizedImage = resizeImage(image: image, maxSize: NSSize(width: 50, height: 50))
                DispatchQueue.main.async {
                    self.thumbnailImage = resizedImage
                }
            }
        }
    }

    func resizeImage(image: NSImage, maxSize: NSSize) -> NSImage {
        let aspectRatio = image.size.width / image.size.height
        var newSize = maxSize

        if aspectRatio > 1 {
            newSize.height = maxSize.width / aspectRatio
        } else {
            newSize.width = maxSize.height * aspectRatio
        }

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

// Extension to append Data
extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
