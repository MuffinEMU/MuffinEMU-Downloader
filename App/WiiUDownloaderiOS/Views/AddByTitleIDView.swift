import SwiftUI
import WUDCore

struct AddByTitleIDView: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (TitleEntry) -> Void

    @State private var titleIDHex = ""
    @State private var name = ""
    @State private var versionText = ""

    /// Empty = latest; otherwise a TMD version code.
    private var version: Int? {
        let trimmed = versionText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return versionLatest }
        guard let v = Int(trimmed), v >= 0, v <= 0xFFFF else { return nil }
        return v
    }

    private var isValid: Bool {
        titleIDHex.count == 16 && UInt64(titleIDHex, radix: 16) != nil && version != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title ID") {
                    TextField("0005000E1010EC00", text: $titleIDHex)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Name (optional)", text: $name)
                }
                Section {
                    TextField("Latest", text: $versionText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Version")
                } footer: {
                    Text("Leave empty for the latest version.")
                }
                if !titleIDHex.isEmpty, titleIDHex.count != 16 || UInt64(titleIDHex, radix: 16) == nil {
                    Text("Title ID must be 16 hex characters.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Add by Title ID")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let tid = UInt64(titleIDHex, radix: 16) else { return }
                        let entry = TitleEntry(name: name, titleID: tid, region: 0, key: 0, category: .all, version: version ?? versionLatest)
                        onAdd(entry)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
