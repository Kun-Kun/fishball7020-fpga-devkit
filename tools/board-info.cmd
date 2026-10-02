<# : the cmd launcher; PowerShell reads this block as a comment
@echo off
rem This one file is both a cmd launcher (this block) and the PowerShell script
rem after it, so it can be sent on its own. Windows will not run a .ps1 by
rem double-click or under the default execution policy, so the launcher copies
rem the whole file to %TEMP% as a .ps1 and runs that, policy bypassed for this
rem run only. Arguments pass through, e.g.  board-info.cmd -OutFile board.txt
setlocal
set "ps1=%TEMP%\board-info-%RANDOM%.ps1"
copy /y "%~f0" "%ps1%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%ps1%" %*
set rc=%errorlevel%
del "%ps1%" >nul 2>&1
rem Double-clicked: keep the window open so the report can be read.
echo %cmdcmdline% | find /i "/c" >nul && pause
exit /b %rc%
#>
<#
.SYNOPSIS
    Print everything a Fishball7020 board reports, from a Windows PC.

.DESCRIPTION
    Talks to the board's IIOD server (TCP port 30431) directly, so it needs
    nothing installed: no Python, no libiio, no ssh key. Windows PowerShell 5.1
    (built into Windows 10 and 11) is enough, and PowerShell 7 works too.

    It only READS. It never writes an attribute and never opens a buffer, so it
    cannot change what the radio is doing, and it never makes the board transmit.

    What it prints, in order:
      1. This PC: whether the board is plugged in over USB, and the network
         adapters that can reach it.
      2. Where the board was found.
      3. A summary: model, serial, firmware, kernel, the tuning of both
         receive and transmit, chip temperature and supply voltages.
      4. Every attribute of every IIO device, with its current value.
         (IIO, "Industrial I/O", is the Linux driver interface the radio chip
         and the FPGA's sample paths sit behind; libiio and SDR apps use it.)

    The board is looked for in this order: -Board, then $env:BOARD, then
    fishball.local, Fishball7020.local, pluto.local, and last the USB address
    192.168.2.1, which never changes.

.PARAMETER Board
    The board's hostname or IP address. "ip:HOST" is accepted too.

.PARAMETER DebugAttrs
    Also read the debug attributes (/sys/kernel/debug/iio on the board): the
    AD9361's device-tree settings, BIST and loopback state. About 190 more
    lines. Still read-only.

.PARAMETER OutFile
    Also save the whole report to this file, e.g. to attach to a bug report.

.EXAMPLE
    # run from: the folder holding board-info.cmd, in cmd.exe or PowerShell
    .\board-info.cmd
    .\board-info.cmd -Board 192.168.2.1 -DebugAttrs -OutFile board.txt

    Or double-click it. It is a single file and needs nothing beside it.

.NOTES
    Exit code: 0 the board answered, 3 only its ssh answered (the SDR service,
    iiod, is down), 1 nothing answered. The same codes as tools/board_info.py.
#>
[CmdletBinding()]
param(
    [string]$Board,
    [switch]$DebugAttrs,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$IiodPort  = 30431
$SshPort   = 22
$Names     = @('fishball.local', 'Fishball7020.local', 'pluto.local')
$UsbAddr   = '192.168.2.1'
$UsbVidPid = 'VID_0456&PID_B673'    # Analog Devices; the board enumerates as an ADALM-PLUTO

$report = New-Object System.Collections.Generic.List[string]
function Out-Line([string]$text = '') {
    $report.Add($text)
    Write-Host $text
}
function Out-Head([string]$text) {
    Out-Line ''
    Out-Line "== $text =="
}
function Out-KV([string]$key, $value, [int]$width = 22) {
    # A multi-line value (the gain table, the RSSI step errors) keeps its lines,
    # indented under the first so the key column stays readable.
    $lines = "$value" -split "`r?`n"
    Out-Line ('   {0} {1}' -f ($key + ':').PadRight($width), $lines[0])
    foreach ($l in $lines | Select-Object -Skip 1) { Out-Line ((' ' * ($width + 4)) + $l) }
}

# ---------------------------------------------------------------- network --

# Which of this host's addresses accepts a TCP connection on the port, within
# the timeout? $null if none. Every address is tried, IPv4 first: an mDNS name
# can resolve to a link-local IPv6 address alone, and a TcpClient made without
# an address family would only ever try IPv4.
function Find-Address([string]$hostName, [int]$port, [int]$timeoutMs = 800) {
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($hostName) |
                 Sort-Object { $_.AddressFamily -ne 'InterNetwork' }
    } catch {
        return $null
    }
    foreach ($a in $addrs) {
        $c = New-Object System.Net.Sockets.TcpClient($a.AddressFamily)
        try {
            $ar = $c.BeginConnect($a, $port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($timeoutMs)) {
                $c.EndConnect($ar)
                return $a.ToString()
            }
        } catch {
        } finally {
            $c.Close()
        }
    }
    return $null
}

# A minimal IIOD client. The protocol: commands end in CRLF; every reply opens
# with a decimal line that is either a byte count or a negative errno, and
# attribute values are NUL-terminated. VERSION alone answers with a bare line.
class Iiod {
    [System.Net.Sockets.TcpClient]$Client
    [System.IO.Stream]$Stream
    [byte[]]$Buf = (New-Object byte[] 65536)
    [int]$Pos = 0
    [int]$Len = 0

    Iiod([string]$address, [int]$port) {
        $ip = [System.Net.IPAddress]::Parse($address)
        $this.Client = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
        $ar = $this.Client.BeginConnect($ip, $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(5000)) { throw "no answer from ${address}:$port" }
        $this.Client.EndConnect($ar)
        $this.Client.ReceiveTimeout = 10000
        $this.Client.SendTimeout = 10000
        $this.Stream = $this.Client.GetStream()
    }

    [void] Close() { $this.Client.Close() }

    hidden [int] NextByte() {
        if ($this.Pos -ge $this.Len) {
            $this.Len = $this.Stream.Read($this.Buf, 0, $this.Buf.Length)
            $this.Pos = 0
            if ($this.Len -le 0) { throw 'IIOD closed the connection' }
        }
        $b = $this.Buf[$this.Pos]
        $this.Pos++
        return $b
    }

    hidden [string] ReadLine() {
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $b = $this.NextByte()
            if ($b -eq 10) { break }
            if ($b -ne 13) { [void]$sb.Append([char]$b) }
        }
        return $sb.ToString()
    }

    hidden [byte[]] ReadBytes([int]$n) {
        $out = New-Object byte[] $n
        for ($i = 0; $i -lt $n; $i++) { $out[$i] = [byte]$this.NextByte() }
        return $out
    }

    hidden [void] Send([string]$command) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($command + "`r`n")
        $this.Stream.Write($bytes, 0, $bytes.Length)
        $this.Stream.Flush()
    }

    [string] Version() {
        $this.Send('VERSION')
        return $this.ReadLine().Trim()
    }

    # A length-prefixed reply as text. A negative length is an errno, and is
    # returned as "(not readable: NAME)" rather than thrown: some attributes always fail
    # to read, and one bad attribute must not end the report.
    [string] Text([string]$command) {
        $this.Send($command)
        $n = [int]$this.ReadLine().Trim()
        if ($n -lt 0) {
            $name = switch ($n) { -13 { 'EACCES' } -19 { 'ENODEV' } -22 { 'EINVAL' } default { "errno $(-$n)" } }
            return "(not readable: $name)"
        }
        $data = [System.Text.Encoding]::UTF8.GetString($this.ReadBytes($n))
        [void]$this.ReadLine()
        return $data.TrimEnd([char]0).Trim()
    }
}

# ------------------------------------------------------------------ host ---

Out-Line "Fishball7020 board report, $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

Out-Head 'this PC'
Out-KV 'computer' $env:COMPUTERNAME
Out-KV 'Windows' ([System.Environment]::OSVersion.VersionString)
Out-KV 'PowerShell' $PSVersionTable.PSVersion

if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
    $usb = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like "*$UsbVidPid*" })
    if ($usb.Count -eq 0) {
        Out-KV 'USB' 'board not plugged in over USB (or not enumerated)'
    } else {
        Out-KV 'USB' "board plugged in, $($usb.Count) Windows device(s):"
        foreach ($d in $usb | Sort-Object Class, FriendlyName) {
            Out-Line ('      {0,-8} {1,-12} {2}' -f $d.Status, $d.Class, $d.FriendlyName)
        }
    }
} else {
    Out-KV 'USB' '(Get-PnpDevice is not available on this Windows)'
}

if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
    $usbNet = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like '192.168.2.*' })
    if ($usbNet.Count -eq 0) {
        Out-KV 'USB network' 'no adapter on 192.168.2.x, so 192.168.2.1 is unreachable'
    } else {
        foreach ($a in $usbNet) {
            Out-KV 'USB network' "$($a.IPAddress)/$($a.PrefixLength) on '$($a.InterfaceAlias)'"
        }
    }
}

# ------------------------------------------------------------- find board --

$candidates = New-Object System.Collections.Generic.List[string]
foreach ($c in @($Board, $env:BOARD, $env:SDR_URI)) {
    if ($c) {
        $h = $c -replace '^ip:', ''
        if ($h -notmatch '^\[' -and ($h.Split(':').Count -eq 2)) { $h = $h.Split(':')[0] }
        $candidates.Add($h)
    }
}
if (-not $Board) {
    foreach ($n in $Names) { $candidates.Add($n) }
    $candidates.Add($UsbAddr)
}

Out-Head 'finding the board'
$found = $null
$foundAddr = $null
$sshOnly = $null
foreach ($h in $candidates) {
    $addr = Find-Address $h $IiodPort
    if ($addr) {
        Out-KV $h $(if ($addr -eq $h) { 'iiod answers' } else { "iiod answers at $addr" })
        $found = $h
        $foundAddr = $addr
        break
    } elseif (Find-Address $h $SshPort) {
        Out-KV $h 'only ssh answers'
        if (-not $sshOnly) { $sshOnly = $h }
    } else {
        Out-KV $h 'no answer'
    }
}

function Save-Report {
    if ($OutFile) {
        $report | Set-Content -Path $OutFile -Encoding UTF8
        Write-Host ''
        Write-Host "saved to $OutFile"
    }
}

if (-not $found) {
    Out-Line ''
    if ($sshOnly) {
        Out-Line "The board is at $sshOnly but its SDR service (iiod) is not running."
        Out-Line 'On the board: journalctl -b -u fishball-rf-quiesce -u iiod'
        Save-Report
        exit 3
    }
    Out-Line 'No board found. Check the USB cable carries data (not charge-only), that'
    Out-Line 'the board has mains power, and that a 192.168.2.x adapter shows above.'
    Save-Report
    exit 1
}

# -------------------------------------------------------------- read IIOD --

$io = [Iiod]::new($foundAddr, $IiodPort)
try {
    $iiodVersion = $io.Version()
    $raw = $io.Text('PRINT')
    # The XML opens with a DOCTYPE that .NET refuses to parse by default; the
    # <context> element after it is all that is needed.
    $start = $raw.IndexOf('<context ')
    $end = $raw.LastIndexOf('</context>')
    [xml]$ctx = $raw.Substring($start, $end + '</context>'.Length - $start)

    $cattrs = [ordered]@{}
    foreach ($a in $ctx.context.SelectNodes('context-attribute')) { $cattrs[$a.name] = $a.value }

    # Every attribute value, keyed "device/[in|out] channel/attr".
    $devices = @()
    foreach ($d in $ctx.context.SelectNodes('device')) {
        $dev = [ordered]@{
            Id = $d.id
            Name = $(if ($d.HasAttribute('name')) { $d.name } else { $d.id })
            Attrs = [ordered]@{}
            Channels = @()
            Debug = [ordered]@{}
        }
        foreach ($a in $d.SelectNodes('attribute')) {
            $dev.Attrs[$a.name] = $io.Text("READ $($d.id) $($a.name)")
        }
        foreach ($ch in $d.SelectNodes('channel')) {
            $dir = if ($ch.type -eq 'output') { 'OUTPUT' } else { 'INPUT' }
            $c = [ordered]@{
                Id = $ch.id
                Label = $(if ($ch.HasAttribute('name')) { "$($ch.id) ($($ch.name))" } else { $ch.id })
                Dir = $ch.type
                Attrs = [ordered]@{}
            }
            foreach ($a in $ch.SelectNodes('attribute')) {
                $c.Attrs[$a.name] = $io.Text("READ $($d.id) $dir $($ch.id) $($a.name)")
            }
            $dev.Channels += $c
        }
        if ($DebugAttrs) {
            foreach ($a in $d.SelectNodes('debug-attribute')) {
                $dev.Debug[$a.name] = $io.Text("READ $($d.id) DEBUG $($a.name)")
            }
        }
        $devices += $dev
    }
} finally {
    $io.Close()
}

function Get-Dev([string]$name) { $devices | Where-Object { $_.Name -eq $name } | Select-Object -First 1 }
function Get-Attr($dev, [string]$chId, [string]$dir, [string]$attr) {
    if (-not $dev) { return $null }
    $ch = $dev.Channels | Where-Object { $_.Id -eq $chId -and $_.Dir -eq $dir } | Select-Object -First 1
    if ($ch -and $ch.Attrs.Contains($attr)) { return $ch.Attrs[$attr] }
    return $null
}
function Get-Num($text) {
    $v = 0.0
    if ($text -and [double]::TryParse(($text -split '\s+')[0], [System.Globalization.NumberStyles]::Float,
                                       [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    return $null
}
# A number the same way on every PC: -f would use the Windows locale, which
# prints 2400 MHz as "2.400,000000" on a Belgian or German Windows.
function Format-Num([string]$fmt, $value) { [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $fmt, $value) }
function Format-MHz($hz) { $n = Get-Num $hz; if ($null -eq $n) { return '?' }; Format-Num '{0:F6} MHz' ($n / 1e6) }

# ---------------------------------------------------------------- summary --

Out-Head 'board'
Out-KV 'address' $(if ($foundAddr -eq $found) { $found } else { "$found ($foundAddr)" })
Out-KV 'IIOD version' $iiodVersion
Out-KV 'model' $(if ($cattrs.Contains('hw_model')) { $cattrs['hw_model'] } else { '?' })
Out-KV 'serial' $(if ($cattrs.Contains('hw_serial')) { $cattrs['hw_serial'] } else { '?' })
# The modern (Debian) firmware publishes fw_build, the full git describe of its
# build; the factory (Buildroot) firmware does not.
if ($cattrs.Contains('fw_build')) {
    Out-KV 'firmware' "modern (Debian), $($cattrs['fw_build'])"
} else {
    Out-KV 'firmware' "factory (Buildroot), $(if ($cattrs.Contains('fw_version')) { $cattrs['fw_version'] } else { '?' })"
}
Out-KV 'kernel' $(if ($cattrs.Contains('local,kernel')) { $cattrs['local,kernel'] } else { '?' })
Out-KV 'system' $ctx.context.description

$phy = Get-Dev 'ad9361-phy'
if ($phy) {
    Out-Head 'radio (AD9361)'
    Out-KV 'state (ENSM)' $phy.Attrs['ensm_mode']
    Out-KV 'RX LO' (Format-MHz (Get-Attr $phy 'altvoltage0' 'output' 'frequency'))
    Out-KV 'TX LO' (Format-MHz (Get-Attr $phy 'altvoltage1' 'output' 'frequency'))
    Out-KV 'RX sample rate' ('{0} S/s' -f (Get-Attr $phy 'voltage0' 'input' 'sampling_frequency'))
    Out-KV 'TX sample rate' ('{0} S/s' -f (Get-Attr $phy 'voltage0' 'output' 'sampling_frequency'))
    Out-KV 'RX bandwidth' ('{0} Hz' -f (Get-Attr $phy 'voltage0' 'input' 'rf_bandwidth'))
    Out-KV 'TX bandwidth' ('{0} Hz' -f (Get-Attr $phy 'voltage0' 'output' 'rf_bandwidth'))
    foreach ($i in 0, 1) {
        $mode = Get-Attr $phy "voltage$i" 'input' 'gain_control_mode'
        $gain = Get-Attr $phy "voltage$i" 'input' 'hardwaregain'
        $rssi = Get-Attr $phy "voltage$i" 'input' 'rssi'
        Out-KV "RX$($i + 1)" "gain $gain ($mode), RSSI $rssi, port $(Get-Attr $phy "voltage$i" 'input' 'rf_port_select')"
    }
    foreach ($i in 0, 1) {
        # hardwaregain on a TX channel is minus the attenuation: -89.75 dB is fully muted.
        Out-KV "TX$($i + 1)" "gain $(Get-Attr $phy "voltage$i" 'output' 'hardwaregain'), port $(Get-Attr $phy "voltage$i" 'output' 'rf_port_select')"
    }
    $t = Get-Num (Get-Attr $phy 'temp0' 'input' 'input')
    if ($null -ne $t) { Out-KV 'AD9361 temperature' (Format-Num '{0:F1} C' ($t / 1000)) }
    if ($cattrs.Contains('ad9361-phy,xo_correction')) { Out-KV 'reference clock' "$($cattrs['ad9361-phy,xo_correction']) Hz" }
}

$xadc = Get-Dev 'xadc'
if ($xadc) {
    Out-Head 'FPGA (Zynq XADC)'
    foreach ($ch in $xadc.Channels | Sort-Object { $_.Id -notlike 'temp*' }, { [int]($_.Id -replace '\D', '') }) {
        $raw = Get-Num $ch.Attrs['raw']
        $scale = Get-Num $ch.Attrs['scale']
        if ($null -eq $raw -or $null -eq $scale) { continue }
        $offset = Get-Num $(if ($ch.Attrs.Contains('offset')) { $ch.Attrs['offset'] } else { '0' })
        $value = ($raw + $offset) * $scale / 1000
        if ($ch.Id -like 'temp*') { Out-KV $ch.Label (Format-Num '{0:F1} C' $value) }
        else { Out-KV $ch.Label (Format-Num '{0:F3} V' $value) }
    }
}

# --------------------------------------------------------- everything else --

Out-Head 'context attributes'
foreach ($k in $cattrs.Keys) { Out-KV $k $cattrs[$k] 30 }

foreach ($dev in $devices) {
    Out-Head "$($dev.Name) ($($dev.Id))"
    foreach ($k in $dev.Attrs.Keys) { Out-KV $k $dev.Attrs[$k] 34 }
    foreach ($c in $dev.Channels) {
        if ($c.Attrs.Count -eq 0) { continue }
        Out-Line "   -- $($c.Dir) $($c.Label)"
        foreach ($k in $c.Attrs.Keys) { Out-KV "  $k" $c.Attrs[$k] 34 }
    }
    if ($DebugAttrs -and $dev.Debug.Count -gt 0) {
        Out-Line '   -- debug'
        foreach ($k in $dev.Debug.Keys) { Out-KV "  $k" $dev.Debug[$k] 34 }
    }
}

Save-Report
exit 0
