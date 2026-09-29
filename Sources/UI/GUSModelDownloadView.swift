import SwiftUI

public struct GUSModelDownloadView: View {
    @ObservedObject private var manager: GUSModelDownloadManager
    @EnvironmentObject private var store: WorkbenchStore
    @State private var dualSmolEnabled = GUSDualModelExperimentSettings.isEnabled
    @State private var isApplyingDualSmol = false
    @State private var modelPendingDeletion: String?

    public init(manager: GUSModelDownloadManager = .shared) { self.manager = manager }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GUS · modelos locales")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
            Text("Elige y descarga un modelo aprobado. Los tres usan el mismo rol de GUS; solo cambia el modelo local. Los archivos no se incluyen en la app.")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Text("Las descargas pueden continuar con la app suspendida o la pantalla bloqueada. Si fuerzas el cierre desde el selector de apps, iOS cancela la transferencia; al volver podrás reintentar.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Text("GUS local sigue en modo orientación: sin herramientas, permisos nuevos ni fallback remoto.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(IysThemePreferences.active.accent)

            ForEach(GUSModelManifest.all) { manifest in
                modelCard(manifest)
            }

            dualSmolControls
        }
        .padding(12)
        .background(OCColor.bgBase)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(IysThemePreferences.active.accent.opacity(0.35), lineWidth: 1))
        .confirmationDialog("Eliminar modelo descargado", isPresented: Binding(
            get: { modelPendingDeletion != nil }, set: { if !$0 { modelPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                if let id = modelPendingDeletion { manager.deleteModel(modelID: id) }
                modelPendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) { modelPendingDeletion = nil }
        } message: {
            Text("Se eliminará solo este modelo del iPhone. Los demás modelos se conservarán.")
        }
        .task {
            await manager.refresh()
            dualSmolEnabled = GUSDualModelExperimentSettings.isEnabled
        }
    }

    private var dualSmolControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Dual-Smol · experimental", isOn: $dualSmolEnabled)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .disabled(!bothDualModelsReady && !dualSmolEnabled)

            Text("Smol solo clasifica; Qwen sigue respondiendo. Es experimental y no garantiza estabilidad ni menor uso de memoria.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !bothDualModelsReady {
                let missing = [GUSModelManifest.qwen25Q4KM, GUSModelManifest.smolLM2Q4KM]
                    .filter { !isModelReady($0.id) }
                    .map(\.modelName)
                    .joined(separator: " · ")
                Text("Falta descargar y verificar: \(missing). Usa los botones de descarga de arriba.")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task {
                    isApplyingDualSmol = true
                    _ = await store.setDualSmolEnabled(dualSmolEnabled)
                    dualSmolEnabled = GUSDualModelExperimentSettings.isEnabled
                    isApplyingDualSmol = false
                }
            } label: {
                HStack {
                    if isApplyingDualSmol { ProgressView().tint(.white) }
                    Text(dualSmolEnabled ? "Aplicar Dual-Smol" : "Desactivar y liberar Smol")
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(dualSmolEnabled
                ? "Carga secuencialmente Qwen y Smol en el sandbox. Qwen seguirá respondiendo."
                : "Descarga Smol de memoria; conserva el GGUF verificado en el dispositivo.")
            .disabled(isApplyingDualSmol || (dualSmolEnabled && !bothDualModelsReady))
        }
        .padding(10)
        .background(OCColor.bgDeep)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(IysThemePreferences.active.accent.opacity(0.28), lineWidth: 1))
    }

    private var bothDualModelsReady: Bool {
        isModelReady(GUSModelManifest.qwen25Q4KM.id) && isModelReady(GUSModelManifest.smolLM2Q4KM.id)
    }

    private func isModelReady(_ modelID: String) -> Bool {
        guard case .ready? = manager.state(for: modelID) else { return false }
        return manager.modelURL(id: modelID) != nil
    }

    @ViewBuilder
    private func modelCard(_ manifest: GUSModelManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu").foregroundColor(IysThemePreferences.active.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(manifest.modelName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("GGUF · \(manifest.byteCount / 1_000_000) MB · \(manifest.licenseName)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                if manager.selectedModelID == manifest.id {
                    Label("Activo", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(IysThemePreferences.active.accent)
                }
            }

            HStack(spacing: 12) {
                Link("Fuente / revisión", destination: URL(string: "https://huggingface.co/\(manifest.repository)/tree/\(manifest.revision)")!)
                Link("Licencia", destination: manifest.licenseURL)
            }
            .font(.system(size: 9, design: .monospaced))

            Text("SHA-256  \(manifest.sha256)")
                .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                .textSelection(.enabled)
            Text(manifest.attribution)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)

            stateControls(for: manifest)
        }
        .padding(10)
        .background(OCColor.bgDeep)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(IysThemePreferences.active.accent.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func stateControls(for manifest: GUSModelManifest) -> some View {
        switch manager.state(for: manifest.id) ?? .notDownloaded {
        case .notDownloaded:
            Button { Task { await manager.startDownload(modelID: manifest.id) } } label: {
                Label("Descargar · \(manifest.byteCount / 1_000_000) MB", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                HStack {
                    Text("Descargando · \(Int(progress * 100))%")
                    Spacer()
                    Button("Cancelar") { manager.cancelDownload(modelID: manifest.id) }
                }
            }
            .font(.system(size: 10, design: .monospaced))
        case .verifying:
            Label("Verificando tamaño y SHA-256…", systemImage: "checkmark.shield")
                .font(.system(size: 10, design: .monospaced))
        case .ready:
            HStack {
                Button(manager.selectedModelID == manifest.id ? "Modelo seleccionado" : "Usar este modelo") {
                    manager.selectModel(modelID: manifest.id)
                }
                .disabled(manager.selectedModelID == manifest.id)
                .buttonStyle(.borderedProminent)
                Button("Eliminar", role: .destructive) { modelPendingDeletion = manifest.id }
                    .buttonStyle(.bordered)
            }
        case .failed(let error):
            Text(error.localizedDescription)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.red)
            Button("Reintentar") { Task { await manager.startDownload(modelID: manifest.id) } }
                .buttonStyle(.bordered)
        }
    }
}
