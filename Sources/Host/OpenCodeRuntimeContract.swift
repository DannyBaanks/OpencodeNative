import Foundation

/// Contrato estático del *runtime* que el TUI real de OpenCode requiere del host.
///
/// **Evidencia** (referencias al repositorio `anomalyco/opencode@dev`):
/// cada entrada declara la dependencia exacta del repo OpenCode que la motiva.
/// No es especulación: son imports/dependencias textuales de `package.json`.
///
/// Esta es una capa de COMPATIBILIDAD, no una imitación de OpenCode.
public enum OpenCodeRuntimeContract {
    /// Identificadores de capability requerida por el binario OpenCode.
    public enum Requirement: String, CaseIterable, Sendable {
        case nativeExecutable          // C1
        case bunRuntime                // C2
        case ptyTTY                    // C3 + C10
        case spawnExec                 // C4
        case nodeFsAndWatch            // C5
        case sqliteBun                 // C6
        case treeSitterNative          // C7
        case networkTLSWS              // C8
        case posixEnv                  // C9

        /// Descripción humana de la capability.
        public var label: String {
            switch self {
            case .nativeExecutable:  return "Executable nativo para el ABI del host"
            case .bunRuntime:        return "Runtime JavaScript compatible Bun 1.3.x"
            case .ptyTTY:            return "PTY + TTY raw mode (render TUI ANSI)"
            case .spawnExec:         return "spawn/exec de procesos (bash tool)"
            case .nodeFsAndWatch:    return "node:fs + fs.watch + glob"
            case .sqliteBun:         return "SQLite variante Bun (@effect/sql-sqlite-bun)"
            case .treeSitterNative:  return "tree-sitter parsers nativos"
            case .networkTLSWS:      return "Red TLS + WebSocket + mDNS"
            case .posixEnv:          return "Entorno POSIX (SHELL/HOME/XDG/EDITOR)"
            }
        }

        /// Cita exacta del repo OpenCode que prueba que esa capability es requerida.
        public var evidence: String {
            switch self {
            case .nativeExecutable:
                return "install script: solo linux/darwin/win × {x64,arm64}; cualquier otro OS/Arch → 'Unsupported OS/Arch' + exit 1"
            case .bunRuntime:
                return "package.json raíz: \"packageManager\": \"bun@1.3.14\"; \"@types/bun\": 1.3.13; bunfig.toml; postinstall fix-node-pty"
            case .ptyTTY:
                return "raíz catalog: \"@lydell/node-pty\": \"1.2.0-beta.12\"; TUI deps \"@opentui/core|keymap|solid\""
            case .spawnExec:
                return "raíz catalog: \"cross-spawn\": \"7.0.6\"; packages/opencode deps incluye cross-spawn"
            case .nodeFsAndWatch:
                return "packages/opencode deps: \"@effect/platform-node\", \"@parcel/watcher\", \"chokidar\", \"minimatch\", \"glob\""
            case .sqliteBun:
                return "raíz catalog: \"@effect/sql-sqlite-bun\"; imports #db { bun: ./src/storage/db.bun.ts }"
            case .treeSitterNative:
                return "packages/opencode deps: tree-sitter-bash, tree-sitter-powershell, web-tree-sitter (trustedDependencies necesita build nativo)"
            case .networkTLSWS:
                return "packages/opencode deps: \"ws\", \"bonjour-service\", \"@octokit/rest\", 20+ @ai-sdk/* providers"
            case .posixEnv:
                return "install script lee $SHELL/$HOME/$XDG_CONFIG_HOME/$TMPDIR y edita .bashrc/.zshrc"
            }
        }
    }

    /// Versión del contrato OpenCode referenciada (package.json de packages/opencode).
    public static let openCodeVersion = "1.18.19"
    /// Licencia del repo OpenCode (ver `docs/OPENCODE_COMPAT.md` §10 atribución).
    public static let openCodeLicense = "MIT"
}
