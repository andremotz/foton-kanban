import Foundation
import Testing

@testable import FotonKanbanCore

@Suite("Pfade zu Bounce-Dateien")
struct ConfigPathTests {
    private let config = Config(
        listeningSituations: [],
        releaseCadenceWeeks: 6,
        previewsRoot: "/Volumes/Cloud/Previews"
    )
    private let home = URL(fileURLWithPath: "/Users/beispiel")

    /// Der Fehler, der das zuerst kaputt machte: `previewsRootURL` ist eine
    /// Verzeichnis-URL und endet auf einem Schrägstrich. Ein Präfixvergleich,
    /// der den nicht abschneidet, findet nie eine Übereinstimmung und schreibt
    /// den vollen Pfad samt Benutzernamen in die Track-Datei.
    @Test("Dateien im Previews-Ordner werden relativ notiert")
    func storesRelativePath() {
        let url = URL(fileURLWithPath: "/Volumes/Cloud/Previews/2026 Album/Ferrite 2026-01-02.wav")
        #expect(config.storedPath(for: url, home: home) == "2026 Album/Ferrite 2026-01-02.wav")
    }

    @Test("Dateien außerhalb, aber im Benutzerordner, bekommen eine Tilde")
    func storesTildePath() {
        let url = URL(fileURLWithPath: "/Users/beispiel/Desktop/Ferrite.wav")
        #expect(config.storedPath(for: url, home: home) == "~/Desktop/Ferrite.wav")
    }

    @Test("Alles Übrige bleibt absolut")
    func keepsForeignPathsAbsolute() {
        let url = URL(fileURLWithPath: "/Volumes/Extern/Ferrite.wav")
        #expect(config.storedPath(for: url, home: home) == "/Volumes/Extern/Ferrite.wav")
    }

    @Test("Ein ähnlich benannter Nachbarordner wird nicht verwechselt")
    func doesNotMatchSiblingFolder() {
        // "/Volumes/Cloud/PreviewsAlt" beginnt zwar mit dem Wurzelpfad,
        // liegt aber nicht darin.
        let url = URL(fileURLWithPath: "/Volumes/Cloud/PreviewsAlt/Ferrite.wav")
        #expect(config.storedPath(for: url, home: home) == "/Volumes/Cloud/PreviewsAlt/Ferrite.wav")
    }

    @Test("Jeder Eintrag findet zurück zu seiner Datei")
    func resolvesEveryForm() {
        #expect(
            config.resolvedURL(for: "2026 Album/Ferrite.wav")?.path(percentEncoded: false)
                == "/Volumes/Cloud/Previews/2026 Album/Ferrite.wav"
        )
        #expect(
            config.resolvedURL(for: "/Volumes/Extern/Ferrite.wav")?.path(percentEncoded: false)
                == "/Volumes/Extern/Ferrite.wav"
        )
        #expect(config.resolvedURL(for: "~/Desktop/Ferrite.wav")?.path(percentEncoded: false)
            .hasSuffix("/Desktop/Ferrite.wav") == true)
        #expect(config.resolvedURL(for: "") == nil)
    }

    @Test("Hin und zurück ergibt wieder dieselbe Datei")
    func roundTrips() {
        let url = URL(fileURLWithPath: "/Volumes/Cloud/Previews/2026 Album/Ferrite 2026-01-02.wav")
        let stored = config.storedPath(for: url, home: home)
        #expect(
            config.resolvedURL(for: stored)?.path(percentEncoded: false)
                == url.path(percentEncoded: false)
        )
    }

    @Test("Ohne Previews-Ordner bleibt ein relativer Eintrag unauflösbar")
    func needsRootForRelativePaths() {
        let bare = Config(listeningSituations: [], releaseCadenceWeeks: 6)
        #expect(bare.resolvedURL(for: "2026 Album/Ferrite.wav") == nil)
        #expect(bare.resolvedURL(for: "/Volumes/Extern/Ferrite.wav") != nil)
    }
}
