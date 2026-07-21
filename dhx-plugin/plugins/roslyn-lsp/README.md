# roslyn-lsp (dhx-local)

C# LSP for Claude Code via Microsoft's official `roslyn-language-server` (the VS Code C# extension's server), installed as a user-local dotnet global tool on .NET 10.

- Server: `~/.dotnet/tools/roslyn-language-server` 5.9.0 (needs `~/.dotnet` .NET 10 SDK)
- Wrapper `bin/roslyn-lsp.sh` pins DOTNET_ROOT/PATH and passes `--stdio --autoLoadProjects`
- Mutually exclusive with `csharp-lsp@claude-plugins-official` (both claim `.cs`)
- Why not csharp-ls: install/hang failures — `cross-repo:docs/research/2026-07-20-csharp-ls-install-hang.md`; alternatives survey — `...-csharp-lsp-alternatives.md`
