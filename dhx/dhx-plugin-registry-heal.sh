#!/usr/bin/env bash
# Patterns: HP-017, HP-025
# dhx-plugin-registry-heal.sh — SessionStart heal hook (Phase 6 surgical-slim retired)
#
# Phase 6 (2026-05-03) verify-then-retire pre-retire probes (`tests/probes/.results/
# v1.2-phase-6/`) established that CC's Hn() resolver rehydrates `installed_plugins.json`
# natively in default `claude -p` mode across all three failure branches the previous
# heal logic targeted (UNREADABLE per PROBE-02; BADJSON + UNINSTALLED:dhx@dhx-local per
# 06-01 mini-probes; all three returned `supersession_found_drop_heal` with HIGH
# confidence at CC 2.1.121).
#
# Surgical-slim retire (D-25): the IP-heal body is short-circuited via early-exit;
# script + ~/.claude/hooks/ symlink + plugin-manifest dispatch line are retained
# intentionally (D-27) as a known mount-point for the HEAL-07 follow-on (km path
# hardening — known_marketplaces.json does NOT self-heal; per 06-01 km probe
# `v1_2_work_warranted` REFUTE outcome). Retaining the plumbing avoids the
# re-introduction cost when km hardening lands.
#
# Scope (post-Phase-6 surgical-slim):
#   - installed_plugins.json — DO NOT heal (Hn() rehydrates upstream; 06-01 PASS)
#   - known_marketplaces.json — NOT IMPLEMENTED (HEAL-07 follow-on; 06-01 km REFUTE)
#
# Out of scope (handled elsewhere):
#   - MISSING:dhx-local in settings → bashrc wrapper heal (HP-017)
#   - PATH / DISABLED → structural / settings-level
#
# Silent on happy path. No stdin parsing (filesystem state, not session context).
# No subprocess spawns post-retire — ~1ms budget (early-exit before any work).
#
# Evidence base: tests/probes/.results/v1.2-phase-6/probe-installed-plugins-{badjson,
# uninstalled-dhx,known-marketplaces}-natural-heal.json + docs/decisions.md 2026-05-03
# Phase 6 surgical-slim row + HP-025 active doctrine block.
set -uo pipefail

# Phase 6 surgical-slim scope guard (D-25 + D-27): IP heal retired via Hn() upstream-supersession
# evidence. km hardening is HEAL-07 follow-on (not implemented here).
# This script intentionally retains its symlink + dispatcher mount-point so that
# follow-on work has a known anchor without re-introducing manifest + symlink plumbing.
exit 0
