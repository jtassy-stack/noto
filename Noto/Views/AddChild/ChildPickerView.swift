import SwiftUI

/// Lets the parent select which children to add from a multi-child Pronote account.
struct ChildPickerView: View {
    let children: [PronoteChildResource]
    let schoolType: SchoolType
    let serverURL: String
    let onSelect: ([PronoteChildResource]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(children, id: \.id) { child in
                Button {
                    if selected.contains(child.id) {
                        selected.remove(child.id)
                    } else {
                        selected.insert(child.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                            Text(child.name)
                                .font(NotoTheme.Typography.headline)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text("\(child.className) — \(child.establishment)")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }

                        Spacer()

                        if selected.contains(child.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(NotoTheme.Colors.brand)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Sélectionner les enfants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ajouter") {
                        let selectedChildren = children.filter { selected.contains($0.id) }
                        onSelect(selectedChildren)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear {
                // Pre-select all children
                selected = Set(children.map(\.id))
            }
        }
    }
}
