import Contacts
import MessageArchiverCore

/// Names for phone numbers and emails come from Contacts, if the user allows it (spec §4).
/// Without it, everything still works and shows the raw numbers and emails.
enum ContactsAccess {
    enum Status: Equatable {
        case notAsked, allowed, denied, restricted
    }

    static var status: Status {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: .notAsked
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .allowed
        }
    }

    /// Shows macOS's own prompt the first time; afterwards it only reports the answer.
    static func request() async -> Status {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return status
    }

    /// Every card with a name and at least one phone number or email. Only read, never changed.
    static func cards() async -> [ContactCard] {
        guard status == .allowed else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let keys: [CNKeyDescriptor] = [
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
            ]
            var cards: [ContactCard] = []
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let handles = contact.phoneNumbers.map(\.value.stringValue) + contact.emailAddresses.map { $0.value as String }
                let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
                guard !handles.isEmpty, !name.isEmpty else { return }
                cards.append(ContactCard(id: contact.identifier, name: name, handles: handles))
            }
            return cards
        }.value
    }

    /// System Settings › Privacy & Security › Contacts.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
}
