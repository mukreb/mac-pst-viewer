# PST Viewer voor macOS

Een eenvoudige, snelle viewer voor Outlook-archieven (`.pst` en `.ost`) op de Mac — zonder Outlook, zonder conversie, alleen-lezen. Gemaakt voor oude archieven, maar werkt ook met nieuwe.

## Mogelijkheden

- **Alle PST-formaten**: ANSI (Outlook 97–2002, de oude 2 GB-bestanden), Unicode (Outlook 2003 en later) en OST (ook de Outlook 2013+ variant met 4K-pagina's en compressie).
- **Alle versleutelingsvormen** van PST (geen, "compressible" en "high").
- **Drie kolommen** zoals in Outlook/Mail: mappenboom → berichtenlijst → voorbeeld.
- **Meerdere bestanden tegelijk** in de zijbalk.
- **Berichten** in HTML, RTF (oude Outlook-berichten) of platte tekst, met ingesloten afbeeldingen (`cid:`).
- **Bijlagen**: snel bekijken (Quick Look), openen, bewaren of alles in één keer bewaren. Bijgevoegde berichten (doorgestuurde mails) kun je zelf weer openen.
- **Contactpersonen, agenda-items, taken** met hun eigen velden (e-mail, telefoon, begin/eind, locatie…).
- **Zoeken** op onderwerp/afzender/ontvanger, in de huidige map of in alle mappen, optioneel ook in de berichttekst.
- **Sorteren** op afzender, onderwerp, datum, grootte; ongelezen berichten vetgedrukt.
- **Exporteren** naar `.eml` (te openen in Apple Mail), een hele map als `.eml`-bestanden of als `.mbox` (te importeren in Apple Mail, Thunderbird).
- **Kopteksten en alle MAPI-eigenschappen** bekijken (voor wie wil weten wat er precies in staat).
- **Privacy**: externe afbeeldingen in HTML-mail worden standaard geblokkeerd; JavaScript staat altijd uit.
- **Tekenset instelbaar** voor oude ANSI-berichten zonder tekensetaanduiding (standaard West-Europees/Windows-1252).

## Installeren

### Optie 1: zelf bouwen (aanbevolen)

Vereist macOS 13 (Ventura) of nieuwer en de Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/mukreb/mac-pst-viewer.git
cd mac-pst-viewer
./scripts/build-app.sh
open "dist/PST Viewer.app"
```

Sleep `dist/PST Viewer.app` daarna naar je map Programma's. Je kunt een `.pst` openen via **Archief → Open** (⌘O), door het bestand op het venster te slepen, of via "Open met" in de Finder.

### Optie 2: kant-en-klare download

Elke build op GitHub Actions maakt een universele app (Apple Silicon + Intel) die je kunt downloaden onder **Actions → Build → Artifacts → PST-Viewer-macOS**. Omdat de app niet door Apple is genotariseerd, moet je de eerste keer rechtsklikken op de app → **Open**, of in Terminal:

```bash
xattr -dr com.apple.quarantine "PST Viewer.app"
```

## Opdrachtregel

Er is ook een klein hulpprogramma `pstdump` (werkt op macOS én Linux):

```bash
swift run pstdump archief.pst              # mappenboom met aantallen
swift run pstdump archief.pst --messages   # mappen + berichtenlijst
swift run pstdump archief.pst --show 0x200024   # één bericht
swift run pstdump archief.pst --eml 0x200024 > bericht.eml
```

## Hoe het werkt

`Sources/PSTKit` is een zelfgeschreven PST-lezer in pure Swift, zonder externe afhankelijkheden, gebaseerd op de openbare specificatie [MS-PST](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/):

| Bestand | Laag |
|---------|------|
| `NDB.swift` | Bestandsheader, node- en blok-B-trees, datablokken, subnodes, versleuteling |
| `LTP.swift` | Heap-on-Node, BTree-on-Heap, Property Context, Table Context |
| `PSTFile.swift`, `Message.swift` | Mappen, berichten, ontvangers, bijlagen, named properties |
| `RTF.swift` | LZFu-decompressie, HTML uit RTF halen, RTF → tekst |
| `Inflate.swift` | Deflate-decoder voor gecomprimeerde OST 2013-blokken |
| `EMLWriter.swift` | Export naar `.eml` en `.mbox` |

De app zelf (`Sources/PSTViewer`) is SwiftUI.

Het bestand wordt geheugen-gemapt geopend en nooit gewijzigd.

## Testen

```bash
swift test
```

De tests draaien tegen echte PST-bestanden in `Tests/PSTKitTests/Fixtures` (zie de README daar voor herkomst). Omdat er vrijwel geen openbare ANSI-voorbeeldbestanden bestaan, zet `scripts/make_ansi_pst.py` een Unicode-PST om naar een echt ANSI-bestand; de uitkomst is gecontroleerd met de onafhankelijke libpff-bibliotheek.

## Licentie

MIT
