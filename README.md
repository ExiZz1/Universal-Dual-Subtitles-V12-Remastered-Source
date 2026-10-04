# Universal Dual Subtitles V12 — Remastered

Source code and build/package documentation for **Universal Dual Subtitles V12 Remastered** for The Witcher 3.

Created by **ExiZz**.

## About
Universal Dual Subtitles allows two subtitle languages to be displayed simultaneously in The Witcher 3 using the `~` separator.

This repository corresponds to the V12 Remastered release distributed through Nexus Mods.

## Compatibility
**V12 is intended for The Witcher 3: Wild Hunt — Remastered only.**

It is not intended for:
- The Witcher 3 Classic
- The Witcher 3 Next-Gen

Older versions of the mod are maintained separately for those game versions.

## Source Code
The main installer and modification logic is provided as PowerShell source code:

`Witcher3_Dual_Subtitles_Installer.ps1`

The source code is distributed in plain text and does not require compilation. The installer is executed using Windows PowerShell.

## Requirements
End users do not need:
- Python
- w3strings.exe
- an external compiler
- any external executable

The V12 Remastered package does not contain an `.exe` installer.

## Main Components

### Witcher3_Dual_Subtitles_Installer.ps1
Main PowerShell installer and management script. It provides:
- Witcher 3 installation detection
- SAFE TEST
- INSTALL
- RESTORE ORIGINALS
- recursive `.w3strings` resource scanning
- DLC and mod resource detection
- language resource matching
- language-code normalization
- W3Strings v164 handling for Remastered
- Ukrainian Secondary support
- backup and validation handling
- installation logging

### START_HERE.bat
Small launcher used to start the PowerShell-based installer. It does not download external software.

### r4gui.bundle
GUI resource used by the installer interface.

### header_art.png
Interface artwork.

### THIRD-PARTY-NOTICES.txt
Third-party notices and attribution information.

## Build / Packaging
The V12 installer does not require compilation. The PowerShell source is used directly:

`Witcher3_Dual_Subtitles_Installer.ps1`

The final Nexus package consists of the required runtime files and documentation and is assembled as a standard ZIP archive. No executable installer is compiled.

## Network Behaviour
The installer does not download additional programs or dependencies from the internet. It does not upload user data or telemetry.

## W3Strings
V12 Remastered uses the built-in W3Strings v164 handling included in the installer.

The external `w3strings.exe` dependency used by older versions is not included in V12 Remastered.

Legacy W3Strings 162/163 support is not part of this Remastered-only release.

## Ukrainian Secondary
V12 includes the verified Ukrainian Secondary subtitle support used by the Remastered release.

Verified combinations include:
- Polish → Ukrainian
- English → Ukrainian
- German → Ukrainian
- Spanish → Ukrainian

## Author
**ExiZz**

Universal Dual Subtitles series for The Witcher games.
