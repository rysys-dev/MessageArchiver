import Foundation

/// Puts phone numbers in E.164 (`+18055551234`) and emails in lower case, so a number as
/// Messages stores it and the same number as Contacts shows it compare equal (spec §8).
///
/// Messages already stores most phone handles in E.164; Contacts holds them as typed
/// ("(805) 555-1234", "0207 946 0000"). A number without a country code is read as the Mac's
/// region. Short codes (6 digits or fewer, e.g. a bank's "72975") are left as digits.
public enum PhoneNumber {
    public static func normalize(_ raw: String, region: String? = Locale.current.region?.identifier) -> String {
        // Contacts wraps some numbers in invisible direction marks (U+202A … U+202C).
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed.lowercased() }

        let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty, trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || separators.contains($0) }) else {
            return trimmed.lowercased()
        }
        if trimmed.hasPrefix("+") { return "+" + digits }
        if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
        if digits.count <= 6 { return digits }

        let code = callingCodes[region ?? "US"] ?? "1"
        if code == "1" {
            if digits.count == 10 { return "+1" + digits }
            if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
            return digits
        }
        // Elsewhere a leading 0 is the trunk prefix, dropped after the country code — except in
        // Italy, where it is part of the number.
        let national = (digits.hasPrefix("0") && region != "IT") ? String(digits.dropFirst()) : digits
        return "+" + code + national
    }

    static let separators: Set<Character> = [" ", "+", "-", "(", ")", ".", "·", "/", "\u{00A0}", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}"]

    static let callingCodes: [String: String] = [
        "US": "1", "CA": "1", "PR": "1", "GU": "1", "VI": "1", "BS": "1", "JM": "1",
        "GB": "44", "IE": "353", "AU": "61", "NZ": "64", "ZA": "27", "IN": "91", "SG": "65",
        "HK": "852", "PH": "63", "JP": "81", "KR": "82", "CN": "86", "TW": "886",
        "FR": "33", "DE": "49", "ES": "34", "IT": "39", "PT": "351", "NL": "31", "BE": "32",
        "LU": "352", "CH": "41", "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358",
        "IS": "354", "PL": "48", "CZ": "420", "GR": "30", "IL": "972", "TR": "90",
        "MX": "52", "BR": "55", "AR": "54", "CL": "56", "CO": "57", "PE": "51",
        "AE": "971", "SA": "966",
    ]
}
