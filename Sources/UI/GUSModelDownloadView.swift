import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct GUSModelDownloadView: View {
    @ObservedObject private var manager: GUSModelDownloadManager
    @EnvironmentObject private var store: WorkbenchStore
    @State private var dualSmolEnabled = GUSDualModelExperimentSettings.isEnabled
    @State private var isApplyingDualSmol = false
    @State private var modelPendingDeletion: String?
    @State private var budget = GUSDeviceBudget.current()
    @AppStorage("gus.showExperimental") private var showExperimental = false
    @State private var riskyDownload: GUSModelManifest?
    @State private var showCrashHistory = false
    @State private var benchmarkModel: GUSModelManifest?
    @State private var showImporter = false
    @State private var exportFiles: [URL] = []
    @State private var isImporting = false
    @State private var importMessage: String?

    public init(manager: GUSModelDownloadManager = .shared) { self.manager = manager }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GUS · modelos locales")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
            Text("Elige y descarga un modelo aprobado. Todos usan el mismo rol de GUS; solo cambia el modelo local. Los archivos no se incluyen en la app.")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            Text("Las descargas pueden continuar con la app suspendida o la pantalla bloqueada. Si fuerzas el cierre desde el selector de apps, iOS cancela la transferencia; al volver podrás reintentar.")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            Text("GUS local sigue en modo orientación: sin herramientas, permisos nuevos ni fallback remoto.")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(IysThemePreferences.active.accent)

            previousRunBanner
            deviceSummary

            ForEach(recommendedModels) { manifest in
                modelCard(manifest)
            }

            Toggle(isOn: $showExperimental) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mostrar modelos experimentales (\(experimentalModels.count))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("Más grandes o sin medir en iPhone. Pensados para equipos con más RAM.")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            if showExperimental {
                Text("Riesgo real y acotado: si no cabe, iOS cierra la app (sin dañar datos ni el teléfono). También puede calentarse y usar varios GB de almacenamiento. Si pasa, el informe de fallos dirá en qué fase y con cuánta memoria.")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(experimentalModels) { manifest in
                    modelCard(manifest)
                }
            }

            modelBackupControls

            Button { showCrashHistory = true } label: {
                Label("Informes de fallos", systemImage: "stethoscope")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

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
        .confirmationDialog("Modelo experimental", isPresented: Binding(
            get: { riskyDownload != nil }, set: { if !$0 { riskyDownload = nil } }
        ), titleVisibility: .visible) {
            Button("Descargar de todos modos") {
                if let manifest = riskyDownload { Task { await manager.startDownload(modelID: manifest.id) } }
                riskyDownload = nil
            }
            Button("Cancelar", role: .cancel) { riskyDownload = nil }
        } message: {
            if let manifest = riskyDownload {
                Text(riskMessage(manifest))
            }
        }
        .sheet(isPresented: $showCrashHistory) { GUSCrashHistoryView() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder, .item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                isImporting = true
                let summary = await manager.importModels(from: urls)
                isImporting = false
                importMessage = Self.describe(summary)
            }
        }
        .sheet(isPresented: Binding(get: { !exportFiles.isEmpty }, set: { if !$0 { exportFiles = [] } })) {
            GUSDocumentExporter(urls: exportFiles) { exportFiles = [] }
        }
        .sheet(item: $benchmarkModel) { manifest in
            if let url = manager.modelURL(id: manifest.id) {
                GUSBenchmarkView(manifest: manifest, modelURL: url)
            }
        }
        .task {
            budget = GUSDeviceBudget.current()
            await manager.refresh()
            dualSmolEnabled = GUSDualModelExperimentSettings.isEnabled
        }
    }

    /// Models live in the app container, which iOS wipes when the app is deleted
    /// or sideloaded again under a new identifier. A copy in Files survives that.
    private var modelBackupControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("¿Reinstalaste la app? iOS borra sus datos al eliminarla o al reinstalarla con otro identificador. Guarda una copia de tus modelos en Archivos (fuera de la carpeta de ISyCode, p. ej. En mi iPhone › Descargas) e impórtala después: se verifica el SHA-256 y no se vuelve a descargar.")
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { showImporter = true } label: {
                    HStack {
                        if isImporting { ProgressView() }
                        Label("Importar desde Archivos", systemImage: "square.and.arrow.down")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)
                Button { exportFiles = manager.installedModelFiles } label: {
                    Label("Guardar copia", systemImage: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(manager.installedModelFiles.isEmpty)
            }
            if let importMessage {
                Text(importMessage)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(IysThemePreferences.active.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(OCColor.bgDeep)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(IysThemePreferences.active.accent.opacity(0.2), lineWidth: 1))
    }

    static func describe(_ summary: GUSModelDownloadManager.ImportSummary) -> String {
        var parts: [String] = []
        if !summary.imported.isEmpty { parts.append("Importados y verificados: \(summary.imported.count)") }
        if !summary.alreadyInstalled.isEmpty { parts.append("ya instalados: \(summary.alreadyInstalled.count)") }
        if !summary.rejected.isEmpty {
            parts.append("no coinciden con el catálogo: \(summary.rejected.joined(separator: ", "))")
        }
        return parts.isEmpty ? "No encontré archivos .gguf en lo que elegiste." : parts.joined(separator: " · ")
    }

    private var recommendedModels: [GUSModelManifest] {
        GUSModelManifest.all.filter { !isExperimentalHere($0) }
    }

    private var experimentalModels: [GUSModelManifest] {
        GUSModelManifest.all.filter { isExperimentalHere($0) }
    }

    /// Experimental if the catalog says so or if it will not fit this device right now.
    private func isExperimentalHere(_ manifest: GUSModelManifest) -> Bool {
        manifest.isExperimental || budget.fit(for: manifest) == .unlikely
    }

    private func riskMessage(_ manifest: GUSModelManifest) -> String {
        let peak = ByteCountFormatter.string(fromByteCount: manifest.estimatedPeakBytes(contextTokens: 2048), countStyle: .memory)
        let limit = ByteCountFormatter.string(fromByteCount: budget.appMemoryLimit, countStyle: .memory)
        let size = ByteCountFormatter.string(fromByteCount: manifest.byteCount, countStyle: .file)
        return "\(manifest.modelName) necesita ~\(peak) de memoria con contexto 2K; ahora la app puede usar ~\(limit). "
            + "Descarga \(size). Lo peor que puede pasar: iOS cierra la app al cargar o generar, el iPhone se calienta o se llena el almacenamiento. "
            + "No hay riesgo para tus datos. Si se cierra, verás el informe al volver a abrir."
    }

    @ViewBuilder
    private var previousRunBanner: some View {
        if let report = GUSFlightRecorder.shared.previousRunReports.first {
            Button { showCrashHistory = true } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label("La app se cerró inesperadamente la última vez", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Text(report.summary).font(.system(size: 9, design: .monospaced))
                    Text("Toca para ver dónde y por qué.").font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(Color.red.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.4), lineWidth: 1))
        }
    }

    private var deviceSummary: some View {
        let ram = ByteCountFormatter.string(fromByteCount: budget.physicalMemory, countStyle: .memory)
        let limit = ByteCountFormatter.string(fromByteCount: budget.appMemoryLimit, countStyle: .memory)
        return Text("Este equipo: \(ram) de RAM · la app puede usar ~\(limit) ahora. La recomendación se calcula con ese límite, no con el nombre del iPhone.")
            .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fitBadge(_ manifest: GUSModelManifest) -> some View {
        let fit = budget.fit(for: manifest)
        let (text, color): (String, Color) = {
            switch fit {
            case .comfortable: return ("Cabe bien", .green)
            case .tight: return ("Justo", .yellow)
            case .unlikely: return ("Probablemente no cabe", .red)
            }
        }()
        return badge(text, color)
    }

    private func evidenceBadge(_ manifest: GUSModelManifest) -> some View {
        switch manifest.evidence {
        case .deviceMeasured: return badge("Medido en iPhone", .green)
        case .desktopSmoke: return badge("Probado en escritorio", .blue)
        case .unmeasured: return badge("Sin medir", .gray)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    Text("\(manifest.vendor) · \(manifest.parameterLabel) · GGUF \(manifest.byteCount / 1_000_000) MB · \(manifest.licenseName)")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        fitBadge(manifest)
                        evidenceBadge(manifest)
                        if manifest.isExperimental { badge("Experimental", .orange) }
                        if !manifest.commercialUse { badge("No comercial", .purple) }
                    }
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
            Button {
                if isExperimentalHere(manifest) || budget.fit(for: manifest) != .comfortable {
                    riskyDownload = manifest
                } else {
                    Task { await manager.startDownload(modelID: manifest.id) }
                }
            } label: {
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
            Button { benchmarkModel = manifest } label: {
                Label("Benchmark en este iPhone", systemImage: "speedometer")
                    .font(.system(size: 10, design: .monospaced))
            }
            .buttonStyle(.bordered)
        case .failed(let error):
            Text(error.localizedDescription)
                .font(.system(size: 9, design: .monospaced)).foregroundColor(.red)
            Button("Reintentar") { Task { await manager.startDownload(modelID: manifest.id) } }
                .buttonStyle(.bordered)
        }
    }
}

/// Presents the system "Save to Files" picker, copying (not moving) the files.
struct GUSDocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}
