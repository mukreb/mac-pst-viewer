# PST Viewer for macOS

A simple, fast viewer for Outlook archives (`.pst` and `.ost`) and old mbox mail (Netscape, Mozilla, Thunderbird) on the Mac — no Outlook, no conversion, read-only. Built for old archives, but works with new ones too.

**Website:** <https://mukreb.github.io/mac-pst-viewer/> — a plain-language introduction for users (English and Dutch).

![PST Viewer with an open archive](docs/screenshot-viewer.png)

## Features

- **All PST formats**: ANSI (Outlook 97–2002, the old 2 GB files), Unicode (Outlook 2003 and later) and OST (including the Outlook 2013+ variant with 4K pages and compression).
- **All PST encryption types** (none, "compressible" and "high").
- **Mbox mail folders**: open a folder of mail from Netscape Communicator, Mozilla or Thunderbird and browse it with the same interface. See [Old mbox mail](#old-mbox-mail-netscape-thunderbird).
- **Three columns** like Outlook and Mail: folder tree → message list → preview.
- **Several files at once** in the sidebar, each listed under its file name.
- **Messages** in HTML, RTF (old Outlook messages) or plain text, with embedded images (`cid:`).
- **Sent items show recipients**: in Sent Items, Outbox and Drafts the list shows who a message went to (To, or Cc) instead of yourself.
- **Attachments**: Quick Look, open, save, or save all at once. Attached messages (forwarded mail) can be opened in turn.
- **Contacts, calendar items and tasks** with their own fields (email, phone, start/end, location…).
- **Search** by subject, sender or recipient, in the current folder or in all folders, optionally in the message text and email addresses as well.
- **Sorting** by sender, subject, date and size; unread messages in bold.
- **Export** to `.eml` (opens in Apple Mail), a whole folder as `.eml` files, or as `.mbox` (imports into Apple Mail and Thunderbird). Selected messages — for example all search results — can also be exported as one `.mbox` file.
- **Headers and all MAPI properties** for anyone who wants to know exactly what's inside.
- **English and Dutch**: follows your Mac's language by default (English when the language isn't available); switch in Settings.
- **Light and dark mode**: follows the system or can be set in Settings; HTML mail can be shown with dark colours in dark mode.
- **Native look**: on macOS 26 the app uses Liquid Glass toolbars and controls.
- **Privacy**: remote images in HTML mail are blocked by default; JavaScript is always off.
- **Configurable character set** for old ANSI messages that don't specify one (Western European/Windows-1252 by default).

![Calendar item from an old ANSI archive](docs/screenshot-ansi.png)

## Installation

### Download (recommended)

Download **[PST-Viewer.zip](https://github.com/mukreb/mac-pst-viewer/releases/latest/download/PST-Viewer.zip)** from the [latest release](https://github.com/mukreb/mac-pst-viewer/releases/latest), double-click it and drag **PST Viewer** to your Applications folder. The app is a universal app (Apple Silicon + Intel), signed with a Developer ID and notarized by Apple, so it opens with a double-click. It requires macOS 13 (Ventura) or later and keeps itself up to date (see [Updates](#updates)).

You can open a `.pst` via **File → Open PST File or Mail Folder…** (⌘O), by dragging the file onto the window, or with "Open With" in the Finder.

### Build it yourself

Requires macOS 13 (Ventura) or later and the Xcode Command Line Tools (`xcode-select --install`). Building with Xcode 26 or Command Line Tools 26 gives the app the macOS 26 Liquid Glass look; older tools build the classic look.

```bash
git clone https://github.com/mukreb/mac-pst-viewer.git
cd mac-pst-viewer
./scripts/build-app.sh
open "dist/PST Viewer.app"
```

Then drag `dist/PST Viewer.app` to your Applications folder.

### Development builds

Every build on GitHub Actions produces a universal app that you can download under **Actions → Build → Artifacts → PST-Viewer-macOS**. Builds of `main` are signed and notarized like releases. Builds of pull requests aren't; for those, the first time you have to right-click the app → **Open**, or run in Terminal:

```bash
xattr -dr com.apple.quarantine "PST Viewer.app"
```

### Notarized builds

Notarizing needs a paid Apple Developer account. To build a notarized app on your own Mac:

```bash
# Once: save your notarization credentials in the keychain (Apple ID + app-specific password from account.apple.com)
xcrun notarytool store-credentials pstviewer --apple-id you@example.com --team-id TEAMID

SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh universal
NOTARY_PROFILE=pstviewer ./scripts/notarize.sh
```

`security find-identity -v -p codesigning` lists the exact name of your certificate. If you don't have a **Developer ID Application** certificate yet, create one in Xcode → Settings → Accounts → Manage Certificates (or at developer.apple.com → Certificates).

GitHub Actions does the same when these repository secrets are set (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | The Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64-encoded: `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | The password you chose when exporting the `.p12` |
| `APPLE_ID` | Your Apple ID email address |
| `APPLE_TEAM_ID` | Your 10-character Team ID (developer.apple.com → Account → Membership) |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID (account.apple.com → Sign-In and Security) |

Until all five secrets are set, the workflow builds an ad-hoc signed app as before.

## Updates

The app looks for a new [GitHub release](https://github.com/mukreb/mac-pst-viewer/releases) once a day at launch, and on demand with **PST Viewer → Check for Updates…** or the button in Settings. When there is one it shows the release notes and offers **Install and Relaunch**, **Later** or **Skip This Version**. Automatic checks can be turned off in Settings.

Settings → Updates → **Install** chooses what to update to:

- **Releases** (default): only versions published from a version tag, such as `v1.2.0`.
- **All builds**: also every signed build of `main` and pre-releases. Builds of `main` are numbered after the latest release (`1.2.0.57` is build 57 after `v1.2.0`), so they sort between that release and the next one. (The Finder shows them as `1.2.0 (57)`, because macOS wants three numbers in the version.) Switching back to Releases never downgrades: you get the next release that is newer than the build you have.

The update is downloaded, unpacked and checked before it replaces the app: it must be signed with a Developer ID of the same team as the running app, have the same bundle identifier and be the version that was offered. An app you built yourself (ad-hoc signed), or one that isn't in a folder it can write to, can't replace itself; for those the button opens the release page instead.

To publish a release, push a version tag:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The Release workflow then builds, signs and notarizes the app with that version, and publishes a release with `PST-Viewer.zip`. Its notes come from `.github/release-notes/<tag>.md` (for example `v1.1.0.md`) when that file exists, otherwise they're generated from the merged pull requests. The updater shows these notes to users, so write them for users. Only releases signed with the Developer ID (the secrets above) can be installed by the updater; it refuses others. Tags with a suffix, such as `v1.2.0-beta.1`, become pre-releases, which only the All builds channel installs. Every signed build of `main` is also published by the Build workflow as a pre-release named `build-<version>`; it keeps the 10 most recent. `./scripts/build-app.sh` gives a self-built app the version of the latest tag (or `APP_VERSION`, if set).

## Settings

Open **PST Viewer → Settings…** (⌘,) for:

- **Language**: System default, English or Nederlands. The app's own texts switch immediately; menu items provided by macOS follow after restarting the app.
- **Appearance**: System default, Light or Dark, and whether HTML messages get dark colours in dark mode.
- **Show system folders**, **load remote images** and the **default character set** for old ANSI messages.
- **Updates**: whether to check for new versions automatically, whether to install only releases or all builds, and a button to check now.

<img src="docs/screenshot-settings.png" alt="Settings window" width="520">

## Old mbox mail (Netscape, Thunderbird)

Netscape Communicator 4.x, Mozilla and Thunderbird keep every mail folder as an **mbox** file without an extension (`Inbox`, `Sent`, `Trash`, …). Subfolders of a folder `Projects` are in a directory `Projects.sbd`. The `.snm` (Netscape) and `.msf` (Mozilla, Thunderbird) files next to them are summary indexes; PST Viewer doesn't need them.

To view such an archive, choose **File → Open PST File or Mail Folder…** and select the folder that contains `Inbox`, `Sent` and the other files, or drag that folder onto the window. The folder tree, message list, search, attachments and export then work as for a PST file. You can also open a single mbox file, an Apple Mail export (`Name.mbox`) or a folder that contains several such archives.

Details:

- **Deleted messages**: Netscape didn't remove deleted messages from the file straight away, it only marked them (until you "compacted" the folder). Those messages are hidden; **File Info** shows how many there are.
- **Read/unread** comes from Netscape's `X-Mozilla-Status` header, or from the `Status` header of other mail programs.
- **Attachments** in MIME messages as well as old uuencoded attachments (`begin 644 …`) are shown as attachments. Forwarded messages (`message/rfc822`) can be opened in turn.
- **Character sets**: headers and texts in old mail often contain unmarked 8-bit text; for those the default character set from Settings is used.
- **Export** to `.eml` writes the original message byte for byte.

## Command line

There's also a small tool, `pstdump` (works on macOS and Linux). It also reads mbox files and mail folders:

```bash
swift run pstdump archive.pst              # folder tree with counts
swift run pstdump "Netscape Mail" --messages   # an mbox mail folder
swift run pstdump archive.pst --messages   # folders + message list
swift run pstdump archive.pst --show 0x200024   # a single message
swift run pstdump archive.pst --eml 0x200024 > message.eml
```

It can also export the messages of one or more archives to a single mbox file, optionally only those that match a search:

```bash
swift run pstdump archive.pst --mbox all.mbox
swift run pstdump old.pst archive.pst "Netscape Mail" --mbox piet.mbox --search "asseldonk"
swift run pstdump archive.pst --mbox sent.mbox --search "piet" --folder "verzonden"
```

- `--search` looks for words in the subject, sender and recipients, including their email addresses; all words must occur. Add `--body` to search the message text and attachment names as well.
- `--folder` only exports folders whose path contains this text (for example `inbox` or `projects/client a`).
- `--append` adds to an existing mbox file instead of overwriting it.
- Each message gets an `X-Folder` header with the archive and folder it came from. A message that is in several folders or archives (same Message-ID) is written once.
- The exit code is 3 when some messages couldn't be read; they are listed in the output.

## How it works

`Sources/PSTKit` is a PST reader written from scratch in pure Swift, without external dependencies, based on the public [MS-PST](https://learn.microsoft.com/en-us/openspecs/office_file_formats/ms-pst/) specification:

| File | Layer |
|------|-------|
| `NDB.swift` | File header, node and block B-trees, data blocks, subnodes, encryption |
| `LTP.swift` | Heap-on-Node, BTree-on-Heap, Property Context, Table Context |
| `PSTFile.swift`, `Message.swift` | Folders, messages, recipients, attachments, named properties |
| `RTF.swift` | LZFu decompression, extracting HTML from RTF, RTF → text |
| `Inflate.swift` | Deflate decoder for compressed OST 2013 blocks |
| `EMLWriter.swift` | Export to `.eml` and `.mbox` |
| `MailExport.swift` | Search filter and mbox export across archives (`pstdump --mbox`) |
| `MailStore.swift` | The interface the app uses for both PST files and mbox archives |
| `Mbox.swift` | Mbox files and Netscape/Thunderbird folder trees (`.sbd`) |
| `MIME.swift`, `MIMEContent.swift` | MIME parser (multipart, base64, quoted-printable, RFC 2047/2231, uuencode) |
| `Localization.swift` | English/Dutch texts (`tr("English", "Nederlands")`) |

The app itself (`Sources/PSTViewer`) is SwiftUI. `Sources/UpdateKit` holds the platform-independent part of the updater (version numbers, GitHub release data); `Updater.swift` in the app does the download, signature check and install.

The file is opened memory-mapped and never modified.

## Testing

```bash
swift test
```

The tests run against real PST files in `Tests/PSTKitTests/Fixtures` (see the README there for their origin) and a Netscape-style mail folder generated by `scripts/make_mbox_fixture.py`. Because there are hardly any public ANSI sample files, `scripts/make_ansi_pst.py` converts a Unicode PST into a genuine ANSI file; the result has been verified with the independent libpff library.

## License

MIT
