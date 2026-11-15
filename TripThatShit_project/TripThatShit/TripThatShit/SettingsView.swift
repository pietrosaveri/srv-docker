import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var settings = AppSettings.shared
    private var account = SyncAccount.shared
    @State private var name = ""
    @State private var nameError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Aspetto") {
                    AppearancePicker(selection: $settings.appearance)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }

                Section {
                    ForEach(TransportMode.allCases) { mode in
                        ModeColorRow(mode: mode, settings: settings)
                    }
                    Button("Ripristina colori predefiniti") {
                        withAnimation { settings.resetColors() }
                    }
                    .disabled(settings.colorsAreDefault)
                } header: {
                    Text("Colori dei mezzi")
                } footer: {
                    Text("Usati per le linee sulla mappa, le icone e la cronologia. Sono solo tuoi: nei viaggi condivisi ognuno vede i propri colori.")
                }

                Section {
                    if account.isSignedIn {
                        TextField("Il tuo nome", text: $name)
                            .onSubmit(saveName)
                            .submitLabel(.done)
                        LabeledContent("Server", value: SyncConfig.baseURL.host() ?? "")
                    } else {
                        Text("Nessun account. Ti verrà chiesto quando inviti qualcuno o ti unisci a un viaggio.")
                            .foregroundStyle(Theme.mute)
                    }
                } header: {
                    Text("Condivisione")
                } footer: {
                    Text(nameError ?? "Il nome che vedono gli altri partecipanti.")
                }

                Section("Mappa") {
                    Picker("Stile", selection: $settings.mapLook) {
                        ForEach(MapLook.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    Toggle("Voli tratteggiati", isOn: $settings.dashedFlights)
                }

                Section {
                    LabeledContent("Versione", value: appVersion)
                } footer: {
                    Text("TripThatShit salva tutto sul telefono e funziona anche offline. Solo i viaggi condivisi passano dal server.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.formCanvas)
            .onAppear { name = account.session?.name ?? "" }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { saveName(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.text)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != account.session?.name else { return }
        nameError = nil
        Task {
            do {
                try await account.api.rename(trimmed)
                account.updateName(trimmed)
            } catch {
                nameError = error.localizedDescription
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - Appearance

struct AppearancePicker: View {
    @Binding var selection: Appearance

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Appearance.allCases) { option in
                let on = option == selection
                Button { selection = option } label: {
                    VStack(spacing: 8) {
                        AppearanceThumb(option: option)
                        Label(option.label, systemImage: option.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .labelStyle(.titleOnly)
                            .foregroundStyle(on ? Theme.text : Theme.mute)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(on ? Theme.text : Theme.stone)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Mini phone mock-up of the light and dark canvas.
private struct AppearanceThumb: View {
    let option: Appearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            switch option {
            case .light: mock(dark: false)
            case .dark: mock(dark: true)
            case .system:
                mock(dark: false)
                mock(dark: true).mask(
                    GeometryReader { g in
                        Rectangle().frame(width: g.size.width / 2).offset(x: g.size.width / 2)
                    }
                )
            }
        }
        .frame(height: 96)
        .clipShape(shape)
        .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
    }

    private func mock(dark: Bool) -> some View {
        let bg = dark ? Color.black : .white
        let card = dark ? Color(hex: 0x16181A) : Color(hex: 0xF4F4F4)
        let ink = dark ? Color.white : Color(hex: 0x191C1F)
        return VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(ink).frame(width: 34, height: 6)
            RoundedRectangle(cornerRadius: 5).fill(card).frame(height: 22)
                .overlay(alignment: .leading) {
                    Circle().fill(Color(hex: 0x3D7BFF)).frame(width: 10, height: 10).padding(.leading, 6)
                }
            RoundedRectangle(cornerRadius: 5).fill(card).frame(height: 22)
                .overlay(alignment: .leading) {
                    Circle().fill(Color(hex: 0xE23B4A)).frame(width: 10, height: 10).padding(.leading, 6)
                }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg)
    }
}

// MARK: - Transport colours

struct ModeColorRow: View {
    let mode: TransportMode
    let settings: AppSettings

    static let palette: [UInt32] = [
        0x3D7BFF, 0x494FDF, 0x8E5CF7, 0xE61E49, 0xE23B4A,
        0xEC7E00, 0xF2B705, 0x2FB866, 0x00A87E, 0x007BC2, 0x936D62,
    ]

    var body: some View {
        let current = settings.modeColors[mode] ?? mode.defaultHex
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ModeBadge(mode: mode, size: 34)
                Text(mode.label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                LinePreview(color: mode.color, dashed: mode == .plane && settings.dashedFlights)
                ColorPicker("Colore personalizzato \(mode.label)", selection: Binding(
                    get: { mode.color },
                    set: { settings.setColor($0.hexValue, for: mode) }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Self.palette, id: \.self) { hex in
                        let on = hex == current
                        Button { withAnimation(.snappy) { settings.setColor(hex, for: mode) } } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if on {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay(Circle().stroke(on ? Theme.text : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: "Colore #%06X", hex))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: current)
    }
}

/// How the leg line will look on the map.
private struct LinePreview: View {
    let color: Color
    let dashed: Bool

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 3, y: 5))
            p.addLine(to: CGPoint(x: 37, y: 5))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dashed ? [2, 7] : []))
        .frame(width: 40, height: 10)
    }
}
