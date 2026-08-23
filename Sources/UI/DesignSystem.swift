import SwiftUI

// MARK: - Color Tokens (OpenCode v2 → iOS Dark Mode)

public struct OCColor {
    // Core neutrals
    public static let bgDeep       = Color(hex: "080808")
    public static let bgBase       = Color(hex: "161616")
    public static let bgLayer1     = Color(hex: "242424")
    public static let bgLayer2     = Color(hex: "2E2E2E")
    public static let borderMuted  = Color(hex: "FFFFFF", opacity: 0.08)
    public static let borderBase   = Color(hex: "FFFFFF", opacity: 0.10)
    public static let borderStrong = Color(hex: "FFFFFF", opacity: 0.20)
    public static let textPrimary  = Color(hex: "F2F2F2")
    public static let textSecondary = Color(hex: "AEAEAE")
    public static let textFaint    = Color(hex: "808080")
    public static let iconPrimary  = Color(hex: "DBDBDB")
    public static let iconMuted    = Color(hex: "808080")

    // Agent / Mode colors
    public static let agentBuild   = Color(hex: "A2BCFF")
    public static let agentPlan    = Color(hex: "F799C6")
    public static let agentExplore = Color(hex: "F3DA9B")
    public static let agentReview  = Color(hex: "96E3A6")
    public static let agentCustom  = Color(hex: "9E99F7")

    public static let agentBuildSoft   = Color(hex: "A2BCFF", opacity: 0.08)
    public static let agentPlanSoft    = Color(hex: "F799C6", opacity: 0.08)
    public static let agentExploreSoft = Color(hex: "F3DA9B", opacity: 0.08)
    public static let agentReviewSoft  = Color(hex: "96E3A6", opacity: 0.08)
    public static let agentCustomSoft  = Color(hex: "9E99F7", opacity: 0.08)

    public static let agentBuildBorder   = Color(hex: "A2BCFF", opacity: 0.20)
    public static let agentPlanBorder    = Color(hex: "F799C6", opacity: 0.30)
    public static let agentExploreBorder = Color(hex: "F3DA9B", opacity: 0.30)
    public static let agentReviewBorder  = Color(hex: "96E3A6", opacity: 0.30)
    public static let agentCustomBorder  = Color(hex: "9E99F7", opacity: 0.30)

    // Syntax & Diff
    public static let diffAddFg      = Color(hex: "C4FFC0")
    public static let diffDeleteFg   = Color(hex: "EC2F14")
    public static let syntaxComment  = Color(hex: "8F8F8F")
    public static let syntaxKeyword  = Color(hex: "EDB2F1")
    public static let syntaxString   = Color(hex: "00CEB9")
    public static let syntaxPrimitive = Color(hex: "8CB0FF")
    public static let syntaxProperty = Color(hex: "FAB283")
    public static let syntaxType     = Color(hex: "FCD53A")

    public static let diffAddBg      = Color(hex: "14361D", opacity: 0.60)
    public static let diffDeleteBg   = Color(hex: "461516", opacity: 0.60)
    public static let diffContextBg  = Color(hex: "161616")
    public static let diffSelectedBg = Color(hex: "A2BCFF", opacity: 0.07)

    // Semantic
    public static let success        = Color(hex: "4CD97B")
    public static let warning        = Color(hex: "F7D060")
    public static let danger         = Color(hex: "FF6B6B")
    public static let info           = Color(hex: "60C8F7")

    // Liquid Glass approximations (for Figma parity; prefer system APIs in code)
    public static let glassNavFill   = Color.white.opacity(0.06)
    public static let glassNavBlur: CGFloat = 28
    public static let glassNavHighlight = Color.white.opacity(0.10)
    public static let glassNavStroke = Color.white.opacity(0.12)
    public static let glassNavShadow = Color.black.opacity(0.20)
}

extension Color {
    public init(hex: String, opacity: Double = 1.0) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Spacing Tokens

public struct OCSpacing {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 6
    public static let base: CGFloat = 8
    public static let md: CGFloat = 10
    public static let lg: CGFloat = 12
    public static let xl: CGFloat = 16
    public static let xxl: CGFloat = 20
    public static let xxxl: CGFloat = 24
    public static let huge: CGFloat = 32

    public static let contentMargin: CGFloat = 16
    public static let compactMargin: CGFloat = 12
    public static let timelineEventGap: CGFloat = 20
    public static let timelineBlockGap: CGFloat = 10
    public static let toolClusterGap: CGFloat = 6
}

// MARK: - Radius Tokens

public struct OCRadius {
    public static let r4: CGFloat  = 4
    public static let r8: CGFloat  = 8
    public static let r10: CGFloat = 10
    public static let r12: CGFloat = 12
    public static let r14: CGFloat = 14
    public static let r18: CGFloat = 18
    public static let r22: CGFloat = 22
    public static let r24: CGFloat = 24
    public static let r28: CGFloat = 28
}

// MARK: - Typography Tokens

public struct OCTypography {
    // Font families
    public static let ui = Font.system(.body, design: .default)
    public static let mono = Font.system(.body, design: .monospaced)

    // Style definitions
    public static let navTitle       = Font.system(size: 15, weight: .semibold, design: .default)
    public static let navSubtitle    = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let body           = Font.system(size: 15, weight: .regular, design: .default)
    public static let bodyStrong     = Font.system(size: 15, weight: .semibold, design: .default)
    public static let userPrompt     = Font.system(size: 15, weight: .medium, design: .default)
    public static let meta           = Font.system(size: 11, weight: .regular, design: .default)
    public static let metaMono       = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let control        = Font.system(size: 12, weight: .medium, design: .default)
    public static let controlMono    = Font.system(size: 11, weight: .medium, design: .monospaced)
    public static let code           = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let codeSmall      = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let sectionLabel   = Font.system(size: 11, weight: .semibold, design: .default)
    public static let rowPrimary     = Font.system(size: 14.5, weight: .semibold, design: .default)
    public static let rowSecondary   = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let pillLabel      = Font.system(size: 11, weight: .medium, design: .monospaced)
    public static let modelPillLabel = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let toolLabel      = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let toolDetail     = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let diffHeader     = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let diffLineNum    = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let diffCode       = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let fileRow        = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let permissionTitle = Font.system(size: 14, weight: .semibold, design: .default)
    public static let permissionBody  = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let questionChoice  = Font.system(size: 14, weight: .regular, design: .default)
    public static let todoText        = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let todoMeta        = Font.system(size: 10.5, weight: .regular, design: .monospaced)
}

// MARK: - Shadow / Elevation

public struct OCShadow {
    public static let composer = ShadowStyle(
        color: Color.black.opacity(0.18),
        radius: 18,
        x: 0,
        y: -4
    )
    public static let elevated = ShadowStyle(
        color: Color.black.opacity(0.25),
        radius: 12,
        x: 0,
        y: 4
    )
    public static let navGlass = ShadowStyle(
        color: Color.black.opacity(0.20),
        radius: 24,
        x: 0,
        y: 8
    )
}

public struct ShadowStyle {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat
}

// MARK: - Agent Mode Enum

public enum AgentMode: String, CaseIterable, Identifiable, Sendable {
    case build   = "build"
    case plan    = "plan"
    case explore = "explore"
    case review  = "review"
    case custom  = "custom"

    public var displayName: String { rawValue }

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .build:   return OCColor.agentBuild
        case .plan:    return OCColor.agentPlan
        case .explore: return OCColor.agentExplore
        case .review:  return OCColor.agentReview
        case .custom:  return OCColor.agentCustom
        }
    }

    public var softColor: Color {
        switch self {
        case .build:   return OCColor.agentBuildSoft
        case .plan:    return OCColor.agentPlanSoft
        case .explore: return OCColor.agentExploreSoft
        case .review:  return OCColor.agentReviewSoft
        case .custom:  return OCColor.agentCustomSoft
        }
    }

    public var borderColor: Color {
        switch self {
        case .build:   return OCColor.agentBuildBorder
        case .plan:    return OCColor.agentPlanBorder
        case .explore: return OCColor.agentExploreBorder
        case .review:  return OCColor.agentReviewBorder
        case .custom:  return OCColor.agentCustomBorder
        }
    }

    public var description: String {
        switch self {
        case .build:   return "Can edit files and run tools"
        case .plan:    return "Read-only exploration and planning"
        case .explore: return "Exploration and sub-agent tasks"
        case .review:  return "Review and check changes"
        case .custom:  return "Custom agent behavior"
        }
    }

    public var icon: String {
        switch self {
        case .build:   return "hammer.fill"
        case .plan:    return "doc.text.magnifyingglass"
        case .explore: return "map.fill"
        case .review:  return "checkmark.seal.fill"
        case .custom:  return "sparkles"
        }
    }
}

// MARK: - Tool Call State

public enum ToolCallState: String, Sendable {
    case running
    case success
    case failed
    case permission

    public var color: Color {
        switch self {
        case .running:    return OCColor.agentBuild
        case .success:    return OCColor.success
        case .failed:     return OCColor.danger
        case .permission: return OCColor.warning
        }
    }

    public var icon: String {
        switch self {
        case .running:    return "circle.dotted"
        case .success:    return "checkmark"
        case .failed:     return "xmark"
        case .permission: return "exclamationmark.shield"
        }
    }
}

// MARK: - Timeline Event Types

public enum TimelineEventKind: String, Sendable {
    case userPrompt
    case assistantText
    case toolCall
    case toolResult
    case diff
    case codeBlock
    case permission
    case question
    case thinking
    case todo
    case system
}

// MARK: - Work Surface

public enum WorkSurface: String, CaseIterable, Identifiable, Sendable {
    case chat    = "Chat"
    case files   = "Files"
    case review  = "Review"
    case terminal = "Terminal"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .chat:      return "bubble.left.and.bubble.right"
        case .files:     return "doc.text"
        case .review:    return "arrow.left.arrow.right"
        case .terminal:  return "terminal"
        }
    }
}

// MARK: - View Modifiers for consistent styling

public struct OCNavGlassModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .background(
                OCColor.glassNavFill
                    .background(.ultraThinMaterial)
            )
            .overlay(
                Rectangle()
                    .frame(height: 0.5)
                    .foregroundColor(OCColor.borderBase),
                alignment: .bottom
            )
    }
}

public struct OCCardStyle: ViewModifier {
    let radius: CGFloat
    let border: Color
    let background: Color

    public init(radius: CGFloat = OCRadius.r12, border: Color = OCColor.borderBase, background: Color = OCColor.bgBase) {
        self.radius = radius
        self.border = border
        self.background = background
    }

    public func body(content: Content) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(border, lineWidth: 1)
            )
    }
}

public struct OCPillStyle: ViewModifier {
    let height: CGFloat
    let radius: CGFloat
    let background: Color
    let border: Color
    let horizontalPadding: CGFloat

    public init(
        height: CGFloat = 28,
        radius: CGFloat = OCRadius.r14,
        background: Color = OCColor.bgLayer1,
        border: Color = OCColor.borderBase,
        horizontalPadding: CGFloat = 9
    ) {
        self.height = height
        self.radius = radius
        self.background = background
        self.border = border
        self.horizontalPadding = horizontalPadding
    }

    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(border, lineWidth: 1)
            )
    }
}

extension View {
    public func ocNavGlass() -> some View { modifier(OCNavGlassModifier()) }
    public func ocCard(radius: CGFloat = OCRadius.r12, border: Color = OCColor.borderBase, background: Color = OCColor.bgBase) -> some View {
        modifier(OCCardStyle(radius: radius, border: border, background: background))
    }
    public func ocPill(height: CGFloat = 28, radius: CGFloat = OCRadius.r14, background: Color = OCColor.bgLayer1, border: Color = OCColor.borderBase, horizontalPadding: CGFloat = 9) -> some View {
        modifier(OCPillStyle(height: height, radius: radius, background: background, border: border, horizontalPadding: horizontalPadding))
    }
}