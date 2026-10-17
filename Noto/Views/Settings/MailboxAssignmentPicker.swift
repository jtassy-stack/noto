import SwiftUI

/// "Ces mails concernent : Tous les enfants / <prénom> / Parent".
/// Shared by every "add a mailbox" flow and by the account rows in
/// Réglages > Boîtes mail, so the options read the same everywhere.
struct MailboxAssignmentPicker: View {
    @Binding var selection: MailboxAssignment
    let children: [Child]

    var body: some View {
        HStack {
            Text("Ces mails concernent")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Spacer()
            Picker("Ces mails concernent", selection: $selection) {
                ForEach(MailboxAssignmentOption.options(for: children), id: \.assignment) { option in
                    Text(option.label).tag(option.assignment)
                }
            }
            .pickerStyle(.menu)
            .tint(NotoTheme.Colors.cobalt)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, NotoTheme.Spacing.sm)
        .background(NotoTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
    }
}

/// One entry of the assignment menu.
struct MailboxAssignmentOption {
    let assignment: MailboxAssignment
    let label: String

    /// "Tous les enfants", then each child by first name, then "Parent".
    static func options(for children: [Child]) -> [MailboxAssignmentOption] {
        [MailboxAssignmentOption(assignment: .allChildren, label: MailboxRouting.allChildrenLabel)]
            + children.map {
                MailboxAssignmentOption(assignment: .child(id: MailboxRouting.childKey($0)), label: $0.firstName)
            }
            + [MailboxAssignmentOption(assignment: .parent, label: MailboxRouting.parentLabel)]
    }
}
