Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FontBundleSource = Join-Path $ScriptDir 'r4gui.bundle'
$FontBundleBaseSha256 = '02DCFB5C0E4EDEC66F9236834C9A6ADD72A29DE8D9DAFBC4BEC5DEADDDF42775'
$FontBundlePatchedSha256 = '3AF62B2C50B68E4D2D365B7748F27C93417969688D3942050BDA7F4524A049AB'
$FontBackupDirName = '_DualSubtitles_FontBackups_v12'
$script:ResourceCache = @{}
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;

public static class W3V164Bridge
{
    private static readonly Encoding UTF8 = new UTF8Encoding(false, true);

    private sealed class Entry
    {
        public uint Id;
        public uint Offset;
        public uint Length;
        public uint KeyHex;
        public string Text;
    }

    private sealed class B2
    {
        public uint KeyHex;
        public uint Id;
    }

    private static int ReadBit6(BinaryReader br)
    {
        int result = 0;
        int shift = 0;
        int i = 1;
        while (true)
        {
            int b = br.ReadByte();
            int mask = 255;
            int s = 6;

            if (b > 127)
            {
                mask = 127;
                s = 7;
            }
            else if (b > 63)
            {
                if (i == 1) mask = 63;
            }

            if (shift < 32)
                result |= (b & mask) << shift;

            shift += s;

            if (b < 64 || (i >= 3 && b < 128))
                break;

            i++;
        }
        return result;
    }

    private static void WriteBit6(BinaryWriter bw, int value)
    {
        if (value == 0)
        {
            bw.Write((byte)128);
            return;
        }

        var bytes = new List<int>();
        int left = value;
        int i = 0;

        while (left > 0)
        {
            if (i == 0)
            {
                bytes.Add(left & 63);
                left >>= 6;
            }
            else
            {
                bytes.Add(left & 255);
                left >>= 7;
            }
            i++;
        }

        for (i = 0; i < bytes.Count; i++)
        {
            bool last = i == bytes.Count - 1;
            int cleft = (bytes.Count - 1) - i;
            int v = bytes[i];

            if (!last)
            {
                if (cleft >= 1 && i >= 1)
                    v |= 128;
                else if (v < 64)
                    v |= 64;
                else
                    v |= 128;
            }

            if (v == 128)
                throw new InvalidDataException("Invalid Bit6 value.");

            bw.Write((byte)v);
        }
    }

    private static uint GetMagic(uint key)
    {
        switch (key)
        {
            case 0x83496237: return 0x73946816; // pl
            case 0x43975139: return 0x79321793; // en
            case 0x75886138: return 0x42791159; // de
            case 0x45931894: return 0x12375973; // it
            case 0x23863176: return 0x75921975; // fr
            case 0x24987354: return 0x21793217; // cs/cz
            case 0x18796651: return 0x42387566; // es
            case 0x18632176: return 0x16875467; // zh/cn
            case 0x63481486: return 0x42386347; // ru
            case 0x42378932: return 0x67823218; // hu
            case 0x54834893: return 0x59825646; // ja/jp
            case 0x00000000: return 0x00000000; // ua and other zero-key languages
            default: throw new InvalidDataException(
                "Unknown W3Strings language key: 0x" + key.ToString("X8"));
        }
    }

    private static uint GetKeyForLanguage(string lang)
    {
        string c = (lang ?? "").Trim().ToLowerInvariant();
        switch (c)
        {
            case "pl": return 0x83496237;
            case "en": return 0x43975139;
            case "de": return 0x75886138;
            case "it": return 0x45931894;
            case "fr": return 0x23863176;
            case "cs":
            case "cz": return 0x24987354;
            case "es": return 0x18796651;
            case "zh":
            case "cn": return 0x18632176;
            case "ru": return 0x63481486;
            case "hu": return 0x42378932;
            case "ja":
            case "jp": return 0x54834893;
            case "ar":
            case "br":
            case "pt":
            case "tr":
            case "kr":
            case "ko":
            case "ua":
            case "uk":
            case "esmx":
                return 0x00000000;
            default:
                throw new InvalidDataException(
                    "Unknown W3Strings language code in CSV: " + lang);
        }
    }

    private static string LanguageFromPath(string path)
    {
        string c = Path.GetFileNameWithoutExtension(path).ToLowerInvariant();
        switch (c)
        {
            case "uk": return "ua";
            case "jp": return "ja";
            case "kr": return "ko";
            case "cn": return "zh";
            case "cz": return "cs";
            default: return c;
        }
    }

    private static string GetMetaValue(string line, string name)
    {
        string token = name + "=";
        int p = line.IndexOf(token, StringComparison.OrdinalIgnoreCase);
        if (p < 0) return null;
        p += token.Length;
        int e = line.IndexOf(';', p);
        if (e < 0) e = line.IndexOf(']', p);
        if (e < 0) return null;
        return line.Substring(p, e - p);
    }

    private static string EscapeText(string value)
    {
        return (value ?? "").Replace("\\", "\\\\").Replace("\r", "\\r").Replace("\n", "\\n");
    }

    private static string UnescapeText(string value)
    {
        var sb = new StringBuilder(value == null ? 0 : value.Length);
        for (int i = 0; i < (value == null ? 0 : value.Length); i++)
        {
            char c = value[i];
            if (c == '\\' && i + 1 < value.Length)
            {
                char n = value[i + 1];
                if (n == 'n' || n == 'r' || n == '\\')
                {
                    sb.Append(n == 'n' ? '\n' : n == 'r' ? '\r' : '\\');
                    i++;
                    continue;
                }
            }
            sb.Append(c);
        }
        return sb.ToString();
    }

    public static int GetVersion(string path)
    {
        using (var fs = File.OpenRead(path))
        using (var br = new BinaryReader(fs))
        {
            if (br.ReadByte() != 'R' || br.ReadByte() != 'T' ||
                br.ReadByte() != 'S' || br.ReadByte() != 'W')
                throw new InvalidDataException("Not a W3Strings file.");
            return br.ReadInt32();
        }
    }

    public static uint GetLanguageKey(string path)
    {
        using (var fs = File.OpenRead(path))
        using (var br = new BinaryReader(fs))
        {
            if (fs.Length < 12 || br.ReadByte() != 'R' || br.ReadByte() != 'T' ||
                br.ReadByte() != 'S' || br.ReadByte() != 'W')
                throw new InvalidDataException("Not a W3Strings file.");
            fs.Position = 8;
            uint high = br.ReadUInt16();
            fs.Position = fs.Length - 2;
            uint low = br.ReadUInt16();
            return (high << 16) | low;
        }
    }

    public static void Decode(string path)
    {
        byte[] all = File.ReadAllBytes(path);
        using (var ms = new MemoryStream(all, false))
        using (var br = new BinaryReader(ms, Encoding.UTF8, true))
        {
            if (br.ReadByte() != 'R' || br.ReadByte() != 'T' ||
                br.ReadByte() != 'S' || br.ReadByte() != 'W')
                throw new InvalidDataException("Invalid RTSW header.");

            uint version = br.ReadUInt32();
            if (version < 164)
                throw new InvalidDataException("Built-in engine is for W3Strings v164+.");

            ushort key1 = br.ReadUInt16();
            ms.Seek(-2, SeekOrigin.End);
            ushort key2 = br.ReadUInt16();
            uint languageKey = ((uint)key1 << 16) | key2;
            uint magic = GetMagic(languageKey);

            ms.Seek(10, SeekOrigin.Begin);

            int count1 = ReadBit6(br);
            var block1 = new List<Entry>(count1);

            for (int i = 0; i < count1; i++)
            {
                uint hashedId = br.ReadUInt32();
                uint offset = br.ReadUInt32();
                uint length = br.ReadUInt32();
                block1.Add(new Entry
                {
                    Id = hashedId ^ magic,
                    Offset = offset,
                    Length = length
                });
            }

            int count2 = ReadBit6(br);
            var block2 = new List<B2>(count2);
            var keyById = new Dictionary<uint, uint>();

            for (int i = 0; i < count2; i++)
            {
                uint keyHex = br.ReadUInt32();
                uint hashedId = br.ReadUInt32();
                uint id = hashedId ^ magic;
                block2.Add(new B2 { KeyHex = keyHex, Id = id });
                if (!keyById.ContainsKey(id))
                    keyById[id] = keyHex;
            }

            int block3Count = ReadBit6(br);
            long stringStart = ms.Position;

            foreach (var e in block1)
            {
                long at = stringStart + e.Offset;
                if (at < stringStart || at + e.Length > stringStart + block3Count)
                    throw new InvalidDataException("String entry points outside the v164 string buffer.");

                ms.Position = at;
                byte[] raw = br.ReadBytes((int)e.Length);
                if (raw.Length != e.Length)
                    throw new EndOfStreamException();

                ushort stringKey = (ushort)((magic >> 8) & 0xFFFF);
                for (int j = 0; j < raw.Length; j++)
                {
                    ushort charKey = (ushort)(((e.Length + 1UL) * stringKey) & 0xFFFF);
                    raw[j] = (byte)(raw[j] ^ (byte)(charKey & 0xFF));
                    stringKey = (ushort)((stringKey << 1) | (stringKey >> 15));
                }

                e.Text = UTF8.GetString(raw);
            }

            string csvPath = path + ".csv";
            string language = LanguageFromPath(path);

            var sb = new StringBuilder(Math.Min(int.MaxValue, all.Length + 512));
            sb.Append(";meta[language=").Append(language).AppendLine("]");
            sb.Append(";w3v164[version=").Append(version)
              .Append(";key=").Append(languageKey.ToString("x8"))
              .Append(";magic=").Append(magic.ToString("x8"))
              .Append(";escape=backslash-v1").AppendLine("]");

            block1.Sort((a, b) => a.Id.CompareTo(b.Id));

            var block1Ids = new HashSet<uint>();
            foreach (var e in block1)
            {
                block1Ids.Add(e.Id);
                uint kh = keyById.ContainsKey(e.Id) ? keyById[e.Id] : 0;
                sb.Append(e.Id).Append('|')
                  .Append(kh.ToString("x8")).Append("||")
                  .Append(EscapeText(e.Text)).Append('\n');
            }

            // Preserve block-2 mappings which have no block-1 string entry.
            foreach (var b2 in block2)
            {
                if (!block1Ids.Contains(b2.Id))
                {
                    sb.Append(";w3v164-extra=")
                      .Append(b2.KeyHex.ToString("x8"))
                      .Append(':')
                      .Append(b2.Id)
                      .Append('\n');
                }
            }

            File.WriteAllText(csvPath, sb.ToString(), new UTF8Encoding(false));
        }
    }

    public static void Encode(string csvPath)
    {
        EncodeCore(csvPath, null, false);
    }

    public static void Encode(string csvPath, uint fallbackLanguageKey)
    {
        EncodeCore(csvPath, fallbackLanguageKey, true);
    }

    private static void EncodeCore(string csvPath, uint? fallbackLanguageKey, bool forceEscapedText)
    {
        string[] lines = File.ReadAllLines(csvPath, UTF8);
        string language = null;
        uint encLanguageKey = 0;
        uint encMagic = 0;
        bool encHaveKey = false;
        bool encEscapedText = forceEscapedText;
        var encRows = new List<Entry>();
        var encExtra = new List<B2>();

        foreach (string line in lines)
        {
            if (line.StartsWith(";meta[language=", StringComparison.OrdinalIgnoreCase))
            {
                int p = ";meta[language=".Length;
                int e = line.IndexOf(']', p);
                if (e > p) language = line.Substring(p, e - p);
                continue;
            }

            if (line.StartsWith(";w3v164[", StringComparison.OrdinalIgnoreCase))
            {
                string keyText = GetMetaValue(line, "key");
                string magicText = GetMetaValue(line, "magic");
                encEscapedText = forceEscapedText || String.Equals(GetMetaValue(line, "escape"), "backslash-v1", StringComparison.OrdinalIgnoreCase);
                if (!String.IsNullOrEmpty(keyText))
                {
                    encLanguageKey = Convert.ToUInt32(keyText, 16);
                    encHaveKey = true;
                }
                if (!String.IsNullOrEmpty(magicText))
                    encMagic = Convert.ToUInt32(magicText, 16);
                continue;
            }

            if (line.StartsWith(";w3v164-extra=", StringComparison.OrdinalIgnoreCase))
            {
                string x = line.Substring(";w3v164-extra=".Length);
                int colon = x.IndexOf(':');
                if (colon > 0)
                {
                    uint extraKeyHex = Convert.ToUInt32(x.Substring(0, colon), 16);
                    uint extraId = Convert.ToUInt32(x.Substring(colon + 1));
                    encExtra.Add(new B2 { KeyHex = extraKeyHex, Id = extraId });
                }
                continue;
            }

            if (String.IsNullOrWhiteSpace(line) || line.StartsWith(";"))
                continue;

            string[] parts = line.Split(new[] { '|' }, 4);
            if (parts.Length != 4)
                continue;

            uint parsedId;
            if (!UInt32.TryParse(parts[0].Trim(), out parsedId))
                continue;

            uint rowKeyHex = 0;
            string rowKeyText = parts[1].Trim();
            if (!String.IsNullOrEmpty(rowKeyText))
                UInt32.TryParse(rowKeyText, System.Globalization.NumberStyles.HexNumber,
                                System.Globalization.CultureInfo.InvariantCulture, out rowKeyHex);

            encRows.Add(new Entry
            {
                Id = parsedId,
                KeyHex = rowKeyHex,
                Text = encEscapedText ? UnescapeText(parts[3]) : parts[3]
            });
        }

        if (!encHaveKey)
        {
            if (fallbackLanguageKey.HasValue)
            {
                encLanguageKey = fallbackLanguageKey.Value;
            }
            else
            {
                if (String.IsNullOrEmpty(language))
                {
                    string csvName = Path.GetFileNameWithoutExtension(csvPath);
                    language = Path.GetFileNameWithoutExtension(csvName);
                }
                encLanguageKey = GetKeyForLanguage(language);
            }
            encMagic = GetMagic(encLanguageKey);
        }
        else if (encMagic == 0)
        {
            encMagic = GetMagic(encLanguageKey);
        }

        encRows.Sort((a, b) => (a.Id ^ encMagic).CompareTo(b.Id ^ encMagic));
        encExtra.Sort((a, b) => a.KeyHex.CompareTo(b.KeyHex));

        var encStringBuffer = new MemoryStream();
        using (var sw = new BinaryWriter(encStringBuffer, Encoding.UTF8, true))
        {
            foreach (var row in encRows)
            {
                byte[] raw = UTF8.GetBytes(row.Text ?? "");
                row.Offset = (uint)encStringBuffer.Position;
                row.Length = (uint)raw.Length;

                ushort encStringKey = (ushort)((encMagic >> 8) & 0xFFFF);
                for (int j = 0; j < raw.Length; j++)
                {
                    ushort encCharKey = (ushort)(((row.Length + 1UL) * encStringKey) & 0xFFFF);
                    raw[j] = (byte)(raw[j] ^ (byte)(encCharKey & 0xFF));
                    encStringKey = (ushort)((encStringKey << 1) | (encStringKey >> 15));
                }

                sw.Write(raw);
                sw.Write((byte)0);
            }
        }

        var encB2 = new List<B2>();
        foreach (var row in encRows)
        {
            if (row.KeyHex != 0)
                encB2.Add(new B2 { KeyHex = row.KeyHex, Id = row.Id });
        }
        encB2.AddRange(encExtra);
        encB2.Sort((a, b) => a.KeyHex.CompareTo(b.KeyHex));

        string outPath = csvPath + ".w3strings";
        using (var fs = File.Create(outPath))
        using (var bw = new BinaryWriter(fs, Encoding.UTF8, true))
        {
            bw.Write(new byte[] { (byte)'R', (byte)'T', (byte)'S', (byte)'W' });
            bw.Write((uint)164);
            bw.Write((ushort)(encLanguageKey >> 16));

            WriteBit6(bw, encRows.Count);
            foreach (var row in encRows)
            {
                bw.Write(row.Id ^ encMagic);
                bw.Write(row.Offset);
                bw.Write(row.Length);
            }

            WriteBit6(bw, encB2.Count);
            foreach (var x in encB2)
            {
                bw.Write(x.KeyHex);
                bw.Write(x.Id ^ encMagic);
            }

            WriteBit6(bw, checked((int)encStringBuffer.Length));
            encStringBuffer.Position = 0;
            encStringBuffer.CopyTo(fs);

            bw.Write((ushort)(encLanguageKey & 0xFFFF));
        }
    }
}
"@


function Find-Witcher3 {
    $candidates = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    function Add-Candidate([string]$p) {
        if([string]::IsNullOrWhiteSpace($p)){return}
        try { $full=[System.IO.Path]::GetFullPath($p) } catch { return }
        if($seen.Add($full)){[void]$candidates.Add($full)}
    }

    # Common Steam locations.
    Add-Candidate 'C:\Program Files (x86)\Steam\steamapps\common\The Witcher 3'
    Add-Candidate 'C:\Program Files\Steam\steamapps\common\The Witcher 3'

    # Steam registry locations (works with custom Steam roots too).
    foreach($regPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $steam=$null
            if(Test-Path $regPath){$steam=(Get-ItemProperty -Path $regPath -ErrorAction Stop).SteamPath}
            if($steam){Add-Candidate (Join-Path $steam 'steamapps\common\The Witcher 3')}
        } catch {}
    }

    # Steam libraryfolders.vdf: find every registered Steam library, including D:\Steam\...
    $steamRoots=New-Object System.Collections.Generic.List[string]
    foreach($regPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            if(Test-Path $regPath){$steam=(Get-ItemProperty -Path $regPath -ErrorAction Stop).SteamPath;if($steam){[void]$steamRoots.Add($steam)}}
        } catch {}
    }
    foreach($steamRoot in ($steamRoots | Select-Object -Unique)) {
        $vdf=Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if(Test-Path $vdf -PathType Leaf){
            try {
                $raw=[System.IO.File]::ReadAllText($vdf)
                foreach($m in [regex]::Matches($raw,'"path"\s*"([^"]+)"')) {
                    $lib=$m.Groups[1].Value -replace '\\\\','\\'
                    Add-Candidate (Join-Path $lib 'steamapps\common\The Witcher 3')
                }
                Add-Candidate (Join-Path $steamRoot 'steamapps\common\The Witcher 3')
            } catch {}
        }
    }

    # Last fallback: conventional SteamLibrary/Games folders on fixed drives.
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne 'Fixed' -or -not $drive.IsReady) { continue }
        $root = $drive.RootDirectory.FullName
        Add-Candidate (Join-Path $root 'SteamLibrary\steamapps\common\The Witcher 3')
        Add-Candidate (Join-Path $root 'Steam\steamapps\common\The Witcher 3')
        Add-Candidate (Join-Path $root 'Games\Steam\steamapps\common\The Witcher 3')
    }

    foreach ($p in $candidates) {
        if (Test-Path (Join-Path $p 'content') -PathType Container) { return $p }
    }
    return $null
}

function Log($text) {
    $txtLog.AppendText("$text`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Run-W3Strings([string[]]$Arguments, [bool]$Quiet=$false) {
    $inputPath = $null
    foreach($a in $Arguments) {
        if(-not $a.StartsWith('-')) { $inputPath = $a; break }
    }

    if(-not $inputPath -or -not (Test-Path $inputPath -PathType Leaf)) {
        if(-not $Quiet) { Log 'ERROR: W3Strings input file is missing.' }
        return 1
    }

    try {
        if($Arguments -contains '-d') {
            $ver = [W3V164Bridge]::GetVersion($inputPath)
            if($ver -lt 164) {
                if(-not $Quiet) { Log "ERROR: This Remastered build supports W3Strings v164+ only (found v$ver)." }
                return 1
            }
            if(-not $Quiet) { Log ("RUN: built-in W3Strings v164 engine -d " + $inputPath) }
            [W3V164Bridge]::Decode($inputPath)
            return 0
        }

        if($Arguments -contains '-e') {
            $v164KeyArg = $Arguments | Where-Object { $_ -match '^--w3v164-key=([0-9a-fA-F]{8})$' } | Select-Object -First 1
            if(-not $v164KeyArg) {
                if(-not $Quiet) { Log 'ERROR: Remastered encoder requires a verified v164 language key.' }
                return 1
            }
            $fallbackKey = [Convert]::ToUInt32(($v164KeyArg -split '=',2)[1],16)
            if(-not $Quiet) { Log ("RUN: built-in W3Strings v164 engine -e (primary key {0:x8}) {1}" -f $fallbackKey,$inputPath) }
            [W3V164Bridge]::Encode($inputPath,$fallbackKey)
            return 0
        }

        if(-not $Quiet) { Log 'ERROR: Unsupported W3Strings operation.' }
        return 1
    } catch {
        if(-not $Quiet) { Log ("v164 engine failed: " + $_.Exception.Message) }
        return 1
    }
}
function Parse-Csv([string]$path) {
    $d = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';')) { continue }
        $parts = $line.Split('|', 4)
        if ($parts.Count -ne 4) { continue }
        $key = $parts[0].Trim()
        $text = $parts[3]
        if (-not $key) { continue }
        if (-not $d.ContainsKey($key) -or [string]::IsNullOrEmpty($d[$key]) -or $text.Length -gt $d[$key].Length) { $d[$key] = $text }
    }
    return $d
}

function Merge-Csv([string]$primaryCsv, [string]$secondaryCsv) {
    $secondaryMap = Parse-Csv $secondaryCsv
    $lines = [System.IO.File]::ReadAllLines($primaryCsv, [System.Text.Encoding]::UTF8)
    $out = New-Object System.Collections.Generic.List[string]
    $appended=0; $already=0
    foreach ($line in $lines) {
        $raw=$line
        $parts=$raw.Split('|',4)
        if ($parts.Count -eq 4) {
            $key=$parts[0].Trim(); $primaryText=$parts[3]
            if ($secondaryMap.ContainsKey($key) -and -not [string]::IsNullOrEmpty($secondaryMap[$key])) {
                $secondaryText=$secondaryMap[$key]
                if ($primaryText.Contains($secondaryText)) { $already++ }
                else {
                    $sep=if($primaryText.Length -gt 20){'<br>~ '}else{' ~ '}
                    $parts[3]=$primaryText+$sep+$secondaryText
                    $raw=[string]::Join('|',$parts); $appended++
                }
            }
        }
        [void]$out.Add($raw)
    }
    [System.IO.File]::WriteAllText($primaryCsv,(($out -join "`n")+"`n"),(New-Object System.Text.UTF8Encoding($false)))
    return @($appended,$already)
}

function Language-Label([string]$code) {
    $names=@{
        'en'='English'; 'pl'='Polski'; 'ru'='Русский'; 'de'='Deutsch'; 'fr'='Français'; 'es'='Español';
        'it'='Italiano'; 'pt'='Português'; 'br'='Português (BR)'; 'cs'='Čeština'; 'tr'='Türkçe';
        'zh'='中文'; 'ja'='日本語'; 'ko'='한국어'; 'uk'='Українська'; 'ua'='Українська'; 'hu'='Magyar'; 'ro'='Română';
        'ar'='العربية'; 'nl'='Nederlands'; 'sv'='Svenska'; 'da'='Dansk'; 'fi'='Suomi';
        'no'='Norsk'; 'sk'='Slovenčina'
    }
    $c=$code.ToLowerInvariant()
    if($names.ContainsKey($c)){return "$($names[$c]) [$c]"}
    return "Custom / $c [$c]"
}

function Normalize-LanguageCode([string]$code) {
    $map=@{
        'cz'='cs'; 'jp'='ja'; 'kr'='ko'; 'cn'='zh'; 'br'='pt'; 'ua'='ua'
    }
    $c=$code.ToLowerInvariant()
    if($map.ContainsKey($c)){return $map[$c]}
    return $c
}

function Test-IsStandardLanguageSlot([string]$code) {
    $c=$code.ToLowerInvariant()
    return $c -in @('ar','br','cn','cz','de','en','es','fr','hu','it','jp','kr','pl','pt','ru','tr','zh','ja','ko','cs','uk','ua','ro','nl','sv','da','fi','no','sk')
}

function Detect-TextLanguage([string]$csvPath, [string]$physicalCode) {
    # Detect the language from the actual decoded text, not only from the filename.
    # This is specifically for localization mods that replace e.g. en.w3strings with Ukrainian text.
    $samples = New-Object System.Collections.Generic.List[string]
    try {
        $lines=[System.IO.File]::ReadAllLines($csvPath,[System.Text.Encoding]::UTF8)
        $usable = New-Object 'System.Collections.Generic.List[string]'
        foreach($line in $lines){
            if($line.StartsWith(';') -or [string]::IsNullOrWhiteSpace($line)){continue}
            $p=$line.Split('|',4)
            if($p.Count -eq 4 -and -not [string]::IsNullOrWhiteSpace($p[3])){[void]$usable.Add($p[3])}
        }
        if($usable.Count -eq 0){return $physicalCode.ToLowerInvariant()}
        # Use the beginning, middle and end so metadata/menu strings cannot dominate the result.
        $indices = New-Object System.Collections.Generic.List[int]
        $take=[Math]::Min(900,$usable.Count)
        for($i=0;$i -lt $take;$i++){
            $idx=[int][Math]::Floor(($i * ($usable.Count-1)) / [Math]::Max(1,($take-1)))
            [void]$indices.Add($idx)
        }
        foreach($i in ($indices | Select-Object -Unique)){[void]$samples.Add($usable[$i])}
    } catch { return $physicalCode.ToLowerInvariant() }

    $text = ($samples -join ' ')
    if(-not $text){return $physicalCode.ToLowerInvariant()}

    $scores=@{uk=0.0;ru=0.0;pl=0.0;cs=0.0;de=0.0;fr=0.0;es=0.0;it=0.0;en=0.0}
    $stats=@{}
    foreach($ch in $text.ToCharArray()){
        $k=[string]$ch
        if($stats.ContainsKey($k)){$stats[$k]++}else{$stats[$k]=1}
    }

    # Strong script-specific evidence. Repeated distinctive letters are much stronger than one occurrence.
    $scores.uk += 2.0 * (([regex]::Matches($text,'[іїєґІЇЄҐ]')).Count)
    $scores.ru += 2.0 * (([regex]::Matches($text,'[ыэъёЫЭЪЁ]')).Count)
    $scores.pl += 1.5 * (([regex]::Matches($text,'[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]')).Count)
    $scores.cs += 1.5 * (([regex]::Matches($text,'[ěščřžůĚŠČŘŽŮ]')).Count)
    $scores.de += 1.2 * (([regex]::Matches($text,'[äöüßÄÖÜ]')).Count)
    $scores.fr += 1.0 * (([regex]::Matches($text,'[àâçéèêëîïôûùüÿÀÂÇÉÈÊËÎÏÔÛÙÜŸ]')).Count)
    $scores.es += 1.0 * (([regex]::Matches($text,'[ñáéíóúü¿¡ÑÁÉÍÓÚÜ]')).Count)

    $patterns=@{
        uk=@('це','що','для','та','але','він','вона','вони','може','треба','буде','після','перед','якщо','мене','тобі','грати','гри','завдання','говорити','тому','цього','цьому');
        ru=@('это','что','для','так','но','он','она','они','может','нужно','будет','после','перед','если','меня','тебе','играть','игры','задание','говорить','поэтому');
        pl=@('jest','jestem','dla','ale','który','która','może','trzeba','będzie','przed','jeśli','mnie','tobie','grać','gry','zadanie','mówić','dlatego');
        cs=@('je','jsem','pro','ale','který','která','může','bude','před','pokud','mě','tobě','hrát','hry','úkol');
        de=@('der','die','das','und','ist','für','aber','kann','wird','wenn','mich','dir','spielen','spiel','aufgabe');
        fr=@('le','la','les','des','est','pour','mais','peut','sera','si','moi','toi','jouer','jeu','quête');
        es=@('el','la','los','las','para','pero','puede','será','si','me','te','jugar','juego','misión');
        it=@('il','la','gli','per','ma','può','sarà','se','me','te','giocare','gioco','missione')
    }
    foreach($k in $patterns.Keys){
        foreach($word in $patterns[$k]){
            $n=([regex]::Matches($text,('\b'+[regex]::Escape($word)+'\b'),[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
            $scores[$k] += [Math]::Min(25,$n * 1.25)
        }
    }

    # Penalize impossible language/script combinations a little.
    $cyr = ([regex]::Matches($text,'[А-Яа-яЇїІіЄєҐґЁёЫыЭэЪъ]')).Count
    $lat = ([regex]::Matches($text,'[A-Za-zĄąĆćĘęŁłŃńÓóŚśŹźŻżČčŠšŘřŽžŮůÄäÖöÜüßÀ-ÿ]')).Count
    if($cyr -gt ($lat*0.15)){
        $scores.en -= 20; $scores.de -= 4; $scores.fr -= 4; $scores.es -= 4; $scores.it -= 4
    }

    # Minimal override for replaced English slots: only allow Ukrainian to override en
    # when there is strong Ukrainian-specific evidence. Other language slots never use this detector.
    if($physicalCode.ToLowerInvariant() -eq 'en'){
        $ukDistinct = ([regex]::Matches($text,'[іїєґІЇЄҐ]')).Count
        $ukWords = 0
        foreach($w in @('це','що','для','та','але','він','вона','вони','може','треба','буде','після','перед','якщо','мене','тобі','грати','гри','завдання','говорити','цього','цьому')) {
            $ukWords += ([regex]::Matches($text,('\b'+[regex]::Escape($w)+'\b'),[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
        }
        if($ukDistinct -ge 3 -and $ukWords -ge 2){ return 'uk' }
    }

    $best=$scores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $second=$scores.GetEnumerator() | Sort-Object Value -Descending | Select-Object -Skip 1 | Select-Object -First 1
    $physical=$physicalCode.ToLowerInvariant()

    # Require enough evidence and a useful margin before overriding the physical filename code.
    if($best.Value -ge 8 -and ($best.Value - $second.Value) -ge 2 -and $best.Key -ne $physical){return $best.Key}
    return $physical
}

function Get-ResourceSignature([string]$path) {
    $fi=Get-Item $path
    $key="$($fi.FullName)|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if($script:ResourceCache.ContainsKey($key)){return $script:ResourceCache[$key]}

    $physical=$fi.BaseName.ToLowerInvariant()
    $normalized=Normalize-LanguageCode $physical

    # FAST PATH: official Remastered language slots are identified by their filename.
    # Ukrainian is an official language in the current game, so en.w3strings must
    # remain English and must NOT be reclassified by content detection.
    # Do not decode stock language slots during the initial recursive scan.
    if(Test-IsStandardLanguageSlot $physical){
        $r=[pscustomobject]@{PhysicalCode=$physical;DetectedCode=$normalized;Path=$path}
        $script:ResourceCache[$key]=$r
        return $r
    }

    $work=Join-Path $env:TEMP ('W3Scan_'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $copy=Join-Path $work $fi.Name
    try {
        Copy-Item $path $copy -Force
        $decodeWatch=[Diagnostics.Stopwatch]::StartNew()
        $code=Run-W3Strings @('-d',$copy) $true
        $decodeWatch.Stop()
        Log ("SCAN DECODE: {0:N3}s ({1})" -f $decodeWatch.Elapsed.TotalSeconds,$path)
        $csv="$copy.csv"

        if($code -eq 0 -and (Test-Path $csv)) {
            # Content detection is only for genuinely custom/non-standard slots.
            $det=Detect-TextLanguage $csv $normalized
            if($det -and $det -ne $normalized){$normalized=$det}
        }

        $r=[pscustomobject]@{PhysicalCode=$physical;DetectedCode=$normalized;Path=$path}
        $script:ResourceCache[$key]=$r
        return $r
    } finally {
        if(Test-Path $work){Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}
    }
}

function Get-AllResources([string]$game) {
    $resources=New-Object System.Collections.Generic.List[object]
    $scanCount=0
    $scanWatch=[Diagnostics.Stopwatch]::StartNew()
    $lastScanPath=''
    Get-ChildItem $game -Recurse -File -Filter '*.w3strings' -ErrorAction SilentlyContinue | ForEach-Object {
        $scanCount++
        $lastScanPath=$_.FullName
        if(($scanCount % 250) -eq 0) {
            $lblStatus.Text="Scanning .w3strings resources... $scanCount found"
            [System.Windows.Forms.Application]::DoEvents()
        }
        if($_.FullName -match '\\_DualSubtitles_Backups(_v\d+)?\\'){return}
        # Ignore the known standalone backups created by older installer builds.
        # They are not game localization resources and must not appear as languages.
        if($_.BaseName -match '(?i)_(dual_backup|dual_subtitles_original|dual_test_backup|before_cleanup)$'){return}
        try {
            $sig=Get-ResourceSignature $_.FullName
            $rel=$_.FullName.Substring($game.Length).TrimStart('\\')
            $resources.Add([pscustomobject]@{Folder=$_.DirectoryName;RelativePath=$rel;PhysicalCode=$sig.PhysicalCode;DetectedCode=$sig.DetectedCode;Path=$_.FullName})
        } catch { Log "SCAN WARN: $($_.FullName) -> $($_.Exception.Message)" }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $scanWatch.Stop()
    Log ("SCAN COMPLETE: {0} .w3strings files in {1:N2}s; last file: {2}" -f $scanCount,$scanWatch.Elapsed.TotalSeconds,$lastScanPath)
    # Do not wrap a generic List in @().  Windows PowerShell 5.1 can throw
    # "Argument types do not match" while converting it during recursive scans.
    return $resources.ToArray()
}

function Get-ResourcesByFolder([string]$game) {
    $all=Get-AllResources $game
    $groups=@{}
    foreach($r in $all){if(-not $groups.ContainsKey($r.Folder)){$groups[$r.Folder]=New-Object System.Collections.Generic.List[object]};$groups[$r.Folder].Add($r)}
    return $groups
}

function Find-Resource($list,[string]$logicalCode) {
    $exact=$list | Where-Object {$_.PhysicalCode -eq $logicalCode -and $_.DetectedCode -eq $logicalCode} | Select-Object -First 1
    if($exact){return $exact}
    $det=$list | Where-Object {$_.DetectedCode -eq $logicalCode} | Select-Object -First 1
    return $det
}

function Get-Targets([string]$game,[string]$primary,[string]$secondary) {
    $targets=New-Object System.Collections.Generic.List[object]
    $groups=Get-ResourcesByFolder $game
    foreach($folder in $groups.Keys){
        # The values are generic Lists; @($list) can fail in Windows PowerShell 5.1.
        $list=$groups[$folder].ToArray()
        $a=Find-Resource $list $primary; $b=Find-Resource $list $secondary
        if($a -and $b -and $a.Path -ne $b.Path){
            $rel=$a.RelativePath
            $targets.Add([pscustomobject]@{Name=$rel;Folder=$folder;Primary=$a;Secondary=$b})
        }
    }
    # See Get-AllResources: return a real object array, not a generic List.
    return $targets.ToArray()
}

function Get-Languages([string]$game) {
    $all=Get-AllResources $game
    $set=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($r in $all){[void]$set.Add($r.DetectedCode)}
    return @($set | Sort-Object)
}

function Clean-Temps([string]$folder) {
    Get-ChildItem $folder -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*.w3strings.csv' -or $_.Name -like '*.w3strings.csv.w3strings' -or $_.Name -like '*.w3strings.csv.w3strings.ws' -or $_.Name -like '*.w3strings.csv.w3strings.csv'
    } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Process-Target($target,[string]$Primary,[string]$Secondary,[bool]$Install) {
    $primaryReal=$target.Primary.Path; $secondaryReal=$target.Secondary.Path
    $backupDir=Join-Path $target.Folder '_DualSubtitles_Backups_v12'
    $safeName=($target.Primary.PhysicalCode + '.original.w3strings')
    $backup=Join-Path $backupDir $safeName
    Log ""; Log "=== $($target.Name) : $Primary + $Secondary ==="; Log "Primary resource: $($target.Primary.RelativePath) [detected $($target.Primary.DetectedCode)]"; Log "Secondary resource: $($target.Secondary.RelativePath) [detected $($target.Secondary.DetectedCode)]"
    if($Install -and -not(Test-Path $backupDir)){New-Item -ItemType Directory -Path $backupDir -Force | Out-Null}
    if($Install -and -not(Test-Path $backup)) {
        Copy-Item $primaryReal $backup -Force
        Log "Original primary backup created."
    } elseif($Install -and (Test-Path $backup)) {
        $liveVersion=[W3V164Bridge]::GetVersion($primaryReal)
        $backupVersion=[W3V164Bridge]::GetVersion($backup)
        if($backupVersion -ne $liveVersion) {
            $stamp=[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
            $archivedBackup=Join-Path $backupDir ("{0}.original.v{1}.{2}.w3strings" -f $target.Primary.PhysicalCode,$backupVersion,$stamp)
            Copy-Item $backup $archivedBackup -Force
            Copy-Item $primaryReal $backup -Force
            Log "Archived stale v$backupVersion backup and refreshed original backup to live version $liveVersion."
        }
    }
    $cleanSource=$primaryReal
    if(Test-Path $backup) {
        try {
            $liveVersion=[W3V164Bridge]::GetVersion($primaryReal)
            $backupVersion=[W3V164Bridge]::GetVersion($backup)
            if($backupVersion -eq $liveVersion) {
                $cleanSource=$backup
                Log "Using matching original backup (version $backupVersion)."
            } else {
                Log "Ignoring stale backup version $backupVersion; live primary is version $liveVersion."
            }
        } catch {
            Log "Could not validate backup version; using live primary: $($_.Exception.Message)"
        }
    }
    $work=Join-Path $env:TEMP ('W3Dual_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $work | Out-Null
    $p=Join-Path $work (Split-Path $primaryReal -Leaf);$s=Join-Path $work (Split-Path $secondaryReal -Leaf);Copy-Item $cleanSource $p -Force;Copy-Item $secondaryReal $s -Force
    $pcsv="$p.csv";$scsv="$s.csv";$temp="$pcsv.w3strings";$valid="$temp.csv"
    try {
        $primaryVersion = [W3V164Bridge]::GetVersion($p)
        Log "Primary .w3strings version: $primaryVersion"
        Log "Decoding primary...";if((Run-W3Strings @('-d',$p)) -ne 0){throw 'Primary decode failed'}
        Log "Decoding secondary...";if((Run-W3Strings @('-d',$s)) -ne 0){throw 'Secondary decode failed'}
        $m=Merge-Csv $pcsv $scsv;Log "Secondary appended: $($m[0]); already present: $($m[1])"
        $mergedLines=[System.IO.File]::ReadAllLines($pcsv,[System.Text.Encoding]::UTF8)
        $hasV164Metadata=$false;$csvRows=0;$badCsvRows=0
        foreach($line in $mergedLines) {
            if($line -match '(?i)^\s*;w3v164\['){$hasV164Metadata=$true}
            if([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';')){continue}
            $fields=$line.Split('|',4);$rowId=0
            if($fields.Count -ne 4 -or -not [uint32]::TryParse($fields[0].Trim(),[ref]$rowId)){$badCsvRows++}else{$csvRows++}
        }
        Log "Primary version: $primaryVersion"
        Log "CSV path: $pcsv"
        Log "CSV data entries: $csvRows; malformed rows: $badCsvRows"
        Log "Contains v164 metadata: $($hasV164Metadata.ToString().ToUpperInvariant())"
        Log 'CSV first 10 lines:'
        for($i=0;$i -lt [Math]::Min(10,$mergedLines.Count);$i++){Log ("CSV[{0}] {1}" -f ($i+1),$mergedLines[$i])}
        if($badCsvRows -gt 0){throw "Merged CSV has $badCsvRows malformed data row(s)."}
        if($primaryVersion -eq 164) {
            Log 'Encoding temporary primary with built-in v164 encoder...'
            $primaryKey=[W3V164Bridge]::GetLanguageKey($p)
            $keyArg='--w3v164-key={0:x8}' -f $primaryKey
            if((Run-W3Strings @($keyArg,'-e',$pcsv)) -ne 0){throw 'Encoding failed'}
        } else {
            throw "Unsupported primary W3Strings version $primaryVersion. This Remastered build supports v164 only."
        }
        if(-not(Test-Path $temp)){throw 'Temporary encoded file missing'}
        Log 'Validating temporary file...';if((Run-W3Strings @('-d',$temp)) -ne 0){throw 'Validation decode failed'}
        if(-not(Test-Path $valid)){throw 'Validation CSV missing'}
        $src=(Parse-Csv $pcsv).Count;$val=(Parse-Csv $valid).Count
        if($src -ne $val){throw "Validation count mismatch: $src -> $val"}
        Log "VALIDATION OK: $val strings"
        if($Install){Copy-Item $temp $primaryReal -Force;Clean-Temps $target.Folder;Log 'INSTALLED.'}else{Log 'SAFE TEST: real game file was NOT changed.'}
        return 'PASS'
    }catch{Log "ERROR: $($_.Exception.Message)";return 'FAIL'}finally{if(Test-Path $work){Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue}}
}

function Get-Sha256([string]$path) {
    if(-not(Test-Path $path -PathType Leaf)){return $null}
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
}

function Test-FontBundlePackage {
    if(-not(Test-Path $FontBundleSource -PathType Leaf)){Log 'FONT PATCH: bundled r4gui.bundle is missing.';return $false}
    $sha=Get-Sha256 $FontBundleSource
    if($sha -ne $FontBundlePatchedSha256){Log "FONT PATCH: bundled r4gui.bundle SHA mismatch: $sha";return $false}
    Log "FONT PATCH PACKAGE OK: SHA-256 $sha"
    return $true
}

function Install-FontBundle([string]$game) {
    if(-not(Test-FontBundlePackage)){throw 'The bundled Ukrainian EN-font patch failed its SHA-256 check.'}
    $bundle=Join-Path $game 'content\content0\bundles\r4gui.bundle'
    if(-not(Test-Path $bundle -PathType Leaf)){throw "r4gui.bundle was not found: $bundle"}
    $live=Get-Sha256 $bundle
    if($live -eq $FontBundlePatchedSha256){Log 'FONT PATCH: EN-font Ukrainian patch is already installed.';return 'ALREADY-INSTALLED'}
    if($live -ne $FontBundleBaseSha256){throw "Unsupported r4gui.bundle version or another bundle mod is present. Expected clean SHA $FontBundleBaseSha256, found $live. No font bundle changes were made."}
    $backupDir=Join-Path $game $FontBackupDirName
    if(-not(Test-Path $backupDir)){New-Item -ItemType Directory -Path $backupDir -Force | Out-Null}
    $backup=Join-Path $backupDir 'r4gui.bundle.original'
    if(-not(Test-Path $backup)){Copy-Item $bundle $backup -Force;Log 'FONT PATCH: original r4gui.bundle backup created.'}
    Copy-Item $FontBundleSource $bundle -Force
    $after=Get-Sha256 $bundle
    if($after -ne $FontBundlePatchedSha256){throw "Font bundle installation verification failed: $after"}
    Log 'FONT PATCH: EN-font Ukrainian patch installed.'
    return 'INSTALLED'
}

function Restore-FontBundle([string]$game) {
    $backup=Join-Path (Join-Path $game $FontBackupDirName) 'r4gui.bundle.original'
    $bundle=Join-Path $game 'content\content0\bundles\r4gui.bundle'
    if(-not(Test-Path $backup -PathType Leaf)){return 0}
    Copy-Item $backup $bundle -Force
    Log 'FONT PATCH: original r4gui.bundle restored.'
    return 1
}

function Restore-All([string]$game) {
    $n=0
    Get-ChildItem $game -Recurse -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq '_DualSubtitles_Backups_v12'} | ForEach-Object {
        $folder=$_.Parent.FullName
        Get-ChildItem $_.FullName -File -Filter '*.original.w3strings' -ErrorAction SilentlyContinue | ForEach-Object {
            $physical=$_.Name -replace '\.original\.w3strings$','';$dest=Join-Path $folder "$physical.w3strings";Copy-Item $_.FullName $dest -Force;Clean-Temps $folder;Log "Restored: $($dest.Substring($game.Length).TrimStart('\\'))";$n++
        }
    }
    $fontRestored=Restore-FontBundle $game
    Log "RESTORE COMPLETE: $n language file(s); $fontRestored font bundle restored."
}


function Show-Guide {
    $g=New-Object System.Windows.Forms.Form
    $g.Text='The Witcher 3 — Dual Subtitles Guide'
    $g.ClientSize=New-Object System.Drawing.Size(1040,760)
    $g.StartPosition='CenterParent'
    $g.BackColor=$uiBg
    $g.MinimizeBox=$false
    $g.MaximizeBox=$false

    $header=New-Object System.Windows.Forms.Panel
    $header.Location=New-Object System.Drawing.Point(0,0)
    $header.Size=New-Object System.Drawing.Size(1040,78)
    $header.BackColor=$uiPanel
    $g.Controls.Add($header)
    $header.Controls.Add((New-UiLabel 'The Witcher 3' 28 12 300 34 20 $true $uiText))
    $header.Controls.Add((New-UiLabel 'Dual Subtitles Guide' 28 45 320 22 10 $false $uiMuted))

    $nl=[Environment]::NewLine

    $tabs=New-Object System.Windows.Forms.TabControl
    $tabs.Location=New-Object System.Drawing.Point(14,88)
    $tabs.Size=New-Object System.Drawing.Size(1012,610)
    $g.Controls.Add($tabs)

    function New-GuidePage([string]$title) {
        $page=New-Object System.Windows.Forms.TabPage
        $page.Text=$title
        $page.BackColor=$uiBg
        $scroll=New-Object System.Windows.Forms.Panel
        $scroll.Dock='Fill';$scroll.AutoScroll=$true
        $page.Controls.Add($scroll)
        [void]$tabs.TabPages.Add($page)
        return $scroll
    }
    function Add-GuideTitle($p,[string]$title,[string]$subtitle) {
        $p.Controls.Add((New-UiLabel $title 22 18 900 34 19 $true $uiText))
        $p.Controls.Add((New-UiLabel $subtitle 22 52 900 42 10 $false $uiMuted))
    }
    function Add-GuideCard($p,[int]$x,[int]$y,[int]$w,[int]$h,[string]$title,[string]$body,[System.Drawing.Color]$accent,[string]$number='') {
        $card=New-Object System.Windows.Forms.Panel
        $card.Location=New-Object System.Drawing.Point($x,$y);$card.Size=New-Object System.Drawing.Size($w,$h)
        $card.BackColor=$uiPanel;$card.BorderStyle='FixedSingle'
        $bar=New-Object System.Windows.Forms.Panel;$bar.Location=New-Object System.Drawing.Point(0,0);$bar.Size=New-Object System.Drawing.Size(5,$h);$bar.BackColor=$accent;$card.Controls.Add($bar)
        if($number){
            $n=New-UiLabel $number 18 15 38 38 13 $true $accent;$n.TextAlign='MiddleCenter';$card.Controls.Add($n)
            $tx=70
        } else {$tx=22}
        $card.Controls.Add((New-UiLabel $title $tx 12 ($w-$tx-18) 28 12 $true $uiText))
        $b=New-UiLabel $body $tx 43 ($w-$tx-18) ($h-52) 10 $false $uiMuted
        $b.AutoEllipsis=$false;$card.Controls.Add($b)
        $p.Controls.Add($card)
    }

    # Quick start
    $p=New-GuidePage 'Quick start';Add-GuideTitle $p 'Quick Start' 'Follow these steps to enable dual subtitles in The Witcher 3.'
    Add-GuideCard $p 22 102 615 90 'Select game folder' 'Click Browse or use Scan to locate your The Witcher 3 installation folder. The tool also checks Steam library locations.' $uiBlue '1'
    Add-GuideCard $p 22 202 615 90 'Choose languages' 'Primary is shown first. Secondary is added after the  ~  separator.' $uiGreen '2'
    Add-GuideCard $p 22 302 615 90 'Run SAFE TEST' 'SAFE TEST builds temporary files only. It does not change the real game files.' ([System.Drawing.Color]::FromArgb(234,88,12)) '3'
    Add-GuideCard $p 22 402 615 90 'Install' 'If the test is successful, click INSTALL and then launch The Witcher 3 to check the result.' ([System.Drawing.Color]::FromArgb(124,58,237)) '4'
    Add-GuideCard $p 657 102 337 180 'How it works' "The tool takes the selected Primary language and adds the selected Secondary language after  ~  .${nl}${nl}Example:${nl}New Game${nl}~  Nowa gra" $uiBlue
    Add-GuideCard $p 657 298 337 194 'Important' "• Close The Witcher 3 before installing.$nl• Run SAFE TEST before INSTALL.$nl• DLC and mod resources are scanned automatically.$nl• If text appears but some characters are squares, check the language-specific font notes." ([System.Drawing.Color]::FromArgb(220,38,38))
    Add-GuideCard $p 22 512 972 70 'Language order' 'English → Polish     |     Ukrainian → English     |     Polish → Ukrainian     |     German → Ukrainian' $uiGreen

    # Ukrainian
    $p=New-GuidePage 'Ukrainian Secondary';Add-GuideTitle $p 'Ukrainian Secondary' 'The verified Ukrainian Secondary path for this build.'
    Add-GuideCard $p 22 102 972 104 'Confirmed combinations' "Polish → Ukrainian$nlEnglish → Ukrainian$nlGerman → Ukrainian$nlSpanish → Ukrainian" $uiGreen
    Add-GuideCard $p 22 220 972 120 'How to read the result' 'The Primary subtitle remains first. The Ukrainian Secondary subtitle is appended after  ~  . If the full Ukrainian text appears, the subtitle merge and the verified Ukrainian font patch are working.' $uiBlue
    Add-GuideCard $p 22 354 972 120 'Missing characters' 'If only a few characters are displayed as squares, check the Primary language font coverage. The dual-subtitle data can still be correct even when a font lacks a glyph.' ([System.Drawing.Color]::FromArgb(234,88,12))

    # Other languages
    $p=New-GuidePage 'Other languages';Add-GuideTitle $p 'Other languages' 'Primary language is shown first; Secondary is appended after the separator.'
    Add-GuideCard $p 22 102 972 130 'Standard / Latin-based languages' 'The verified Ukrainian Secondary font patch is intended for Latin-based Primary languages. Examples: English → Ukrainian, Polish → Ukrainian, German → Ukrainian, Spanish → Ukrainian.' $uiBlue
    Add-GuideCard $p 22 246 972 130 'Language order' 'Changing Primary and Secondary changes the order of the two subtitles. Example: English + Polish gives English first and Polish after  ~  . Polish + English does the opposite.' $uiGreen
    Add-GuideCard $p 22 390 972 120 'If a pair behaves differently' 'First check the exact Primary → Secondary pair. If the second line is present but individual letters are missing, this is normally font coverage rather than a failed merge.' ([System.Drawing.Color]::FromArgb(234,88,12))

    # CJK / Arabic
    $p=New-GuidePage 'JP / CN / KR / AR';Add-GuideTitle $p 'Japanese / Chinese / Korean / Arabic' 'These language-specific Primary fonts have known character-coverage limitations.'
    Add-GuideCard $p 22 102 972 126 'Japanese Primary' 'Japanese → English can work because the Japanese font contains basic Latin glyphs. Japanese → Polish or Japanese → Ukrainian can show squares for characters that are not present in the Japanese font.' $uiBlue
    Add-GuideCard $p 22 242 972 126 'Chinese / Korean / Arabic Primary' 'The same principle applies: the Secondary text can be correctly merged while some Secondary characters are missing from the Primary font.' $uiGreen
    Add-GuideCard $p 22 382 972 126 'What to do' 'Do not assume the subtitle merge is broken when the second line is visible. This build deliberately keeps the verified Ukrainian font patch small and does not apply large JP/CN/ZH/KR/AR font modifications.' ([System.Drawing.Color]::FromArgb(234,88,12))

    # Restore
    $p=New-GuidePage 'Restore & troubleshooting';Add-GuideTitle $p 'Restore & troubleshooting' 'Safe recovery steps if you want to return to the original game files.'
    Add-GuideCard $p 22 102 972 108 'SAFE TEST' 'Reads and rebuilds temporary data only. Real game files are not changed. Some DLC or mod resources can be skipped or fail to decode.' $uiBlue
    Add-GuideCard $p 22 222 972 108 'INSTALL' 'Creates backups before changing language resources. The verified Ukrainian font patch is handled separately from the language files.' $uiGreen
    Add-GuideCard $p 22 342 972 108 'RESTORE ORIGINALS' 'Restores the language files backed up by this installer and restores the original r4gui.bundle font bundle.' ([System.Drawing.Color]::FromArgb(124,58,237))
    Add-GuideCard $p 22 462 972 108 'If something looks wrong' "1. Close The Witcher 3 completely.$nl2. Use RESTORE ORIGINALS.$nl3. Restart the game.$nl4. Run SCAN again before another test." ([System.Drawing.Color]::FromArgb(220,38,38))

    $close=New-Object System.Windows.Forms.Button
    $close.Text='Close';$close.Size=New-Object System.Drawing.Size(100,34);$close.Location=New-Object System.Drawing.Point(470,712)
    Style-Button $close
    $g.Controls.Add($close);$close.Add_Click({$g.Close()})
    [void]$g.ShowDialog($form)
}

function Validate-UIState {
    $game=$txtPath.Text.Trim()
    return (Test-Path (Join-Path $game 'content') -PathType Container) -and $cmbPrimary.SelectedItem -and $cmbSecondary.SelectedItem -and ($cmbPrimary.SelectedItem.Code -ne $cmbSecondary.SelectedItem.Code)
}
function Refresh-InstallState {
    $ok=Validate-UIState;$btnInstall.Enabled=$ok
    if($ok){$lblStatus.Text="Ready: $($cmbPrimary.SelectedItem.Label) + $($cmbSecondary.SelectedItem.Label). Recursive scan includes DLC and mods."}else{$lblStatus.Text='Select a valid game folder and two different detected languages.'}
}
function Populate-Languages {
    $game=$txtPath.Text.Trim();$cmbPrimary.Items.Clear();$cmbSecondary.Items.Clear();$script:ResourceCache=@{}
    if(-not(Test-Path (Join-Path $game 'content') -PathType Container)){Refresh-InstallState;return}
    Log 'Scanning all .w3strings resources under the Witcher 3 folder (fast filename scan; content detection only for suspicious/custom slots)...';
    $langs=Get-Languages $game
    foreach($l in $langs){$item=[pscustomobject]@{Code=$l;Label=(Language-Label $l)};[void]$cmbPrimary.Items.Add($item);[void]$cmbSecondary.Items.Add($item)}
    if($langs.Count -gt 0){
        $dp=if($langs -contains 'pl'){'pl'}else{$langs[0]};$ds=if($langs -contains 'ua' -and $dp -ne 'ua'){'ua'}elseif($langs -contains 'uk' -and $dp -ne 'uk'){'uk'}elseif($langs -contains 'ru' -and $dp -ne 'ru'){'ru'}else{$langs|Where-Object{$_ -ne $dp}|Select-Object -First 1}
        $cmbPrimary.SelectedItem=($cmbPrimary.Items|Where-Object{$_.Code -eq $dp}|Select-Object -First 1);$cmbSecondary.SelectedItem=($cmbSecondary.Items|Where-Object{$_.Code -eq $ds}|Select-Object -First 1)
        Log ('Detected logical languages: '+(($langs|ForEach-Object{Language-Label $_}) -join ', '))
        $all=Get-AllResources $game
        $custom=$all|Where-Object{$_.DetectedCode -ne $_.PhysicalCode}
        foreach($r in $custom|Select-Object -First 30){Log "Custom/replaced localization: $($r.RelativePath) -> detected $($r.DetectedCode) (physical $($r.PhysicalCode))"}
    }
    Refresh-InstallState
}

# ---------------------------
# Modern main window
# ---------------------------

# ========================= POLISHED WITCHER UI =========================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$uiBg=[System.Drawing.Color]::FromArgb(9,14,20)
$uiPanel=[System.Drawing.Color]::FromArgb(17,25,34)
$uiPanel2=[System.Drawing.Color]::FromArgb(22,32,43)
$uiBorder=[System.Drawing.Color]::FromArgb(52,68,84)
$uiText=[System.Drawing.Color]::FromArgb(241,245,249)
$uiMuted=[System.Drawing.Color]::FromArgb(163,174,187)
$uiBlue=[System.Drawing.Color]::FromArgb(45,125,235)
$uiBlueDark=[System.Drawing.Color]::FromArgb(24,72,140)
$uiGreen=[System.Drawing.Color]::FromArgb(52,211,153)
$uiOrange=[System.Drawing.Color]::FromArgb(245,158,11)
$uiRed=[System.Drawing.Color]::FromArgb(239,68,68)
$uiPurple=[System.Drawing.Color]::FromArgb(139,92,246)
$uiWhite=[System.Drawing.Color]::White

function New-UiFont([string]$name,[float]$size,[System.Drawing.FontStyle]$style=[System.Drawing.FontStyle]::Regular) {
    return [System.Drawing.Font]::new($name,[float]$size,$style)
}
function New-UiLabel([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[int]$size=10,[bool]$bold=$false,[System.Drawing.Color]$color=$uiText) {
    $l=New-Object System.Windows.Forms.Label
    $l.Text=$text;$l.Location=New-Object System.Drawing.Point($x,$y);$l.Size=New-Object System.Drawing.Size($w,$h)
    $fs=[System.Drawing.FontStyle]::Regular;if($bold){$fs=[System.Drawing.FontStyle]::Bold}
    $l.Font=New-UiFont 'Segoe UI' $size $fs;$l.ForeColor=$color;$l.BackColor=[System.Drawing.Color]::Transparent
    return $l
}
function Style-Button($b,[System.Drawing.Color]$back=$uiPanel2,[System.Drawing.Color]$fore=$uiText,[bool]$primary=$false) {
    $b.FlatStyle='Flat';$b.FlatAppearance.BorderSize=1
    if($primary){$b.FlatAppearance.BorderColor=$uiBlue}else{$b.FlatAppearance.BorderColor=$uiBorder}
    $b.BackColor=$back;$b.ForeColor=$fore;$b.Font=New-UiFont 'Segoe UI' 9 ([System.Drawing.FontStyle]::Bold);$b.Cursor=[System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor=$false
}
function New-Card([int]$x,[int]$y,[int]$w,[int]$h,[System.Drawing.Color]$back=$uiPanel2,[System.Drawing.Color]$border=$uiBorder) {
    $p=New-Object System.Windows.Forms.Panel;$p.Location=New-Object System.Drawing.Point($x,$y);$p.Size=New-Object System.Drawing.Size($w,$h)
    $p.BackColor=$back;$p.BorderStyle='FixedSingle';return $p
}
function New-NavButton([string]$text,[int]$y,[scriptblock]$action) {
    $b=New-Object System.Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object System.Drawing.Point(12,$y);$b.Size=New-Object System.Drawing.Size(166,44)
    $b.FlatStyle='Flat';$b.FlatAppearance.BorderSize=0;$b.BackColor=[System.Drawing.Color]::FromArgb(15,22,30);$b.ForeColor=$uiText
    $b.Font=New-UiFont 'Segoe UI' 9 ([System.Drawing.FontStyle]::Bold);$b.TextAlign='MiddleLeft';$b.Padding=New-Object System.Windows.Forms.Padding(14,0,0,0);$b.Cursor=[System.Windows.Forms.Cursors]::Hand
    $b.Add_Click($action);$sidebar.Controls.Add($b);return $b
}

function Show-Guide([int]$startTab=0) {
    $g=New-Object System.Windows.Forms.Form
    $g.Text='The Witcher 3 — Dual Subtitles Guide';$g.ClientSize=New-Object System.Drawing.Size(1100,790);$g.StartPosition='CenterParent';$g.BackColor=$uiBg
    $g.MinimizeBox=$false;$g.MaximizeBox=$false
    $banner=New-Object System.Windows.Forms.PictureBox;$banner.Location=New-Object System.Drawing.Point(0,0);$banner.Size=New-Object System.Drawing.Size(1100,150);$banner.SizeMode='StretchImage';$banner.BackColor=$uiBg
    $imgPath=Join-Path $PSScriptRoot 'header_art.png';if(Test-Path $imgPath){$banner.Image=[System.Drawing.Image]::FromFile($imgPath)};$g.Controls.Add($banner)
    $shade=New-Object System.Windows.Forms.Panel;$shade.Location=New-Object System.Drawing.Point(0,0);$shade.Size=New-Object System.Drawing.Size(1100,150);$shade.BackColor=[System.Drawing.Color]::FromArgb(145,7,12,18);$g.Controls.Add($shade)
    $shade.Controls.Add((New-UiLabel 'THE WITCHER 3' 28 20 420 38 22 $true $uiWhite));$shade.Controls.Add((New-UiLabel 'Universal Dual Subtitles  •  Remastered' 30 62 500 28 11 $false $uiMuted))
    $tabs=New-Object System.Windows.Forms.TabControl;$tabs.Location=New-Object System.Drawing.Point(18,165);$tabs.Size=New-Object System.Drawing.Size(1064,560);$tabs.BackColor=$uiBg;$tabs.ForeColor=$uiText;$g.Controls.Add($tabs)
    function New-GuidePage([string]$title){$page=New-Object System.Windows.Forms.TabPage;$page.Text=$title;$page.BackColor=$uiBg;$scroll=New-Object System.Windows.Forms.Panel;$scroll.Dock='Fill';$scroll.AutoScroll=$true;$page.Controls.Add($scroll);[void]$tabs.TabPages.Add($page);return $scroll}
    function Add-GuideTitle($p,[string]$title,[string]$sub){$p.Controls.Add((New-UiLabel $title 22 18 960 34 19 $true $uiWhite));$p.Controls.Add((New-UiLabel $sub 22 54 960 38 10 $false $uiMuted))}
    function Add-GuideCard($p,[int]$x,[int]$y,[int]$w,[int]$h,[string]$title,[string]$body,[System.Drawing.Color]$accent,[string]$num=''){
        $c=New-Card $x $y $w $h $uiPanel2 $uiBorder;$p.Controls.Add($c);$bar=New-Object System.Windows.Forms.Panel;$bar.Location=New-Object System.Drawing.Point(0,0);$bar.Size=New-Object System.Drawing.Size(5,$h);$bar.BackColor=$accent;$c.Controls.Add($bar)
        $tx=22;if($num){$n=New-UiLabel $num 18 12 34 34 13 $true $accent;$n.TextAlign='MiddleCenter';$c.Controls.Add($n);$tx=68}
        $c.Controls.Add((New-UiLabel $title $tx 12 ($w-$tx-18) 26 12 $true $uiText));$bodyLbl=New-UiLabel $body $tx 44 ($w-$tx-22) ($h-52) 10 $false $uiMuted;$bodyLbl.AutoEllipsis=$false;$c.Controls.Add($bodyLbl)
    }
    $nl=[Environment]::NewLine
    $p=New-GuidePage 'Quick start';Add-GuideTitle $p 'Quick Start' 'Everything needed to create and install a dual-subtitle setup.'
    Add-GuideCard $p 22 105 620 88 'Select game folder' 'Use Browse or Scan. The scanner checks Steam libraries automatically.' $uiBlue '1'
    Add-GuideCard $p 22 203 620 88 'Choose languages' 'Primary is shown first. Secondary is added after the  ~  separator.' $uiGreen '2'
    Add-GuideCard $p 22 301 620 88 'Run SAFE TEST' 'SAFE TEST builds temporary data only. It does not change real game files.' $uiOrange '3'
    Add-GuideCard $p 22 399 620 88 'Install' 'After a successful test, click INSTALL and launch the game.' $uiPurple '4'
    Add-GuideCard $p 660 105 360 170 'How it works' "Primary subtitle${nl}~  Secondary subtitle${nl}${nl}Example:${nl}Nowa gra${nl}~  Нова гра" $uiBlue
    Add-GuideCard $p 660 291 360 196 'Important' "• Close The Witcher 3 before INSTALL.${nl}• Run SAFE TEST first.${nl}• DLC and mod resources are scanned.${nl}• Missing glyphs can be a font-coverage issue." $uiRed
    Add-GuideCard $p 22 497 998 78 'Language order' 'English → Polish     |     Polish → Ukrainian     |     Ukrainian → English     |     German → Ukrainian' $uiGreen
    $p=New-GuidePage 'Ukrainian Secondary';Add-GuideTitle $p 'Ukrainian Secondary' 'The verified path for Ukrainian as the Secondary language in this build.'
    Add-GuideCard $p 22 105 998 112 'Verified combinations' "Polish → Ukrainian${nl}English → Ukrainian${nl}German → Ukrainian${nl}Spanish → Ukrainian" $uiGreen
    Add-GuideCard $p 22 229 998 116 'What success looks like' 'The Primary subtitle stays first and Ukrainian appears after  ~  . If the Ukrainian sentence is complete, the merge and the verified EN-font Ukrainian patch are working.' $uiBlue
    Add-GuideCard $p 22 357 998 120 'If some letters are squares' 'If the second subtitle is present but a few characters are missing, the selected Primary font may not contain those glyphs. This is most noticeable with Japanese, Chinese, Korean and Arabic Primary languages.' $uiOrange
    $p=New-GuidePage 'Other languages';Add-GuideTitle $p 'Other languages' 'The tool keeps the selected order for the two subtitle lines.'
    Add-GuideCard $p 22 105 998 126 'Latin-based Primary languages' 'The verified Ukrainian Secondary patch is intended for the normal Latin-based Primary fonts used by English, Polish, German, Spanish and similar languages.' $uiBlue
    Add-GuideCard $p 22 243 998 126 'Changing the order' 'English + Polish gives English first and Polish after  ~  . Polish + English gives Polish first and English after  ~  .' $uiGreen
    Add-GuideCard $p 22 381 998 120 'When a pair looks wrong' 'Check whether the second line exists. If it exists and only certain characters are missing, the merge is working and the limitation is usually font coverage.' $uiOrange
    $p=New-GuidePage 'JP / CN / KR / AR';Add-GuideTitle $p 'Japanese / Chinese / Korean / Arabic' 'Language-specific fonts can have narrower glyph coverage for another language.'
    Add-GuideCard $p 22 105 998 150 'Japanese / Chinese / Korean / Arabic Primary' 'Dual subtitles can still work, but characters from the Secondary language that are absent from the active Primary font may appear as squares. For example, Japanese → Polish can show the Polish line with some missing letters.' $uiOrange
    Add-GuideCard $p 22 269 998 120 'What to do' 'This build does not replace the large CJK/Arabic font resources. Keep the working EN-font Ukrainian patch intact and treat missing glyphs in these language combinations as a known font limitation.' $uiBlue
    $p=New-GuidePage 'Restore & troubleshooting';Add-GuideTitle $p 'Restore & troubleshooting' 'Safe recovery steps when a setup needs to be reverted.'
    Add-GuideCard $p 22 105 998 120 'SAFE TEST' 'SAFE TEST works with temporary files. It should be used before INSTALL whenever you change the language pair.' $uiBlue
    Add-GuideCard $p 22 239 998 130 'RESTORE ORIGINALS' 'Use RESTORE ORIGINALS to restore the language resources and the original r4gui.bundle backup created by this installer.' $uiGreen
    Add-GuideCard $p 22 383 998 138 'If something looks wrong' 'Close the game completely, restore originals, restart the game, then scan again. If the second line exists but specific glyphs are missing, check the font-coverage tab above.' $uiOrange
    $tabs.SelectedIndex=[Math]::Max(0,[Math]::Min($startTab,$tabs.TabPages.Count-1))
    $close=New-Object System.Windows.Forms.Button;$close.Text='Close';$close.Location=New-Object System.Drawing.Point(492,742);$close.Size=New-Object System.Drawing.Size(116,32);Style-Button $close;$g.Controls.Add($close);$close.Add_Click({$g.Close()})
    [void]$g.ShowDialog()
}

$form=New-Object System.Windows.Forms.Form
$form.Text='The Witcher 3 — Universal Dual Subtitles';$form.ClientSize=New-Object System.Drawing.Size(1200,820);$form.StartPosition='CenterScreen';$form.MaximizeBox=$false;$form.MinimizeBox=$true;$form.BackColor=$uiBg

$art=New-Object System.Windows.Forms.PictureBox;$art.Location=New-Object System.Drawing.Point(0,0);$art.Size=New-Object System.Drawing.Size(1200,230);$art.SizeMode='StretchImage';$imgPath=Join-Path $PSScriptRoot 'header_art.png';if(Test-Path $imgPath){$art.Image=[System.Drawing.Image]::FromFile($imgPath)};$form.Controls.Add($art)
$artShade=New-Object System.Windows.Forms.Panel;$artShade.Location=New-Object System.Drawing.Point(0,0);$artShade.Size=New-Object System.Drawing.Size(1200,230);$artShade.BackColor=[System.Drawing.Color]::FromArgb(135,6,12,18);$form.Controls.Add($artShade)
$artShade.Controls.Add((New-UiLabel 'THE WITCHER 3' 34 28 430 42 26 $true $uiWhite));$artShade.Controls.Add((New-UiLabel 'UNIVERSAL DUAL SUBTITLES' 36 72 520 30 12 $true $uiMuted));$artShade.Controls.Add((New-UiLabel 'REMASTERED' 38 107 300 40 18 $true $uiOrange))
$ver=New-UiLabel 'v12 Remastered  •  Ukrainian Secondary' 850 38 310 26 9 $false $uiWhite;$ver.TextAlign='MiddleRight';$artShade.Controls.Add($ver)

$sidebar=New-Object System.Windows.Forms.Panel;$sidebar.Location=New-Object System.Drawing.Point(0,190);$sidebar.Size=New-Object System.Drawing.Size(190,630);$sidebar.BackColor=[System.Drawing.Color]::FromArgb(235,8,14,20);$form.Controls.Add($sidebar)
$sideTitle=New-UiLabel 'UNIVERSAL' 18 20 150 22 9 $true $uiMuted;$sidebar.Controls.Add($sideTitle);$sideTitle2=New-UiLabel 'DUAL SUBTITLES' 18 42 160 26 11 $true $uiText;$sidebar.Controls.Add($sideTitle2)
New-NavButton '⌂   Quick start' 82 {Show-Guide 0}|Out-Null
New-NavButton '▣   Ukrainian Secondary' 132 {Show-Guide 1}|Out-Null
New-NavButton '文   Other languages' 182 {Show-Guide 2}|Out-Null
New-NavButton '文   JP / CN / KR / AR' 232 {Show-Guide 3}|Out-Null
New-NavButton '↻   Restore & troubleshooting' 282 {Show-Guide 4}|Out-Null
New-NavButton '▤   Guide' 344 {Show-Guide 0}|Out-Null
New-NavButton 'ⓘ   About' 394 {[System.Windows.Forms.MessageBox]::Show("Universal Dual Subtitles`n`nThe Witcher 3 Remastered`nv12 + verified Ukrainian Secondary font patch`n`nCreated by ExiZZ",'About','OK','Information')|Out-Null}|Out-Null
$sidebar.Controls.Add((New-UiLabel 'ExiZZ' 18 548 150 20 9 $true $uiMuted));$sidebar.Controls.Add((New-UiLabel 'Universal Dual Subtitles' 18 570 160 20 8 $false $uiMuted));$sidebar.Controls.Add((New-UiLabel 'v12 Remastered' 18 592 160 20 8 $false $uiMuted))

# Main content area
$pathCard=New-Card 210 248 970 88;$form.Controls.Add($pathCard)
$pathCard.Controls.Add((New-UiLabel '1  •  GAME FOLDER' 18 10 220 22 9 $true $uiBlue));$pathCard.Controls.Add((New-UiLabel 'Choose your The Witcher 3 installation folder.' 18 34 400 20 9 $false $uiMuted))
$txtPath=New-Object System.Windows.Forms.TextBox;$txtPath.Location=New-Object System.Drawing.Point(18,55);$txtPath.Size=New-Object System.Drawing.Size(720,26);$txtPath.Font=New-UiFont 'Segoe UI' 9;$txtPath.BackColor=[System.Drawing.Color]::FromArgb(9,14,20);$txtPath.ForeColor=$uiText;$txtPath.BorderStyle='FixedSingle';$found=Find-Witcher3;if($found){$txtPath.Text=$found};$pathCard.Controls.Add($txtPath)
$btnBrowse=New-Object System.Windows.Forms.Button;$btnBrowse.Text='Browse…';$btnBrowse.Location=New-Object System.Drawing.Point(750,53);$btnBrowse.Size=New-Object System.Drawing.Size(98,30);Style-Button $btnBrowse;$pathCard.Controls.Add($btnBrowse)
$btnScan=New-Object System.Windows.Forms.Button;$btnScan.Text='↻  Scan';$btnScan.Location=New-Object System.Drawing.Point(856,53);$btnScan.Size=New-Object System.Drawing.Size(94,30);Style-Button $btnScan;$pathCard.Controls.Add($btnScan)

$langCard=New-Card 210 348 970 124 $uiPanel2 $uiBorder;$form.Controls.Add($langCard);$langCard.Controls.Add((New-UiLabel '2  •  SUBTITLE LANGUAGES' 18 10 280 24 10 $true $uiGreen));$langCard.Controls.Add((New-UiLabel 'Primary is shown first. Secondary is added after  ~  .' 18 34 600 20 9 $false $uiMuted))
$langCard.Controls.Add((New-UiLabel 'PRIMARY LANGUAGE' 18 61 200 18 8 $true $uiMuted));$langCard.Controls.Add((New-UiLabel 'SECONDARY LANGUAGE' 500 61 220 18 8 $true $uiMuted))
$cmbPrimary=New-Object System.Windows.Forms.ComboBox;$cmbPrimary.Location=New-Object System.Drawing.Point(18,82);$cmbPrimary.Size=New-Object System.Drawing.Size(450,30);$cmbPrimary.DropDownStyle='DropDownList';$cmbPrimary.DisplayMember='Label';$cmbPrimary.Font=New-UiFont 'Segoe UI' 10;$cmbPrimary.BackColor=[System.Drawing.Color]::FromArgb(9,14,20);$cmbPrimary.ForeColor=$uiText;$langCard.Controls.Add($cmbPrimary)
$cmbSecondary=New-Object System.Windows.Forms.ComboBox;$cmbSecondary.Location=New-Object System.Drawing.Point(500,82);$cmbSecondary.Size=New-Object System.Drawing.Size(450,30);$cmbSecondary.DropDownStyle='DropDownList';$cmbSecondary.DisplayMember='Label';$cmbSecondary.Font=New-UiFont 'Segoe UI' 10;$cmbSecondary.BackColor=[System.Drawing.Color]::FromArgb(9,14,20);$cmbSecondary.ForeColor=$uiText;$langCard.Controls.Add($cmbSecondary)

$statusCard=New-Card 210 484 970 54 $uiPanel $uiBorder;$form.Controls.Add($statusCard);$statusDot=New-UiLabel '●' 16 15 18 20 10 $true $uiOrange;$statusCard.Controls.Add($statusDot);$lblStatus=New-UiLabel 'Select a game folder or click Scan.' 42 12 900 30 10 $false $uiMuted;$statusCard.Controls.Add($lblStatus)

$actions=New-Object System.Windows.Forms.Panel;$actions.Location=New-Object System.Drawing.Point(210,550);$actions.Size=New-Object System.Drawing.Size(970,60);$actions.BackColor=[System.Drawing.Color]::Transparent;$form.Controls.Add($actions)
$btnTest=New-Object System.Windows.Forms.Button;$btnTest.Text='⚗  SAFE TEST';$btnTest.Location=New-Object System.Drawing.Point(0,7);$btnTest.Size=New-Object System.Drawing.Size(190,46);Style-Button $btnTest $uiPanel2 $uiBlue $true;$actions.Controls.Add($btnTest)
$btnInstall=New-Object System.Windows.Forms.Button;$btnInstall.Text='↓  INSTALL';$btnInstall.Location=New-Object System.Drawing.Point(202,7);$btnInstall.Size=New-Object System.Drawing.Size(190,46);Style-Button $btnInstall $uiRed $uiWhite $true;$actions.Controls.Add($btnInstall)
$btnRestore=New-Object System.Windows.Forms.Button;$btnRestore.Text='↻  RESTORE ORIGINALS';$btnRestore.Location=New-Object System.Drawing.Point(404,7);$btnRestore.Size=New-Object System.Drawing.Size(210,46);Style-Button $btnRestore;$actions.Controls.Add($btnRestore)
$btnGuide=New-Object System.Windows.Forms.Button;$btnGuide.Text='▤  GUIDE';$btnGuide.Location=New-Object System.Drawing.Point(626,7);$btnGuide.Size=New-Object System.Drawing.Size(150,46);Style-Button $btnGuide;$actions.Controls.Add($btnGuide)
$btnAbout=New-Object System.Windows.Forms.Button;$btnAbout.Text='ⓘ  ABOUT';$btnAbout.Location=New-Object System.Drawing.Point(788,7);$btnAbout.Size=New-Object System.Drawing.Size(150,46);Style-Button $btnAbout;$actions.Controls.Add($btnAbout)

$logCard=New-Card 210 622 970 166 $uiPanel2 $uiBorder;$form.Controls.Add($logCard);$logCard.Controls.Add((New-UiLabel 'Activity log' 16 10 180 24 11 $true $uiText));$logCard.Controls.Add((New-UiLabel 'installer results' 180 11 260 20 9 $false $uiMuted))
$txtLog=New-Object System.Windows.Forms.TextBox;$txtLog.Multiline=$true;$txtLog.ReadOnly=$true;$txtLog.ScrollBars='Vertical';$txtLog.Location=New-Object System.Drawing.Point(16,40);$txtLog.Size=New-Object System.Drawing.Size(938,108);$txtLog.Font=New-UiFont 'Cascadia Mono' 8;$txtLog.BackColor=[System.Drawing.Color]::FromArgb(7,11,16);$txtLog.ForeColor=$uiText;$txtLog.BorderStyle='FixedSingle';$logCard.Controls.Add($txtLog)

$btnAbout.Add_Click({[System.Windows.Forms.MessageBox]::Show("Universal Dual Subtitles`n`nThe Witcher 3 Remastered`nv12 + verified Ukrainian Secondary font patch`n`nCreated by ExiZZ",'About','OK','Information')|Out-Null})
$btnBrowse.Add_Click({$d=New-Object System.Windows.Forms.FolderBrowserDialog;$d.Description='Select The Witcher 3 installation folder';if($d.ShowDialog() -eq 'OK'){$txtPath.Text=$d.SelectedPath;Populate-Languages}})
$btnScan.Add_Click({$btnScan.Enabled=$false;try{if(-not(Test-Path (Join-Path $txtPath.Text.Trim() 'content') -PathType Container)){Log 'Game folder not set or invalid. Searching Steam libraries...';$found=Find-Witcher3;if($found){$txtPath.Text=$found;Log "Found The Witcher 3: $found"}else{Log 'The Witcher 3 was not found automatically. Use Browse to select the game folder.';[System.Windows.Forms.MessageBox]::Show('The Witcher 3 was not found automatically. Please select the game folder with Browse.','Game not found','OK','Information')|Out-Null;return}};Populate-Languages}finally{$btnScan.Enabled=$true}})
$txtPath.Add_TextChanged({})
$cmbPrimary.Add_SelectedIndexChanged({Refresh-InstallState});$cmbSecondary.Add_SelectedIndexChanged({Refresh-InstallState})
$btnTest.Add_Click({
    if(-not(Validate-UIState)){[System.Windows.Forms.MessageBox]::Show('Select a valid Witcher 3 folder and choose two different languages.','Cannot test');return}
    $btnTest.Enabled=$false;try{if(-not(Test-FontBundlePackage)){throw 'Bundled Ukrainian font patch is missing or invalid.'};$p=$cmbPrimary.SelectedItem.Code;$s=$cmbSecondary.SelectedItem.Code;Log "SAFE TEST STARTED: $p + $s. Real files will not be changed.";$targets=Get-Targets $txtPath.Text.Trim() $p $s;$ok=0;$skip=0;$fail=0;foreach($t in $targets){$r=Process-Target $t $p $s $false;if($r -eq 'PASS'){$ok++}elseif($r -eq 'SKIP'){$skip++}else{$fail++}};Log "SAFE TEST FINISHED: $ok passed; $skip skipped; $fail failed.";$statusDot.Text='●';$statusDot.ForeColor=if($fail -eq 0){$uiGreen}else{$uiOrange};[System.Windows.Forms.MessageBox]::Show("Safe test finished.`n`nPassed: $ok`nSkipped: $skip`nFailed: $fail`n`nNo real game files were changed.",'Safe test')}finally{$btnTest.Enabled=$true;Refresh-InstallState}
})
$btnInstall.Add_Click({
    if(-not(Validate-UIState)){[System.Windows.Forms.MessageBox]::Show('Select a valid Witcher 3 folder and choose two different languages.','Cannot install');return}
    $p=$cmbPrimary.SelectedItem.Code;$s=$cmbSecondary.SelectedItem.Code
    if([System.Windows.Forms.MessageBox]::Show("Install dual subtitles?`n`nPrimary: $($cmbPrimary.SelectedItem.Label)`nSecondary: $($cmbSecondary.SelectedItem.Label)`n`nOriginal primary resources will be backed up first.",'Confirm installation','YesNo','Warning') -ne 'Yes'){return}
    $btnTest.Enabled=$false;$btnInstall.Enabled=$false;try{Log "INSTALL STARTED: $p + $s";$targets=Get-Targets $txtPath.Text.Trim() $p $s;$ok=0;$skip=0;$fail=0;foreach($t in $targets){$r=Process-Target $t $p $s $true;if($r -eq 'PASS'){$ok++}elseif($r -eq 'SKIP'){$skip++}else{$fail++}};$font='NOT ATTEMPTED';try{$font=Install-FontBundle $txtPath.Text.Trim()}catch{Log "FONT PATCH ERROR: $($_.Exception.Message)";$font='FAILED'};if($fail -gt 0){Log "WARNING: $fail string target(s) failed. The independent EN-font Ukrainian patch was still processed: $font."};Log "INSTALL FINISHED: $ok installed; $skip skipped; $fail failed; font patch: $font.";$statusDot.ForeColor=if($font -eq 'INSTALLED' -and $fail -eq 0){$uiGreen}else{$uiOrange};[System.Windows.Forms.MessageBox]::Show("Finished.`n`nInstalled: $ok`nSkipped: $skip`nFailed: $fail`nFont patch: $font`n`nThe font patch is independent of individual string-file failures.`nSee the log for details.",'Installation finished')}catch{Log "INSTALL ERROR: $($_.Exception.Message)";[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Installation error','OK','Error')}finally{$btnTest.Enabled=$true;Refresh-InstallState}
})
$btnRestore.Add_Click({$game=$txtPath.Text.Trim();if([System.Windows.Forms.MessageBox]::Show('Restore all language files backed up by this installer?','Confirm restore','YesNo','Warning') -ne 'Yes'){return};try{Restore-All $game;$statusDot.ForeColor=$uiGreen;[System.Windows.Forms.MessageBox]::Show('Restore complete. Fully restart The Witcher 3 before checking the result.','Restore')}catch{Log "RESTORE ERROR: $($_.Exception.Message)";$statusDot.ForeColor=$uiOrange}})
$btnGuide.Add_Click({Show-Guide 0})

if($txtPath.Text.Trim() -and (Test-Path (Join-Path $txtPath.Text.Trim() 'content') -PathType Container)){Populate-Languages}else{$lblStatus.Text='Select a valid game folder or click Scan to find it automatically.'}
try{Log 'Ready.';Log 'v12 Remastered + UA FONT TEST: recursive .w3strings scan + built-in v164 decoder/encoder; official EN/UA slots + EN-font Ukrainian glyph patch.';Log 'Click SCAN / REFRESH to detect languages.';[void]$form.ShowDialog()}catch{try{[System.Windows.Forms.MessageBox]::Show(('Witcher 3 Dual Subtitles v12 failed to start.`r`n`r`n'+$_.Exception.Message),'Dual Subtitles - Startup Error','OK','Error')|Out-Null}catch{};throw}
