# Third-party notices

The root [MIT license](LICENSE) covers this project's original code and documentation. Third-party notices and licenses remain applicable to their respective material.

| Material | Source / license | Included notice |
|---|---|---|
| jsmn 1.1.0 | [zserge/jsmn](https://github.com/zserge/jsmn), MIT | [license](third_party/jsmn/LICENSE), [pinned source and hash](third_party/jsmn/SOURCE.md) |
| CLDR 48 Windows-to-IANA mapping | [Unicode CLDR](https://github.com/unicode-org/cldr/tree/release-48), Unicode License v3 | [license](third_party/cldr/LICENSE), [source and hash](third_party/cldr/README.md) |
| Runtime adapter reference material | Official Electron 44.9.3 x64 release; Electron and bundled Chromium/V8/Node/ICU/LLVM components have their own notices | [Electron license](third_party/runtime-notices/LICENSE), [original bundled notices](third_party/runtime-notices/LICENSES.chromium.html) |

`profiles/runtime-adapters.json` contains expected instruction data used to identify supported runtime functions. The reference runtime's bundled notices are retained without modification. Electron, Claude, Windows SDK binaries and PDBs are not shipped in the repository; the fixture preparation script downloads official Electron archives separately and verifies their published SHA-256 values.

Native ABI layout references are identified in the source and [Native MUI notes](docs/Native-MUI-ABI.md). Microsoft SDK headers are used from the developer's installed SDK; generated WinRT interface identifiers and forwarding declarations are checked in for the pinned SDK. The project does not bundle the SDK or its libraries.

Claude and other product names belong to their respective owners. This is an independent project and is not affiliated with or endorsed by Anthropic, Microsoft, Electron or the Chromium project.
