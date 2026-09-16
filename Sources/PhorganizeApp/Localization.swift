import Foundation

enum L10n {
    static func string(_ key: String) -> String {
        #if SWIFT_PACKAGE
        NSLocalizedString(key, bundle: .module, comment: "")
        #else
        NSLocalizedString(key, bundle: .main, comment: "")
        #endif
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
