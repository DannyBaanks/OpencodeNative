import SwiftUI

struct ProviderDirectoryView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SandboxModelProvider.all) { provider in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(provider.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(OCColor.textPrimary)
                            Text(provider.description)
                                .font(OCTypography.meta)
                                .foregroundStyle(OCColor.textFaint)
                            Text(provider.id == "gus-local" ? "En el dispositivo · sin API key" : "API compatible · clave en Keychain")
                                .font(OCTypography.metaMono)
                                .foregroundStyle(IysThemePreferences.active.accent)
                            Link(destination: provider.apiKeyURL) {
                                Label(provider.id == "gus-local" ? "Ver el archivo fijado" : "Obtener API key", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .padding(.vertical, 5)
                    }
                } header: {
                    Text("Proveedores de inferencia")
                } footer: {
                    Text("El catálogo muestra proveedores compatibles con el adaptador OpenAI de este sandbox. Modelos, precios y acceso dependen de cada cuenta.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Google OAuth")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Gemini admite OAuth, pero requiere un proyecto de Google Cloud, consentimiento y un cliente OAuth registrado. Para conectar ahora, usa la API key de AI Studio.")
                            .font(OCTypography.meta)
                            .foregroundStyle(OCColor.textFaint)
                        Link(destination: URL(string: "https://ai.google.dev/gemini-api/docs/oauth")!) {
                            Label("Preparar OAuth con Google", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.vertical, 5)
                } header: {
                    Text("Inicio de sesión OAuth")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ChatGPT vía MCP")
                            .font(.system(size: 15, weight: .semibold))
                        Text("ChatGPT es el cliente MCP: se conecta a un servidor remoto. La app del iPhone no puede ofrecerse por sí sola como servidor accesible desde ChatGPT. Hace falta un endpoint remoto seguro y un relay aprobado; el host móvil actual todavía no implementa ese contrato.")
                            .font(OCTypography.meta)
                            .foregroundStyle(OCColor.textFaint)
                        Link(destination: URL(string: "https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt")!) {
                            Label("Cómo conectar un servidor MCP a ChatGPT", systemImage: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text("Esto es distinto de OpenAI API: para llamar GPT directamente desde el sandbox, configura una API key de OpenAI. La suscripción de ChatGPT no es una API key.")
                            .font(OCTypography.meta)
                            .foregroundStyle(OCColor.textFaint)
                    }
                    .padding(.vertical, 5)
                } header: {
                    Text("ChatGPT y MCP")
                }
            }
            .navigationTitle("Proveedores · ayuda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
        }
    }
}
