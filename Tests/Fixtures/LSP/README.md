# LSP integration fixtures (LSP-N13)

- `swift-package/`: minimal SwiftPM package for sourcekit-lsp.
- `clangd-project/`: single-file C project with `compile_flags.txt` for clangd.

Used by `scripts/check-real-lsp.sh` when REQUIRE_REAL_LSP=1 (CI hard gate).
