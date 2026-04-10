@echo off
setlocal enabledelayedexpansion

set "MAP_FILE=%~1"
set "MODE=%~2"
if "%MAP_FILE%"=="" (
    for %%f in ("%~dp0Objects\*.map") do set "MAP_FILE=%%f"
    for %%f in ("%~dp0Listings\*.map") do set "MAP_FILE=%%f"
)
if not defined MAP_FILE (
    echo [ERROR] No .map file. Usage: %~nx0 [file.map] [brief^|verbose]
    exit /b 1
)
if not exist "%MAP_FILE%" (
    echo [ERROR] Not found: %MAP_FILE%
    exit /b 1
)

set "TMPPS=%TEMP%\_kmap_%RANDOM%.ps1"
set "SKIP="
for /f "delims=:" %%a in ('findstr /n "^#PSSTART#" "%~f0"') do set "SKIP=%%a"
if not defined SKIP (
    echo [ERROR] Cannot find PSSTART marker
    exit /b 1
)
more +!SKIP! "%~f0" > "!TMPPS!"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "!TMPPS!" "!MAP_FILE!" "!MODE!"
del "!TMPPS!" >nul 2>&1
exit /b 0

#PSSTART#
param([string]$mapFile, [string]$mode = "brief")
if (-not (Test-Path $mapFile)) { Write-Host "[ERROR] Not found: $mapFile" -Fore Red; exit 1 }
$verbose = ($mode -eq "verbose" -or $mode -eq "v")
$lines = Get-Content $mapFile -Encoding Default

function Write-Header($t) {
    Write-Host ""
    Write-Host ("=" * 80) -Fore Cyan
    Write-Host "  $t" -Fore Yellow
    Write-Host ("=" * 80) -Fore Cyan
}
function Write-Sub($t) {
    Write-Host ""
    Write-Host "--- $t ---" -Fore Green
}
function FS([uint64]$b) {
    if ($b -ge 1MB) { return ("{0:N2} MB" -f ($b/1MB)) }
    if ($b -ge 1KB) { return ("{0:N2} KB" -f ($b/1KB)) }
    return "$b B"
}
function WB($l,[uint64]$v,[uint64]$m,$w,$c) {
    if ($m -le 0) { $m = 1 }
    $pct = [math]::Min(100,[math]::Round($v/$m*100,1))
    $f = [int][math]::Max(0,[math]::Round($pct/100*$w))
    $e = $w - $f
    Write-Host ("  {0,-36} [{1}{2}] {3,5}% ({4})" -f $l,("#"*$f),("-"*$e),$pct,(FS $v)) -Fore $c
}

$gC=0;$gR=0;$gW=0;$gZ=0;$gWFlash=0;$tROM=0;$tRAM=0
$LR = [System.Collections.ArrayList]::new()
$ER = [System.Collections.ArrayList]::new()
$SD = [System.Collections.ArrayList]::new()
$CD = [System.Collections.ArrayList]::new()
$LD = [System.Collections.ArrayList]::new()
$cL="";$cE="";$cI=-1
$inComponentSizes = $false

# Stack/Heap tracking
$stackSize = 0; $stackAddr = 0; $stackModule = ""
$heapSize = 0; $heapAddr = 0; $heapModule = ""
$heapRemoved = $false
$stackRemoved = $false
$initialSP = 0
$removedSections = [System.Collections.ArrayList]::new()

# MSP (Main Stack Pointer) from symbol table
$mspValue = 0

foreach ($line in $lines) {
    # Grand Totals
    if ($line -match '^\s+(\d+)\s+\d+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+Grand Totals') {
        $gC=[uint64]$Matches[1];$gR=[uint64]$Matches[2];$gW=[uint64]$Matches[3];$gZ=[uint64]$Matches[4]
        continue
    }
    # Program Size (alternative)
    if ($line -match 'Program Size:\s*Code=(\d+)\s*RO-data=(\d+)\s*RW-data=(\d+)\s*ZI-data=(\d+)') {
        $gC=[uint64]$Matches[1];$gR=[uint64]$Matches[2];$gW=[uint64]$Matches[3];$gZ=[uint64]$Matches[4]
        continue
    }
    # ROM Totals - actual flash-resident values (RW may be compressed)
    # Format: Code  (inc.data)  RO  RW  ZI  Debug  ROM Totals
    if ($line -match '^\s+(\d+)\s+\d+\s+(\d+)\s+(\d+)\s+\d+\s+\d+\s+ROM Totals') {
        $gWFlash = [uint64]$Matches[3]
        continue
    }
    # Load Region (capture optional COMPRESSED size)
    if ($line -match 'Load Region\s+(\S+)\s+\(Base:\s*(0x[0-9a-fA-F]+),\s*Size:\s*(0x[0-9a-fA-F]+),\s*Max:\s*(0x[0-9a-fA-F]+)') {
        $cL=$Matches[1]
        $lrObj=@{N=$Matches[1];B=[Convert]::ToUInt64($Matches[2],16);S=[Convert]::ToUInt64($Matches[3],16);M=[Convert]::ToUInt64($Matches[4],16);CS=[uint64]0}
        if ($line -match 'COMPRESSED\[(0x[0-9a-fA-F]+)\]') { $lrObj.CS = [Convert]::ToUInt64($Matches[1],16) }
        [void]$LR.Add($lrObj)
        continue
    }
    # Execution Region - full format
    if ($line -match 'Execution Region\s+(\S+)\s+\(Exec base:\s*(0x[0-9a-fA-F]+),\s*Load base:\s*(0x[0-9a-fA-F]+),\s*Size:\s*(0x[0-9a-fA-F]+),\s*Max:\s*(0x[0-9a-fA-F]+)') {
        $cE=$Matches[1]
        $o=@{N=$Matches[1];B=[Convert]::ToUInt64($Matches[2],16);LB=[Convert]::ToUInt64($Matches[3],16);S=[Convert]::ToUInt64($Matches[4],16);M=[Convert]::ToUInt64($Matches[5],16);L=$cL;SC=[System.Collections.ArrayList]::new()}
        $cI=$ER.Add($o);continue
    }
    # Execution Region - fallback
    if ($line -match 'Execution Region\s+(\S+)\s+\(.*Base:\s*(0x[0-9a-fA-F]+).*Size:\s*(0x[0-9a-fA-F]+).*Max:\s*(0x[0-9a-fA-F]+)') {
        $cE=$Matches[1]
        $o=@{N=$Matches[1];B=[Convert]::ToUInt64($Matches[2],16);LB=[Convert]::ToUInt64($Matches[2],16);S=[Convert]::ToUInt64($Matches[3],16);M=[Convert]::ToUInt64($Matches[4],16);L=$cL;SC=[System.Collections.ArrayList]::new()}
        $cI=$ER.Add($o);continue
    }
	# Symbol table: STACK/HEAP section entries
	# "    STACK                                    0x20002ce8   Section     1024  startup_stm32f103xe.o(STACK)"
	if ($line -match '^\s+(STACK|HEAP)\s+(0x[0-9a-fA-F]+)\s+Section\s+(\d+)\s+(\S+)') {
		$secType = $Matches[1]
		$secAddr = [Convert]::ToUInt64($Matches[2],16)
		$secSize = [uint64]$Matches[3]
		$secMod  = $Matches[4]
		if ($secType -eq 'STACK') {
			$stackSize = $secSize; $stackAddr = $secAddr; $stackModule = $secMod
		} else {
			$heapSize = $secSize; $heapAddr = $secAddr; $heapModule = $secMod
		}
		continue
	}
    # Section entries in memory map (verbose only - expensive regex on every line)
    if ($verbose) {
    # Supports both ARMCC5 format: exec_addr  load_addr  size  type  attr  idx  [*]  section  obj
    #             and ARMCC6 format: exec_addr  size  type  attr  idx  section  obj
    $_mA=$null; $_mZ=$null; $_mT=$null; $_mAT=$null; $_mRest=$null
    if ($line -match '^\s+(0x[0-9a-fA-F]+)\s+(?:0x[0-9a-fA-F]+|-)\s+(0x[0-9a-fA-F]+)\s+(Data|Code|Zero|PAD)\s*(\S*)(.*)$') {
        $_mA=$Matches[1];$_mZ=$Matches[2];$_mT=$Matches[3];$_mAT=$Matches[4];$_mRest=$Matches[5].Trim()
    } elseif ($line -match '^\s+(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s+(Data|Code|Zero|PAD)\s*(\S*)(.*)$') {
        $_mA=$Matches[1];$_mZ=$Matches[2];$_mT=$Matches[3];$_mAT=$Matches[4];$_mRest=$Matches[5].Trim()
    }
    if ($null -ne $_mA) {
        $addr = [Convert]::ToUInt64($_mA,16)
        $sz   = [Convert]::ToUInt64($_mZ,16)
        $secName = ""; $modName = ""
        if ($_mRest -match '^\d+\s+\*?\s*(\S+)\s+(.+)$') { $secName=$Matches[1]; $modName=$Matches[2].Trim() }
        elseif ($_mRest -match '^\d+\s+\*?\s*(\S+)$')    { $secName=$Matches[1] }
        if ($sz -eq 0) { continue }
        $e=[PSCustomObject]@{A=$addr;Z=$sz;T=$_mT;AT=$_mAT;SE=$secName;MO=$modName;RE=$cE}
        [void]$SD.Add($e)
        if ($cI -ge 0) { [void]$ER[$cI].SC.Add($e) }
        if ($secName -match '^STACK$' -or $secName -match '^\.\bstack\b') {
            $stackSize = $sz; $stackAddr = $addr; $stackModule = $modName
        }
        if ($secName -match '^HEAP$' -or $secName -match '^\.\bheap\b') {
            $heapSize = $sz; $heapAddr = $addr; $heapModule = $modName
        }
        continue
    }
    } # end if ($verbose) for section entries
    # Detect removed HEAP/STACK sections: "Removing xxx.o(HEAP), (512 bytes)."
    if ($line -match 'Removing\s+(\S+)\(HEAP\).*\((\d+)\s+bytes\)') {
        $heapRemoved = $true
        $heapSize = [uint64]$Matches[2]
        $heapModule = $Matches[1]
        continue
    }
    if ($line -match 'Removing\s+(\S+)\(STACK\).*\((\d+)\s+bytes\)') {
        $stackRemoved = $true
        $stackSize = [uint64]$Matches[2]
        $stackModule = $Matches[1]
        continue
    }
    # Track all removed sections for summary (verbose only)
    if ($verbose -and $line -match 'Removing\s+(\S+)\((\S+)\).*\((\d+)\s+bytes\)') {
        [void]$removedSections.Add(@{Mod=$Matches[1];Sec=$Matches[2];Sz=[uint64]$Matches[3]})
    }
    # __initial_sp symbol
    if ($line -match '__initial_sp\s+(0x[0-9a-fA-F]+)') {
        $initialSP = [Convert]::ToUInt64($Matches[1],16)
    }
    # Image component sizes (verbose only - used by sections 5, 6, 11, 12 warnings)
    if ($verbose) {
    if ($line -match 'Image component sizes') { $inComponentSizes = $true; continue }
    # Object files (.o)
    if ($inComponentSizes -and $line -match '^\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+\.o)\s*$') {
        $o=@{C=[int]$Matches[1];I=[int]$Matches[2];RO=[int]$Matches[3];RW=[int]$Matches[4];ZI=[int]$Matches[5];D=[int]$Matches[6];N=$Matches[7].Trim()}
        $o.ROM=$o.C+$o.RO+$o.RW; $o.RAM=$o.RW+$o.ZI
        [void]$CD.Add($o);continue
    }
    # Library lines
    if ($inComponentSizes -and $line -match '^\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s*$') {
        $name = $Matches[7].Trim()
        if ($name -match '\.o$' -or $name -eq 'Totals' -or $name -match 'Grand') { continue }
        if ($name -match '\.\w+$' -and $name -notmatch '\.o$') {
            $o = [ordered]@{
                C=[int]$Matches[1]; I=[int]$Matches[2]; RO=[int]$Matches[3]; RW=[int]$Matches[4]
                ZI=[int]$Matches[5]; D=[int]$Matches[6]; N=$name
                ROM=([int]$Matches[1]+[int]$Matches[3]+[int]$Matches[4])
                RAM=([int]$Matches[4]+[int]$Matches[5])
            }
            [void]$LD.Add($o)
        }
        continue
    }
    } # end if ($verbose) for component sizes
}

if ($gWFlash -eq 0) { $gWFlash = $gW }  # fallback if ROM Totals not found
$tROM = $gC + $gR + $gWFlash
$tRAM = $gW + $gZ
$rwCompressed = ($gWFlash -lt $gW)

function Is-RAM($er) {
    if ($er.N -match 'RAM|IRAM|SRAM|DTCM|ITCM') { return $true }
    if ($er.B -ge 0x20000000) { return $true }
    return $false
}

# Find RAM region max for stack/heap analysis
$ramMax = 0; $ramUsed = 0; $ramBase = 0
foreach ($e in $ER) {
    if (Is-RAM $e) { $ramMax += $e.M; $ramUsed += $e.S; if ($ramBase -eq 0) { $ramBase = $e.B } }
}


# ==================== OUTPUT ====================

Write-Header "KEIL MAP FILE ANALYSIS REPORT"
Write-Host "  File : $mapFile" -Fore White
Write-Host "  Time : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Fore White

# 1. Overview (always shown)
Write-Header "1. MEMORY USAGE OVERVIEW"
Write-Host ""
Write-Host "  +------------------------+----------------+--------------+" -Fore White
Write-Host "  |       Component        |     Bytes      |    Human     |" -Fore White
Write-Host "  +------------------------+----------------+--------------+" -Fore White
$fm = "  | {0,-22} | {1,14} | {2,12} |"
Write-Host ($fm -f "Code (program)",$gC,(FS $gC)) -Fore White
Write-Host ($fm -f "RO-data (const)",$gR,(FS $gR)) -Fore White
Write-Host ($fm -f "RW-data (init var)",$gW,(FS $gW)) -Fore White
Write-Host ($fm -f "ZI-data (bss/stk)",$gZ,(FS $gZ)) -Fore White
Write-Host "  +------------------------+----------------+--------------+" -Fore Yellow
Write-Host ($fm -f "ROM (Flash) Total",$tROM,(FS $tROM)) -Fore Yellow
Write-Host ($fm -f "RAM Total",$tRAM,(FS $tRAM)) -Fore Yellow
Write-Host "  +------------------------+----------------+--------------+" -Fore White
Write-Host ""
if ($rwCompressed) {
    Write-Host "  ROM = Code+RO+RW(compressed) = $gC + $gR + $gWFlash = $tROM ($(FS $tROM))" -Fore Cyan
    Write-Host "  Note: RW-data $gW bytes compressed to $gWFlash bytes in flash" -Fore DarkGray
} else {
    Write-Host "  ROM = Code+RO+RW = $gC + $gR + $gWFlash = $tROM ($(FS $tROM))" -Fore Cyan
}
Write-Host "  RAM = RW+ZI      = $gW + $gZ = $tRAM ($(FS $tRAM))" -Fore Cyan

# Always build $romE/$ramE (needed by Section 13)
$romE = [System.Collections.ArrayList]::new()
$ramE = [System.Collections.ArrayList]::new()
foreach ($e in $ER) {
    if (Is-RAM $e) { [void]$ramE.Add($e) } else { [void]$romE.Add($e) }
}

# Stack/Heap derived values (needed by sections 4 and 13)
$actualStack = if ($stackRemoved -or $stackSize -eq 0) { 0 } else { $stackSize }
$actualHeap = if ($heapRemoved -or $heapSize -eq 0) { 0 } else { $heapSize }

if ($verbose) {

# 2. Load Regions
if ($LR.Count -gt 0) {
    Write-Header "2. LOAD REGIONS"
    foreach ($r in $LR) {
        $p = if ($r.M -gt 0) { [math]::Round($r.S/$r.M*100,1) } else { 0 }
        Write-Host ""
        Write-Host "  [$($r.N)]" -Fore Yellow
        Write-Host ("    Base: 0x{0:X8}  Used: {1}  Max: {2}  ({3}%)" -f $r.B,(FS $r.S),(FS $r.M),$p) -Fore White
        WB $r.N $r.S $r.M 35 $(if($p -gt 90){'Red'}elseif($p -gt 70){'Yellow'}else{'Green'})
    }
}

# 3. Execution Regions (table only; $romE/$ramE already built above)
if ($ER.Count -gt 0) {
    Write-Header "3. EXECUTION REGIONS"
    if ($romE.Count -gt 0) {
        Write-Sub "FLASH/ROM Regions"
        Write-Host ""
        $hdr = "  {0,-20} {1,-12} {2,-14} {3,-14} {4,-8}" -f "Region","Base","Used","Max","Usage"
        Write-Host $hdr -Fore Cyan
        Write-Host ("  " + ("-"*70)) -Fore DarkGray
        foreach ($e in $romE) {
            $p = if ($e.M -gt 0) { [math]::Round($e.S/$e.M*100,1) } else { 0 }
            $c = if ($p -gt 90) {'Red'} elseif ($p -gt 70) {'Yellow'} else {'White'}
            $row = "  {0,-20} 0x{1:X8} {2,-14} {3,-14} {4}%" -f $e.N,$e.B,(FS $e.S),(FS $e.M),$p
            Write-Host $row -Fore $c
        }
    }
    if ($ramE.Count -gt 0) {
        Write-Sub "RAM Regions"
        Write-Host ""
        $hdr = "  {0,-20} {1,-12} {2,-14} {3,-14} {4,-8}" -f "Region","Base","Used","Max","Usage"
        Write-Host $hdr -Fore Cyan
        Write-Host ("  " + ("-"*70)) -Fore DarkGray
        foreach ($e in $ramE) {
            $p = if ($e.M -gt 0) { [math]::Round($e.S/$e.M*100,1) } else { 0 }
            $c = if ($p -gt 90) {'Red'} elseif ($p -gt 70) {'Yellow'} else {'White'}
            $row = "  {0,-20} 0x{1:X8} {2,-14} {3,-14} {4}%" -f $e.N,$e.B,(FS $e.S),(FS $e.M),$p
            Write-Host $row -Fore $c
        }
    }
}


# ===== NEW: 4. Stack & Heap Analysis =====
Write-Header "4. STACK & HEAP ANALYSIS"
Write-Host ""

# Stack info
if ($stackSize -gt 0) {
    Write-Host "  [STACK]" -Fore Yellow
    if ($stackRemoved) {
        Write-Host "    Status   : REMOVED (unused)" -Fore DarkGray
        Write-Host "    Defined  : $(FS $stackSize) (in $stackModule)" -Fore DarkGray
    } else {
        Write-Host "    Size     : $(FS $stackSize)" -Fore White
        if ($stackAddr -gt 0) {
            $stackEnd = $stackAddr + $stackSize
            Write-Host ("    Address  : 0x{0:X8} - 0x{1:X8}" -f $stackAddr, $stackEnd) -Fore White
        }
        Write-Host "    Module   : $stackModule" -Fore White
        if ($initialSP -gt 0) {
            Write-Host ("    __initial_sp = 0x{0:X8} (top of stack)" -f $initialSP) -Fore White
        }
        # Stack usage in RAM
        if ($tRAM -gt 0) {
            $stkPct = [math]::Round($stackSize/$tRAM*100,1)
            Write-Host "    RAM usage: $stkPct% of total RAM" -Fore $(if($stkPct -gt 50){'Yellow'}else{'White'})
            WB "Stack in RAM" $stackSize $tRAM 30 $(if($stkPct -gt 50){'Yellow'}else{'Cyan'})
        }
    }
} else {
    Write-Host "  [STACK] Not found in map file" -Fore DarkGray
}

Write-Host ""

# Heap info
if ($heapSize -gt 0) {
    Write-Host "  [HEAP]" -Fore Yellow
    if ($heapRemoved) {
        Write-Host "    Status   : REMOVED by linker (unused)" -Fore DarkGray
        Write-Host "    Defined  : $(FS $heapSize) (in $heapModule)" -Fore DarkGray
        Write-Host "    Note     : No dynamic memory allocation (malloc/free) used" -Fore DarkGray
    } else {
        Write-Host "    Size     : $(FS $heapSize)" -Fore White
        if ($heapAddr -gt 0) {
            $heapEnd = $heapAddr + $heapSize
            Write-Host ("    Address  : 0x{0:X8} - 0x{1:X8}" -f $heapAddr, $heapEnd) -Fore White
        }
        Write-Host "    Module   : $heapModule" -Fore White
        if ($tRAM -gt 0) {
            $hpPct = [math]::Round($heapSize/$tRAM*100,1)
            Write-Host "    RAM usage: $hpPct% of total RAM" -Fore $(if($hpPct -gt 30){'Yellow'}else{'White'})
            WB "Heap in RAM" $heapSize $tRAM 30 $(if($hpPct -gt 30){'Yellow'}else{'Cyan'})
        }
    }
} else {
    Write-Host "  [HEAP] Not found (size=0 or not defined)" -Fore DarkGray
}

Write-Host ""


# RAM breakdown with stack/heap
Write-Host "  [RAM DETAILED BREAKDOWN]" -Fore Yellow
Write-Host ""
$rwData = $gW
$bssData = $gZ
$bssOther = $bssData - $actualStack - $actualHeap
if ($bssOther -lt 0) { $bssOther = 0 }

Write-Host "  +----------------------------+----------+---------+" -Fore White
Write-Host "  |        RAM Section         |   Bytes  |  Human  |" -Fore White
Write-Host "  +----------------------------+----------+---------+" -Fore White
$rfm = "  | {0,-26} | {1,8} | {2,7} |"
Write-Host ($rfm -f "RW-data (init globals)",$rwData,(FS $rwData)) -Fore White
Write-Host ($rfm -f "ZI-data (bss globals)",$bssOther,(FS $bssOther)) -Fore White
Write-Host ($rfm -f "Stack",$actualStack,(FS $actualStack)) -Fore $(if($actualStack -gt 0){'Yellow'}else{'DarkGray'})
Write-Host ($rfm -f "Heap",$actualHeap,(FS $actualHeap)) -Fore $(if($actualHeap -gt 0){'Yellow'}else{'DarkGray'})
Write-Host "  +----------------------------+----------+---------+" -Fore Yellow
Write-Host ($rfm -f "Total RAM",$tRAM,(FS $tRAM)) -Fore Yellow
Write-Host "  +----------------------------+----------+---------+" -Fore White

Write-Host ""
Write-Host "  RAM Composition:" -Fore Yellow
if ($tRAM -gt 0) {
    WB "RW-data (init globals)" $rwData $tRAM 30 "Green"
    WB "ZI-data (bss globals)" $bssOther $tRAM 30 "White"
    WB "Stack" $actualStack $tRAM 30 "Yellow"
    WB "Heap" $actualHeap $tRAM 30 "Magenta"
}

# Free RAM calculation
if ($ramMax -gt 0) {
    $freeRAM = $ramMax - $ramUsed
    Write-Host ""
    Write-Host "  RAM Free Space:" -Fore Yellow
    WB "Used" $ramUsed $ramMax 30 $(if($ramUsed/$ramMax -gt 0.9){'Red'}elseif($ramUsed/$ramMax -gt 0.7){'Yellow'}else{'Green'})
    WB "Free" $freeRAM $ramMax 30 "DarkGray"
    Write-Host ""
    Write-Host ("    Total RAM: {0}  Used: {1}  Free: {2} ({3}%)" -f (FS $ramMax),(FS $ramUsed),(FS $freeRAM),([math]::Round($freeRAM/$ramMax*100,1))) -Fore Cyan
}

# Stack overflow risk
Write-Host ""
if ($actualStack -gt 0 -and $ramMax -gt 0) {
    $freeRAM = $ramMax - $ramUsed
    Write-Host "  [STACK SAFETY CHECK]" -Fore Yellow
    if ($actualStack -lt 256) {
        Write-Host "    [!!!] Stack is very small ($actualStack bytes) - HIGH overflow risk!" -Fore Red
    } elseif ($actualStack -lt 512) {
        Write-Host "    [!!] Stack is small ($actualStack bytes) - monitor carefully" -Fore Yellow
    } elseif ($actualStack -lt 1024) {
        Write-Host "    [!] Stack is $(FS $actualStack) - adequate for simple apps" -Fore White
    } else {
        Write-Host "    [OK] Stack is $(FS $actualStack) - good size" -Fore Green
    }
    if ($freeRAM -lt $actualStack) {
        Write-Host "    [!!] Free RAM ($freeRAM B) < Stack ($actualStack B) - very tight!" -Fore Red
    }
    Write-Host ""
    Write-Host ("    Tip: Stack grows downward from 0x{0:X8}" -f $initialSP) -Fore DarkGray
    Write-Host "    Tip: Use HardFault handler + stack canary to detect overflow" -Fore DarkGray
}


# 5. Module Ranking
if ($CD.Count -gt 0) {
    Write-Header "5. MODULE SIZE RANKING (Top 25)"

    Write-Sub "By ROM (Flash) Usage"
    Write-Host ""
    $hdr = "  {0,-4} {1,-40} {2,8} {3,8} {4,8} {5,10}" -f "#","Module","Code","RO","RW","ROM"
    Write-Host $hdr -Fore Cyan
    Write-Host ("  " + ("-"*84)) -Fore DarkGray
    $rk = 1
    foreach ($c in ($CD | Sort-Object {$_.ROM} -Descending | Select-Object -First 25)) {
        $n = if ($c.N.Length -gt 40) { $c.N.Substring(0,37)+"..." } else { $c.N }
        $cl = if ($rk -le 3) {'Yellow'} elseif ($rk -le 10) {'White'} else {'Gray'}
        $row = "  {0,-4} {1,-40} {2,8} {3,8} {4,8} {5,10}" -f $rk,$n,$c.C,$c.RO,$c.RW,$c.ROM
        Write-Host $row -Fore $cl
        $rk++
    }

    Write-Sub "By RAM Usage"
    Write-Host ""
    $hdr = "  {0,-4} {1,-40} {2,8} {3,8} {4,10}" -f "#","Module","RW","ZI","RAM"
    Write-Host $hdr -Fore Cyan
    Write-Host ("  " + ("-"*74)) -Fore DarkGray
    $rk = 1
    foreach ($c in ($CD | Where-Object {$_.RAM -gt 0} | Sort-Object {$_.RAM} -Descending | Select-Object -First 25)) {
        $n = if ($c.N.Length -gt 40) { $c.N.Substring(0,37)+"..." } else { $c.N }
        $cl = if ($rk -le 3) {'Yellow'} elseif ($rk -le 10) {'White'} else {'Gray'}
        $row = "  {0,-4} {1,-40} {2,8} {3,8} {4,10}" -f $rk,$n,$c.RW,$c.ZI,$c.RAM
        Write-Host $row -Fore $cl
        $rk++
    }
}

# 6. Library Summary
if ($LD.Count -gt 0) {
    Write-Header "6. LIBRARY SUMMARY"
    Write-Host ""
    $hdr = "  {0,-35} {1,8} {2,8} {3,8} {4,8} {5,10} {6,10}" -f "Library","Code","RO","RW","ZI","ROM","RAM"
    Write-Host $hdr -Fore Cyan
    Write-Host ("  " + ("-"*93)) -Fore DarkGray
    foreach ($l in ($LD | Sort-Object {$_.ROM} -Descending)) {
        $n = if ($l.N.Length -gt 35) { $l.N.Substring(0,32)+"..." } else { $l.N }
        $row = "  {0,-35} {1,8} {2,8} {3,8} {4,8} {5,10} {6,10}" -f $n,$l.C,$l.RO,$l.RW,$l.ZI,$l.ROM,$l.RAM
        Write-Host $row -Fore White
    }
    $lROM = 0; $lRAM = 0
    foreach ($l in $LD) { $lROM += $l.ROM; $lRAM += $l.RAM }
    Write-Host ""
    Write-Host "  Lib ROM: $(FS $lROM)  |  Lib RAM: $(FS $lRAM)" -Fore Cyan
}


# 7. Section Analysis
if ($SD.Count -gt 0) {
    Write-Header "7. SECTION TYPE ANALYSIS"
    Write-Sub "By Section Name (Top 30)"
    Write-Host ""
    $hdr = "  {0,-28} {1,6} {2,14}" -f "Section","Count","Total"
    Write-Host $hdr -Fore Cyan
    Write-Host ("  " + ("-"*52)) -Fore DarkGray
    $sg = $SD | Group-Object {$_.SE}
    foreach ($g in ($sg | Sort-Object {($_.Group|Measure-Object -Property Z -Sum).Sum} -Descending | Select-Object -First 30)) {
        $s = ($g.Group | Measure-Object -Property Z -Sum).Sum
        $row = "  {0,-28} {1,6} {2,14}" -f $g.Name,$g.Count,(FS $s)
        Write-Host $row -Fore White
    }
    Write-Sub "By Type"
    Write-Host ""
    $tg = $SD | Group-Object {$_.T}
    foreach ($g in ($tg | Sort-Object {($_.Group|Measure-Object -Property Z -Sum).Sum} -Descending)) {
        $s = ($g.Group | Measure-Object -Property Z -Sum).Sum
        $row = "  {0,-8} : {1,6} items, {2}" -f $g.Name,$g.Count,(FS $s)
        Write-Host $row -Fore White
    }
}

# 8. Per-Region Breakdown
if ($ER.Count -gt 0) {
    Write-Header "8. PER-REGION SECTION BREAKDOWN"
    foreach ($er in $ER) {
        if ($er.SC.Count -eq 0) { continue }
        Write-Sub ("{0} (0x{1:X8}, {2})" -f $er.N,$er.B,(FS $er.S))
        Write-Host ""
        $sg = $er.SC | Group-Object {$_.SE}
        $hdr = "    {0,-24} {1,6} {2,14}" -f "Section","Count","Size"
        Write-Host $hdr -Fore Cyan
        Write-Host ("    " + ("-"*48)) -Fore DarkGray
        foreach ($g in ($sg | Sort-Object {($_.Group|Measure-Object -Property Z -Sum).Sum} -Descending)) {
            $s = ($g.Group | Measure-Object -Property Z -Sum).Sum
            $row = "    {0,-24} {1,6} {2,14}" -f $g.Name,$g.Count,(FS $s)
            Write-Host $row -Fore White
        }
    }
}


# 9. Visual Map
Write-Header "9. VISUAL MEMORY MAP"
Write-Host ""
$romE2 = [System.Collections.ArrayList]::new()
$ramE2 = [System.Collections.ArrayList]::new()
foreach ($e in $ER) {
    if (Is-RAM $e) { [void]$ramE2.Add($e) } else { [void]$romE2.Add($e) }
}
if ($romE2.Count -gt 0) {
    Write-Host "  FLASH/ROM:" -Fore Yellow
    Write-Host "  +----------------------------------------------------------+" -Fore DarkGray
    foreach ($e in $romE2) {
        $p = if ($e.M -gt 0) { [math]::Round($e.S/$e.M*100,1) } else { 0 }
        $bw=35; $fi=[int][math]::Min($bw,[math]::Max(0,[math]::Round($p/100*$bw))); $em=$bw-$fi
        $bc = if ($p -gt 90) {'Red'} elseif ($p -gt 70) {'Yellow'} else {'Green'}
        Write-Host ("  | {0,-14} [" -f $e.N) -Fore DarkGray -NoNewline
        Write-Host ("#"*$fi) -Fore $bc -NoNewline
        Write-Host ("-"*$em) -Fore DarkGray -NoNewline
        Write-Host ("] {0,5}% |" -f $p) -Fore DarkGray
    }
    Write-Host "  +----------------------------------------------------------+" -Fore DarkGray
}
if ($ramE2.Count -gt 0) {
    Write-Host ""
    Write-Host "  RAM:" -Fore Yellow
    Write-Host "  +----------------------------------------------------------+" -Fore DarkGray
    foreach ($e in $ramE2) {
        $p = if ($e.M -gt 0) { [math]::Round($e.S/$e.M*100,1) } else { 0 }
        $bw=35; $fi=[int][math]::Min($bw,[math]::Max(0,[math]::Round($p/100*$bw))); $em=$bw-$fi
        $bc = if ($p -gt 90) {'Red'} elseif ($p -gt 70) {'Yellow'} else {'Green'}
        Write-Host ("  | {0,-14} [" -f $e.N) -Fore DarkGray -NoNewline
        Write-Host ("#"*$fi) -Fore $bc -NoNewline
        Write-Host ("-"*$em) -Fore DarkGray -NoNewline
        Write-Host ("] {0,5}% |" -f $p) -Fore DarkGray
    }
    Write-Host "  +----------------------------------------------------------+" -Fore DarkGray
}

# 10. ROM Composition
Write-Header "10. ROM COMPOSITION"
Write-Host ""
Write-Host "  ROM (Flash):" -Fore Yellow
if ($tROM -gt 0) {
    WB "Code (program)" $gC $tROM 30 "Cyan"
    WB "RO-data (const)" $gR $tROM 30 "Green"
    WB "RW-data (init vars)" $gW $tROM 30 "Yellow"
}

# 11. User vs Lib
if ($LD.Count -gt 0 -and $tROM -gt 0) {
    Write-Header "11. USER CODE vs LIBRARY"
    $lROM = 0; foreach ($l in $LD) { $lROM += $l.ROM }
    $uROM = $tROM - $lROM
    Write-Host ""
    Write-Host "  ROM:" -Fore Yellow
    WB "User" $uROM $tROM 30 "Cyan"
    WB "Library" $lROM $tROM 30 "DarkCyan"
}

} # end if ($verbose)


# 12. Warnings (always shown)
Write-Header "12. WARNINGS"
$wc = 0
foreach ($c in ($CD | Sort-Object {$_.ROM} -Descending | Select-Object -First 5)) {
    if ($c.ROM -gt 10240) { Write-Host "  [!] $($c.N) => $(FS $c.ROM) ROM" -Fore Yellow; $wc++ }
}
foreach ($c in ($CD | Sort-Object {$_.RAM} -Descending | Select-Object -First 5)) {
    if ($c.RAM -gt 4096) { Write-Host "  [!] $($c.N) => $(FS $c.RAM) RAM" -Fore Yellow; $wc++ }
}
foreach ($e in $ER) {
    if ($e.M -gt 0) {
        $p = $e.S/$e.M*100
        if ($p -gt 95) { Write-Host "  [!!!] $($e.N) $([math]::Round($p,1))% CRITICAL!" -Fore Red; $wc++ }
        elseif ($p -gt 85) { Write-Host "  [!!] $($e.N) $([math]::Round($p,1))% WARNING" -Fore Yellow; $wc++ }
    }
}
if ($actualStack -gt 0 -and $actualStack -lt 512) {
    Write-Host "  [!!] Stack only $(FS $actualStack) - risk of overflow!" -Fore Yellow; $wc++
}
if ($heapRemoved) {
    Write-Host "  [i] Heap removed by linker (no malloc/free used)" -Fore DarkGray
}
if ($wc -eq 0) { Write-Host "  [OK] Memory usage looks healthy!" -Fore Green }

# 13. Vertical Address Allocation Map (always shown)
Write-Header "13. VERTICAL ADDRESS ALLOCATION MAP"
Write-Host ""

$VH  = 40    # visual height budget (rows)
$IW  = 22    # inner box content width
$AW  = 10    # address label width ("0xXXXXXXXX")
$GAP = "     " # gap between columns

function vPad([string]$s, [int]$w) {
    if ($s.Length -gt $w) { $s = $s.Substring(0, [math]::Max(1, $w-1)) + "~" }
    $l = [int](($w - $s.Length) / 2); $r = $w - $s.Length - $l
    return (" " * $l) + $s + (" " * $r)
}


# Build a column as list of @{Addr; Line; Color}
# segs: [{N, Sz, Color}] sorted LOW to HIGH address
function vBuild([uint64]$base, [uint64]$cap, $segs) {
    $out   = [System.Collections.ArrayList]::new()
    $bline = "+{0}+" -f ("-" * $IW)
    $blank = "|{0}|" -f (" " * $IW)

    $usedSz = [uint64]0
    foreach ($s in $segs) { $usedSz += [uint64]$s.Sz }
    $freeSz = if ($cap -gt $usedSz) { $cap - $usedSz } else { [uint64]0 }

    # Order from HIGH to LOW: free at top, then segments reversed
    $all = [System.Collections.ArrayList]::new()
    if ($freeSz -gt 0) { [void]$all.Add(@{N="(free)"; Sz=$freeSz; Color="DarkGray"}) }
    for ($i = $segs.Count - 1; $i -ge 0; $i--) { [void]$all.Add($segs[$i]) }

    # Proportional heights (min 3 rows each)
    foreach ($seg in $all) {
        $seg.H = [int][math]::Max(3, [math]::Round([double]$seg.Sz / [double]$cap * $VH))
    }

    # Top border with high address
    [void]$out.Add(@{Addr=($base+$cap); Line=$bline; Color="Cyan"})
    $curAddr = $base + $cap

    foreach ($seg in $all) {
        $curAddr -= [uint64]$seg.Sz
        $mid = [int]($seg.H / 2)
        for ($row = 0; $row -lt $seg.H; $row++) {
            if ($row -eq $mid) {
                [void]$out.Add(@{Addr=$null; Line=("|{0}|" -f (vPad $seg.N $IW)); Color=$seg.Color})
            } elseif ($row -eq ($mid+1) -and $seg.H -ge 5) {
                [void]$out.Add(@{Addr=$null; Line=("|{0}|" -f (vPad ("({0})" -f (FS $seg.Sz)) $IW)); Color="DarkGray"})
            } else {
                [void]$out.Add(@{Addr=$null; Line=$blank; Color="DarkGray"})
            }
        }
        [void]$out.Add(@{Addr=$curAddr; Line=$bline; Color="Cyan"})
    }
    return $out
}

function vFmt($e) {
    $a = if ($null -ne $e.Addr) { "0x{0:X8}" -f $e.Addr } else { " " * $AW }
    return "{0} {1}" -f $a, $e.Line
}


# Pick the largest ROM and RAM execution region
# Use $romE/$ramE (built before verbose block) to avoid the $er/$ER case-insensitive name collision
# that occurs in section 8's foreach ($er in $ER) which overwrites $ER.
$pROM = $null; $pRAM = $null
foreach ($e2 in $romE) { if ($null -eq $pROM -or $e2.M -gt $pROM.M) { $pROM = $e2 } }
foreach ($e2 in $ramE) { if ($null -eq $pRAM -or $e2.M -gt $pRAM.M) { $pRAM = $e2 } }

$romCol = @(); $ramCol = @()

if ($null -ne $pROM -and $pROM.M -gt 0) {
    # Use Grand Totals for consistent sizes with the overview table.
    # Note: addresses are logical boundaries, not physical section boundaries,
    # because RO-data sections (e.g. RESET vectors) can be interleaved with Code in flash.
    $codeSize2 = [uint64]$gC
    $roSize2   = [uint64]$gR

    # RW-init: actual flash footprint from ROM Totals (compressed if applicable)
    $rwSize2 = [uint64]$gWFlash

    $rs = [System.Collections.ArrayList]::new()
    if ($codeSize2 -gt 0) { [void]$rs.Add(@{N="Code";    Sz=$codeSize2; Color="Cyan"}) }
    if ($roSize2   -gt 0) { [void]$rs.Add(@{N="RO-data"; Sz=$roSize2;   Color="Green"}) }
    $rwLabel = if ($rwCompressed) { "RW-init(C)" } else { "RW-init" }
    if ($rwSize2   -gt 0) { [void]$rs.Add(@{N=$rwLabel; Sz=$rwSize2;   Color="Yellow"}) }
    $romCol = @(vBuild $pROM.B $pROM.M $rs)
}

if ($null -ne $pRAM -and $pRAM.M -gt 0) {
    $rs = [System.Collections.ArrayList]::new()
    if ($gW -gt 0) { [void]$rs.Add(@{N="RW-data"; Sz=[uint64]$gW; Color="Yellow"}) }
    $bssOnly2 = [uint64]([math]::Max(0, [int64]$gZ - [int64]$actualStack - [int64]$actualHeap))
    if ($bssOnly2 -gt 0) { [void]$rs.Add(@{N="ZI/BSS"; Sz=$bssOnly2; Color="White"}) }
    if ($actualHeap  -gt 0) { [void]$rs.Add(@{N="Heap";  Sz=[uint64]$actualHeap;  Color="Magenta"}) }
    if ($actualStack -gt 0) { [void]$rs.Add(@{N="Stack"; Sz=[uint64]$actualStack; Color="Red"}) }
    $ramCol = @(vBuild $pRAM.B $pRAM.M $rs)
}


# Column total width: AW + 1 space + 1(+) + IW + 1(+) = AW+IW+3
$colW  = $AW + $IW + 3   # e.g. 10+22+3=35
$fullW = $colW + 2        # "  " prefix => 37

$romTitle = if ($null -ne $pROM) { "  FLASH  [base:0x{0:X8}  cap:{1}]" -f $pROM.B,(FS $pROM.M) } else { "" }
$ramTitle  = if ($null -ne $pRAM) { "RAM  [base:0x{0:X8}  cap:{1}]"    -f $pRAM.B,(FS $pRAM.M) } else { "" }
Write-Host ("{0,-$fullW}{1}{2}" -f $romTitle,$GAP,$ramTitle) -Fore Yellow
Write-Host ""

# Color legend
Write-Host "  Legend: " -Fore White -NoNewline
Write-Host "[Code]"    -Fore Cyan    -NoNewline
Write-Host " "         -NoNewline
Write-Host "[RO-data]" -Fore Green   -NoNewline
Write-Host " "         -NoNewline
Write-Host "[RW-init/data]" -Fore Yellow  -NoNewline
Write-Host " "         -NoNewline
Write-Host "[ZI/BSS]"  -Fore White   -NoNewline
Write-Host " "         -NoNewline
Write-Host "[Stack]"   -Fore Red     -NoNewline
Write-Host " "         -NoNewline
Write-Host "[Heap]"    -Fore Magenta -NoNewline
Write-Host " "         -NoNewline
Write-Host "[(free)]"  -Fore DarkGray
Write-Host ""

$nRows = [math]::Max($romCol.Count, $ramCol.Count)
for ($i = 0; $i -lt $nRows; $i++) {
    $lE = if ($i -lt $romCol.Count) { $romCol[$i] } else { $null }
    $rE = if ($i -lt $ramCol.Count) { $ramCol[$i] } else { $null }
    $lStr = if ($null -ne $lE) { "  " + (vFmt $lE) } else { " " * $fullW }
    $rStr = if ($null -ne $rE) { vFmt $rE } else { "" }
    $lStr = $lStr.PadRight($fullW)
    $lC = if ($null -ne $lE) { $lE.Color } else { "DarkGray" }
    $rC = if ($null -ne $rE) { $rE.Color } else { "DarkGray" }
    Write-Host $lStr -Fore $lC -NoNewline
    Write-Host $GAP  -Fore DarkGray -NoNewline
    Write-Host $rStr -Fore $rC
}
Write-Host ""

Write-Host ""
Write-Host ("="*80) -Fore Cyan
Write-Host "  Analysis Complete!" -Fore Green
Write-Host ("="*80) -Fore Cyan
Write-Host ""
