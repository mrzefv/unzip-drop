# Unzip Drop

An iOS app that takes a `.zip`, extracts it on-device, lets you browse the
contents, and pushes the whole tree straight into a GitHub repo as one commit —
built for working without a computer.

Ships as an **unsigned IPA** from GitHub Actions.

## Build (no Mac required)

Push to GitHub → the **Build IPA** workflow runs on a macOS runner → download
the `unzip-drop-ipa` artifact from the run → sideload it.

Locally on a Mac it's just `bash build.sh` → `build/ipa/unzip-drop.ipa`.

## Use

1. **Import** — pick a zip, or share one into the app from Files/Safari. A single
   wrapping folder is auto-flattened.
2. **Contents** — browse the extracted files, share any file, or Save All to Files.
3. **Push** — send the files to the repo set in Settings.

## Settings

- **Owner / Repo / Branch** — the push target (branch must already exist).
- **Subpath** — optional folder to drop the files into; blank = repo root.
- **Token** — a GitHub PAT (fine-grained or classic) with **Contents: read & write**
  on the target repo. Kept in the Keychain.

Files are layered onto the existing branch, so a push adds/overwrites and never
wipes what's already there.

## Stack

SwiftUI · ZIPFoundation · GitHub Git Data API · iOS 16+ · no backend.

_MRzefv · mrzefv.com_
