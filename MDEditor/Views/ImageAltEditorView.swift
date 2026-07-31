import SwiftUI

/// Alt-text/title editor for an image attachment, shown in a popover.
/// Thin UI: all logic lives in `ImageAttachmentController.applyAltEdit`.
struct ImageAltEditorView: View {
    @State private var altText: String
    @State private var title: String

    /// Called with the edited values (alt text, title).
    let onApply: (String, String) -> Void
    let onCancel: () -> Void

    init(
        altText: String,
        title: String,
        onApply: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _altText = State(initialValue: altText)
        _title = State(initialValue: title)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Image Description")
                .font(.headline)
            TextField("Alt Text", text: $altText)
            TextField("Title (optional)", text: $title)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onApply(altText, title) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
