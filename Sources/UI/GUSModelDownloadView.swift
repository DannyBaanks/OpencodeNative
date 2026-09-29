import SwiftUI

public struct GUSModelDownloadView: View {
    @ObservedObject private var manager: GUSModelDownloadManager
    @State private var confirmDelete = false

    public init(manager: GUSModelDownloadManager = .shared) { self.manager = manager }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundColor(IysThemePreferences.active.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.manifest.modelName).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("Qwen · GGUF · Q4_K_M · 1.22 GB")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            Text("Descarga opcional y manual. El modelo se guarda en el iPhone, fuera del IPA. En modo local, tus mensajes no se envían a un proveedor.")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Text("Versión inicial de GUS: solo orientación. No ejecuta herramientas ni modifica archivos.")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(IysThemePreferences.active.accent)
            Text("Archivo GGUF de Qwen; uploader de esta revisión: JustinLin610. Licencia no comercial.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            HStack(spacing: 14) {
                Link("Ver modelo y revisión", destination: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/tree/\(manager.manifest.revision)")!)
                Link("Licencia", destination: URL(string: "https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/blob/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/LICENSE")!)
            }
            .font(.system(size: 11, design: .monospaced))
            Text("SHA-256  \(manager.manifest.sha256)")
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                .textSelection(.enabled)

            switch manager.state {
            case .notDownloaded:
                Button { Task { await manager.startDownload() } } label: {
                    Label("Descargar modelo (requiere ~1.32 GB libres)", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            case .downloading(let progress):
                ProgressView(value: progress)
                HStack {
                    Text("Descargando · \(Int(progress * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Button("Cancelar") { manager.cancelDownload() }
                        .font(.system(size: 11, design: .monospaced))
                }
            case .verifying:
                ProgressView("Verificando tamaño y SHA-256…")
                    .font(.system(size: 11, design: .monospaced))
            case .ready:
                Label("Modelo verificado en este iPhone", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.green)
                Button("Eliminar modelo descargado", role: .destructive) { confirmDelete = true }
                    .font(.system(size: 11, design: .monospaced))
                    .confirmationDialog("¿Eliminar el modelo local?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Eliminar modelo", role: .destructive) { manager.deleteModel() }
                        Button("Cancelar", role: .cancel) {}
                    }
            case .failed(let error):
                Text(error.localizedDescription)
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(.red)
                Button("Reintentar descarga") { Task { await manager.startDownload() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(OCColor.bgBase)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(IysThemePreferences.active.accent.opacity(0.35), lineWidth: 1))
        .task { await manager.refresh() }
    }
}
