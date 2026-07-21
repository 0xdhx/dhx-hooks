#!/usr/bin/env bash
# Wrapper so CC-spawned sessions find the user-local .NET host regardless of PATH state.
export DOTNET_ROOT="$HOME/.dotnet"
export PATH="$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
mkdir -p /tmp/roslyn-lsp-logs
exec "$HOME/.dotnet/tools/roslyn-language-server" --stdio --logLevel Warning \
  --extensionLogDirectory /tmp/roslyn-lsp-logs --autoLoadProjects "$@"
