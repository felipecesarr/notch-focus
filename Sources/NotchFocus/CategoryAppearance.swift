import SwiftUI

extension TaskCategory {
    var title: String {
        switch self {
        case .study: return "Study"
        case .work: return "Work"
        case .creative: return "Creative"
        case .personal: return "Personal"
        }
    }

    var symbol: String {
        switch self {
        case .study: return "book.pages"
        case .work: return "briefcase"
        case .creative: return "paintbrush.pointed"
        case .personal: return "leaf"
        }
    }

    var tint: Color {
        switch self {
        case .study: return Color(red: 0.78, green: 0.72, blue: 0.96)
        case .work: return Color(red: 0.66, green: 0.82, blue: 0.96)
        case .creative: return Color(red: 0.98, green: 0.76, blue: 0.62)
        case .personal: return Color(red: 0.65, green: 0.85, blue: 0.74)
        }
    }
}
