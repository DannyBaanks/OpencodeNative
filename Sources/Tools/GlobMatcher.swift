import Foundation

/// Un matcher de patrones glob simple y puro (sin dependencias).
///
/// Soporte:
/// - `*`      : cero o más caracteres excepto `/`
/// - `?`      : exactamente un carácter excepto `/`
/// - `**/`    : cualquier número de directorios intermedios (incluido cero)
/// - `.` se escapa literalmente
///
/// Es una reescritura nativa del behaviour de `minimatch`/`glob` npm, NO una import.
/// Es pública de manera que pueda testearse directamente.
public enum GlobMatcher {
    /// Devuelve `true` si `path` coincide con `pattern` (path relativo o absoluto).
    public static func match(_ pattern: String, _ path: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: patternToRegex(pattern), options: []) else {
            return false
        }
        let nsRange = NSRange(path.startIndex..<path.endIndex, in: path)
        // Anclamos la coincidencia a la cadena completa.
        guard regex.firstMatch(in: path, range: nsRange) != nil else { return false }
        // NSRegularExpression.firstMatch sin anchor: verificar que coincide toda la cadena.
        // El patrón regex ya está anclado con ^...$; lo validamos manualmente:
        return matchesFull(patternToRegex(pattern), path)
    }
    
    /// Convertir glob -> regex anclado (^...$).
    public static func patternToRegex(_ pattern: String) -> String {
        var out = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let next = pattern.index(after: i)
            let ch = pattern[i]
            // `**/` => ((.*/)?)
            if ch == "*", next < pattern.endIndex, pattern[next] == "*",
               pattern.index(after: next) < pattern.endIndex,
               pattern[pattern.index(after: next)] == "/" {
                out += "(.*/)?"
                i = pattern.index(after: next)  // skip second *
                i = pattern.index(after: i)     // skip /
                continue
            }
            switch ch {
            case "*": out += "[^/]*"
            case "?": out += "[^/]"
            case ".", "+", "(", ")", "{", "}", "|", "^", "$", "\\": out += "\\" + String(ch)
            case "/", "_", "-":
                out += "\\" + String(ch)
            default:
                if ch.isLetter || ch.isNumber { out += String(ch) }
                else { out += NSRegularExpression.escapedPattern(for: String(ch)) }
            }
            i = pattern.index(after: i)
        }
        return "^" + out + "$"
    }
    
    private static func matchesFull(_ rx: String, _ path: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: rx, options: []) else { return false }
        let nsRange = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, range: nsRange) != nil
    }
}
