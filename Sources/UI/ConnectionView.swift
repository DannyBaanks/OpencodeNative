import SwiftUI

public struct ConnectionView: View {
    @EnvironmentObject private var adapter: SessionAdapter
    @State private var pairingLink = ""
    @FocusState private var fieldFocused: Bool

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 36)

                Text("opencode")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text("native / ios")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.45))
                    .padding(.top, 4)

                Spacer().frame(height: 42)

                HStack {
                    label("LINK DESKTOP")
                    Spacer()
                    Button {
                        UIPasteboard.general.string = "npx --yes github:DannyBaanks/OpencodeNative link"
                    } label: {
                        Text("copy")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                commandBox("npx --yes github:DannyBaanks/OpencodeNative link")

                Text("Run it in the project directory on the computer that already has OpenCode installed. Paste the pairing link printed by the command.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.42))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                Spacer().frame(height: 24)

                HStack {
                    label("PAIRING LINK")
                    Spacer()
                    Button {
                        if let pasted = UIPasteboard.general.string, !pasted.isEmpty {
                            pairingLink = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Text("paste")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.55))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                }
                TextField("opencodenative://pair?...", text: $pairingLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($fieldFocused)
                    .submitLabel(.go)
                    .onSubmit { connect() }
                    .scrollDismissesKeyboard(.interactively)
                    .padding(12)
                    .background(Color(red: 0.035, green: 0.035, blue: 0.035))
                    .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))

                Button { connect() } label: {
                    HStack {
                        Text(adapter.isConnecting ? "connecting..." : "connect")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("↵")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(adapter.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(adapter.isConnecting || pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .padding(.top, 10)

                if !adapter.connectionStatus.isEmpty {
                    Text(adapter.connectionStatus)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(adapter.connectionStatus.lowercased().hasPrefix("error") ? .red : Color.white.opacity(0.5))
                        .padding(.top, 10)
                }

                HStack(spacing: 12) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                    Text("OR")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.35))
                    Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                }
                .padding(.vertical, 26)

                Button {
                    adapter.useNativeRuntime()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("use native swift runtime")
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                            Text("sandbox tools + configured model api")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Color.white.opacity(0.38))
                        }
                        Spacer()
                        Text(">")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 54)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("remote mode = real OpenCode server / native mode = Swift runtime")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.28))
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 18)
        }
        .contentShape(Rectangle())
        .onTapGesture { fieldFocused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { fieldFocused = false }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
            }
        }
    }

    private func connect() {
        let link = pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !adapter.isConnecting else { return }
        fieldFocused = false
        adapter.connectRemote(link)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundColor(Color.white.opacity(0.42))
            .padding(.bottom, 8)
    }

    private func commandBox(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .foregroundColor(Color.white.opacity(0.38))
            Text(command)
                .foregroundColor(.white)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(12)
        .background(Color(red: 0.025, green: 0.025, blue: 0.025))
        .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}
