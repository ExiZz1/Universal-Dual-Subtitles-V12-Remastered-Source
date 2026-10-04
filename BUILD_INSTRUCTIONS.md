# Build and Packaging Instructions

## Universal Dual Subtitles V12 — Remastered

Author: ExiZz

## 1. Prerequisites
Windows is required for testing the installer.

Required:
- Windows PowerShell 5.1
- The Witcher 3: Wild Hunt — Remastered for testing

No Python installation is required.
No external `w3strings.exe` is required.

## 2. Source
The primary source code is:

`Witcher3_Dual_Subtitles_Installer.ps1`

The script is executed directly by Windows PowerShell. There is no compiled executable installer.

## 3. Running From Source
Place the project files in the same directory:
- `Witcher3_Dual_Subtitles_Installer.ps1`
- `START_HERE.bat`
- `r4gui.bundle`
- `header_art.png`
- `README.md`
- `THIRD-PARTY-NOTICES.txt`

Run:

`START_HERE.bat`

Alternatively, the PowerShell script can be started directly using Windows PowerShell.

## 4. Testing
Before release, test the following:
1. Start the installer.
2. Run SAFE TEST.
3. Confirm Witcher 3 installation detection.
4. Confirm language/resource detection.
5. Test INSTALL.
6. Launch The Witcher 3 Remastered.
7. Test dual subtitles.
8. Test Ukrainian as Secondary language.
9. Confirm generated files are valid.
10. Test RESTORE ORIGINALS.
11. Confirm original files are restored.

## 5. Packaging
Create a ZIP archive containing:
- `header_art.png`
- `r4gui.bundle`
- `README.md`
- `START_HERE.bat`
- `THIRD-PARTY-NOTICES.txt`
- `Witcher3_Dual_Subtitles_Installer.ps1`

The ZIP is then uploaded to Nexus Mods as the V12 Remastered release.

## 6. Important
The Nexus release must contain the same source/script version represented by this repository.

The project does not require compilation into an `.exe`.

The installer does not download external dependencies.
