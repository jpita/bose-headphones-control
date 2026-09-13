# Changelog

## Unreleased

- Added a separate Swift-only macOS app using IOBluetooth and BMAP over RFCOMM.
- Reused the existing SwiftUI frontend while keeping the Python-backed Native, Electron, and web apps.
- Added Swift tests for BMAP packet framing, BLE segmentation, and QC mode layouts.

## 0.1.0 - 2026-09-12

- Added the local web control panel for compatible Bose BMAP headphones.
- Added Electron desktop builds for macOS and Linux.
- Added a native SwiftUI macOS app with the full supported control set.
- Added listening modes, ANC, wind block, EQ, profile editing, voice prompts, sidetone, device actions, and raw BMAP access.
- Added clean backend shutdown and protection against multiple controllers opening the same headphone connection.
- Added local API request protection and removed remote web assets.
- Added automated backend, API, Electron, and Swift lifecycle tests with GitHub Actions.
