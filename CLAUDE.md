# CLAUDE.md

## Language

English is the project's development language. Write in English:

- documentation (`INTENT.md`, `SPEC.md`, `README.md`, this file);
- code: identifiers, comments and doc comments;
- scripts and CI: comments and output messages;
- commit messages, branch names, PR titles and descriptions, and PR checklists.

Spanish only appears as a UI translation, in the String Catalogs (`*.xcstrings`); English is also the source and fallback language there ([`SPEC.md` §3](SPEC.md#3-platforms-and-requirements)).

Some older code comments and scripts are still in Spanish. When you touch a file, translate the comments you change; don't open a PR just to translate.

## Documents

- `INTENT.md` takes precedence over `SPEC.md`, and `SPEC.md` takes precedence over the code and `README.md`.
- `README.md` explains how to build, install, use and verify. It doesn't copy the spec: it links to its sections.

## When closing a phase (or changing the spec)

Review `README.md` and update whatever changed:

- the **Status** section (completed phases and what's left for after v1);
- **Requirements** (macOS, iOS, Xcode and Swift versions);
- **Getting started** and **Pairing**, if the installation or pairing flow changed;
- **Verification**, if `scripts/verify.sh` or CI do something new;
- **Structure**, if folders or packages were added or moved;
- **How it works, in short**, if the transport, the protocol version or the key storage changed;
- the links to spec sections (`SPEC.md#…`), if sections were renumbered or renamed.

If nothing needs to change, say so in the PR.

## Project and verification

- The `.xcodeproj` is not versioned: it's generated with `xcodegen generate` from `project.yml`.
- Before pushing, run `scripts/verify.sh` (it's the same thing CI runs on `macos-15`).
