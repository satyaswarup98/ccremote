import SwiftUI
import PhotosUI
import UIKit

// Images picked in the message bar. They're shrunk on the phone before sending, so a message with
// a few photos stays small; the Mac saves them and gives Claude their file paths.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let preview: UIImage
    let jpeg: Data

    init?(_ image: UIImage) {
        guard let data = Self.prepare(image), let small = UIImage(data: data) else { return nil }
        preview = small
        jpeg = data
    }

    // Longest side at most 2048 px, JPEG quality 0.8: plenty for Claude to read screenshots and photos.
    static func prepare(_ image: UIImage, maxSide: CGFloat = 2048) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

/// Small removable thumbnails shown above the message box.
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { a in
                    Image(uiImage: a.preview)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { attachments.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                    .frame(width: 22, height: 22)
                                    .foregroundStyle(.white)
                                    .glassEffect(.clear.tint(.black.opacity(0.4)).interactive(), in: Circle())
                            }
                            .offset(x: 6, y: -6)
                        }
                }
            }
            .padding(.horizontal, 4).padding(.top, 8)
        }
    }
}

/// The system camera, for "Take Photo".
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// "[Image attached from my phone: /path]" lines in a sent message, shown as a short label instead.
enum AttachedImageText {
    static let pattern = try! NSRegularExpression(pattern: #"\n*\[Image attached from my phone: [^\]]+\]"#)

    static func split(_ text: String) -> (text: String, images: Int) {
        let range = NSRange(text.startIndex..., in: text)
        let count = pattern.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        let stripped = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return (stripped.trimmingCharacters(in: .whitespacesAndNewlines), count)
    }
}
