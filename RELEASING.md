# Release-Anleitung für Joe's 3D PrintMon

Die App heißt nach außen „Joe's 3D PrintMon"; intern (Targets, Schemes,
Bundle-ID `Meine.BambuMonitor`, Repo) bleibt der Name BambuMonitor —
die Bundle-ID darf sich nie ändern, sonst brechen Sparkle-Updates,
App Group und Keychain-Zugriff.

Verteilung außerhalb des App Store per Developer ID + Notarisierung,
Auto-Updates über Sparkle (Feed: `appcast.xml` im main-Branch).

## Einmalig eingerichtet

- EdDSA-Schlüsselpaar für Sparkle: privater Schlüssel liegt im Keychain
  („Private key for signing Sparkle updates"), öffentlicher Schlüssel steht
  als `SUPublicEDKey` im Info-Tab des Targets.
- Update-Feed-URL (`SUFeedURL`):
  `https://raw.githubusercontent.com/jschallmayer78/BambuMonitor/main/appcast.xml`

## Ablauf pro Release

1. **Version erhöhen**: Target *BambuMonitor* → General → *Version*
   (z. B. 1.1) und *Build* (fortlaufend hochzählen, z. B. 2).
   Beim Widget-Target die gleichen Werte setzen.
2. **Archivieren & notarisieren**: Product → Archive → Organizer →
   *Distribute App* → *Direct Distribution*. Warten bis die Notarisierung
   durch ist, dann *Export* → ergibt `BambuMonitor.app`.
3. **ZIP erstellen** (ditto erhält die Signatur; ZIP-Name ohne
   Apostroph, damit URLs und Shell-Befehle einfach bleiben):
   ```sh
   ditto -c -k --keepParent "Joe's 3D PrintMon.app" Joes-3D-PrintMon-1.1.zip
   ```
4. **Update signieren** (Pfad ggf. an DerivedData anpassen):
   ```sh
   ~/Library/Developer/Xcode/DerivedData/BambuMonitor-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update Joes-3D-PrintMon-1.1.zip
   ```
   Die Ausgabe liefert `sparkle:edSignature="…" length="…"`.
5. **appcast.xml ergänzen**: Neues `<item>` nach dem Muster im Template
   eintragen (Version, Download-URL des GitHub-Release-Assets, Signatur,
   Länge) und auf `main` pushen.
6. **GitHub-Release anlegen**: Tag `v1.1`, das ZIP als Asset hochladen.
   Die URL muss der `enclosure url` im appcast entsprechen.

Danach bieten installierte Apps das Update automatisch an
(bzw. über „Nach Updates suchen" im Popover).

## Erstverteilung

Das notarisierte ZIP aus Schritt 3 kann direkt weitergegeben oder im
GitHub-Release verlinkt werden. Empfänger: entpacken, in den Programme-
Ordner ziehen, starten.
