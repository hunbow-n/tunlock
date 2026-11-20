import Foundation

/// Two languages, picked from the system: Russian, otherwise English.
let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false

func L(_ en: String, _ ru: String) -> String { isRussian ? ru : en }
