#Requires -Version 5.1
<#
.SYNOPSIS
    构建 Qt 6.8 静态库（MSVC 2019 / v142 x64，可选 /MT 静态 CRT）。
    可在 GitHub Actions 的 windows-2022 运行器上跑，也可在本地 Windows 上直接跑。

.DESCRIPTION
    流程：解析 Qt 标签 -> 浅克隆 qt/qt5 超模块 -> init-repository 只拉需要的子模块
        -> configure.bat 静态配置 -> cmake --build -> cmake --install -> 校验产物。

.PARAMETER QtVersion
    Qt 版本号，默认 6.8.5。

.PARAMETER QtTag
    显式指定 qt/qt5 的标签，例如 v6.8.5-lts-lgpl。留空则自动探测。

.PARAMETER Modules
    要构建的模块子集。越少越省时间。默认不含 qtwebengine（静态构建极其昂贵）。

.PARAMETER SrcRoot
    qt5 超模块源码目录。

.PARAMETER BuildDir
    构建目录（建议与源码分开，且不要放在源码树内）。

.PARAMETER Prefix
    安装目录，最终产物位置。

.PARAMETER MsvcToolset
    vcvarsall 的 -vcvars_ver，14.29 即 MSVC 2019 (v142)。传空字符串则用默认工具集。

.PARAMETER Jobs
    并行编译任务数，0 表示取 CPU 核心数。

.PARAMETER StaticRuntime
    使用 /MT 静态运行时（Qt 的 -static-runtime）。必须与你的工程运行时一致。

.PARAMETER ReuseSource
    复用已存在的源码目录（不重新 clone/checkout），仅补拉缺失子模块。

.PARAMETER VerifyOnly
    只校验 $Prefix 下已有产物，不克隆也不编译（CI 命中缓存时使用）。

.PARAMETER Force
    init-repository 加 -f，强制重新同步子模块。

.PARAMETER ExtraConfigureArgs
    追加给 configure.bat 的额外参数，例如 -schannel、-no-feature-accessibility。

.EXAMPLE
    .\build-qt-static.ps1 -QtVersion 6.8.5 -StaticRuntime -Prefix C:\Qt\Qt-6.8.5-msvc2019-static

.EXAMPLE
    .\build-qt-static.ps1 -VerifyOnly -Prefix C:\Qt\Qt-6.8.5-msvc2019-static -StaticRuntime
#>
[CmdletBinding()]
param(
    [string]   $QtVersion   = '6.8.5',
    [string]   $QtTag       = '',
    [string[]] $Modules     = @('qtbase', 'qtdeclarative', 'qtsvg', 'qttools', 'qtshadertools', 'qtimageformats', 'qt5compat', 'qtlanguageserver'),
    [string]   $SrcRoot     = 'C:\Qt\src\qt5',
    [string]   $BuildDir    = 'C:\Qt\build',
    [string]   $Prefix      = "C:\Qt\Qt-$QtVersion-msvc2019-static",
    [string]   $MsvcToolset = '14.29',
    [int]      $Jobs        = 0,
    [switch]   $StaticRuntime,
    [switch]   $ReuseSource,
    [switch]   $VerifyOnly,
    [switch]   $Force,
    [string[]] $ExtraConfigureArgs = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Timer = [System.Diagnostics.Stopwatch]::StartNew()

function Write-Step {
    param([string]$Message)
    $ts = $script:Timer.Elapsed.ToString('hh\:mm\:ss')
    Write-Host ''
    Write-Host "[$ts] === $Message ===" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "      $Message" -ForegroundColor DarkGray
}

function Invoke-Native {
    <# 运行外部命令，非 0 退出码直接抛异常，避免“静默失败” #>
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]] $Arguments = @(),
        [string]   $FailMessage
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        $msg = $FailMessage
        if (-not $msg) { $msg = "命令执行失败（退出码 $LASTEXITCODE）：$FilePath $($Arguments -join ' ')" }
        throw $msg
    }
}

function New-TempBatch {
    <# 把命令写进临时 .cmd 再执行，绕开 PowerShell 与 cmd 之间的引号地狱 #>
    param([string[]]$Lines)
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("qtstatic-" + [guid]::NewGuid().ToString('N') + ".cmd")
    Set-Content -Path $path -Value (@('@echo off') + $Lines) -Encoding ASCII
    return $path
}

function Import-MsvcEnvironment {
    <# 未处于 MSVC 环境时，用 vswhere + vcvarsall 初始化（并强制指定工具集） #>
    param([string]$Toolset)

    if ($env:VSCMD_VER -and (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        Write-Info "已处于 MSVC 环境，VSCMD_VER=$env:VSCMD_VER，跳过初始化"
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "找不到 vswhere.exe（$vswhere）。请先安装 Visual Studio 2019 生成工具或 VS2022 + v142 工具集。"
    }

    $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1
    if (-not $vsPath) { throw '找不到包含 C++ 桌面工具集的 Visual Studio 安装。' }

    $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path $vcvars)) { throw "找不到 vcvarsall.bat：$vcvars" }

    $archArg = 'x64'
    if ($Toolset) { $archArg += " -vcvars_ver=$Toolset" }

    Write-Info "初始化 MSVC 环境：$vsPath（$archArg）"

    $bat = New-TempBatch @(
        "call `"$vcvars`" $archArg >nul 2>&1",
        'set'
    )
    try {
        $envLines = & cmd.exe /c $bat
    }
    finally {
        Remove-Item $bat -Force -ErrorAction SilentlyContinue
    }

    foreach ($line in $envLines) {
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            Set-Item -Path ("env:" + $matches[1]) -Value $matches[2]
        }
    }

    if (-not $env:VSCMD_VER) { throw 'vcvarsall.bat 执行失败，MSVC 环境未初始化。' }
}

function Assert-Compiler {
    <# 校验 cl.exe 版本，确保真的是 MSVC 2019 (19.29.x) 而不是被 vs2022 覆盖 #>
    param([string]$Toolset)

    $clPath = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
    if (-not $clPath) { throw 'PATH 中找不到 cl.exe，MSVC 环境不可用。' }

    $banner = (& cmd.exe /c "cl 2>&1") | Out-String
    if ($banner -match '(\d+\.\d+\.\d+\.\d+)') {
        $clVersion = $matches[1]
    }
    else {
        throw "无法解析 cl.exe 版本号：$banner"
    }

    Write-Info "编译器：$clPath"
    Write-Info "cl 版本：$clVersion"

    $majorMinor = ($clVersion -split '\.')[0..1] -join '.'
    if ($Toolset -eq '14.29' -and $majorMinor -ne '19.29') {
        throw "要求 MSVC 2019（cl 19.29.x / v142），实际拿到 cl $clVersion。请安装 VS2019 生成工具或 v142 组件。"
    }
}

function Resolve-QtTag {
    param([string]$Version, [string]$Explicit)
    if ($Explicit) { return $Explicit }

    $candidates = @("v$Version", "v$Version-lts-lgpl", "v$Version-lts")
    foreach ($cand in $candidates) {
        & git ls-remote --exit-code --tags https://github.com/qt/qt5.git "refs/tags/$cand" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "匹配到 Qt 标签：$cand"
            return $cand
        }
    }
    throw "qt/qt5 中找不到 Qt $Version 的标签（尝试过：$($candidates -join ', ')）。请用 -QtTag 显式指定。"
}

function Get-QtSource {
    param([string]$Tag)

    $parent = Split-Path -Parent $SrcRoot
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    if (Test-Path (Join-Path $SrcRoot '.git')) {
        $current = (& git -C $SrcRoot describe --tags --exact-match 2>$null) | Select-Object -First 1
        if ($ReuseSource -and $current -eq $Tag) {
            Write-Info "源码已位于 $Tag，直接复用"
        }
        else {
            & git -C $SrcRoot rev-parse --verify --quiet "refs/tags/$Tag" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Invoke-Native -FilePath 'git' -Arguments @('-C', $SrcRoot, 'fetch', '--depth', '1', '--tags', 'origin', $Tag) -FailMessage "拉取标签 $Tag 失败"
            }
            Invoke-Native -FilePath 'git' -Arguments @('-C', $SrcRoot, 'checkout', '-q', '-f', $Tag) -FailMessage "切换到 $Tag 失败"
        }
    }
    else {
        if (Test-Path $SrcRoot) {
            if ((Get-ChildItem $SrcRoot -Force | Measure-Object).Count -gt 0) {
                throw "$SrcRoot 已存在且不是 qt5 仓库，请先手动清理或换一个 -SrcRoot。"
            }
        }
        Invoke-Native -FilePath 'git' -Arguments @('clone', '--depth', '1', '--branch', $Tag, '--recurse-submodules=no', 'https://github.com/qt/qt5.git', $SrcRoot) -FailMessage '克隆 qt/qt5 失败'
    }

    if (-not (Get-Command perl -ErrorAction SilentlyContinue)) {
        throw 'PATH 中找不到 perl。请安装 Strawberry Perl，或把 Git for Windows 的 perl 加入 PATH。'
    }

    Write-Info "init-repository 子模块子集：$($Modules -join ', ')"
    Push-Location $SrcRoot
    try {
        $initArgs = @("--module-subset=$($Modules -join ',')")
        if ($Force) { $initArgs += '-f' }
        Invoke-Native -FilePath 'perl' -Arguments (@('init-repository') + $initArgs) -FailMessage 'init-repository 失败'
    }
    finally {
        Pop-Location
    }
}

function Invoke-QtConfigure {
    $configureBat = Join-Path $SrcRoot 'configure.bat'
    if (-not (Test-Path $configureBat)) { throw "找不到 configure.bat：$configureBat" }

    if (-not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null }

    # 运行器镜像里 C:\vcpkg 常带 VCPKG_INSTALLATION_ROOT，会让 Qt 去捡 vcpkg 的动态库，破坏静态一致性
    Remove-Item Env:VCPKG_INSTALLATION_ROOT -ErrorAction SilentlyContinue

    $cfgArgs = @(
        '-static'
        '-release'
        '-prefix', "`"$Prefix`""
        '-opensource'
        '-confirm-license'
        '-nomake', 'examples'
        '-nomake', 'tests'
        '-opengl', 'desktop'
    )
    if ($StaticRuntime) { $cfgArgs += '-static-runtime' }
    if ($ExtraConfigureArgs.Count -gt 0) { $cfgArgs += $ExtraConfigureArgs }

    $cfgLine = "call `"$configureBat`" $($cfgArgs -join ' ')"
    Write-Info "configure：$cfgLine"

    $bat = New-TempBatch @(
        "cd /d `"$BuildDir`"",
        $cfgLine,
        'exit /b %ERRORLEVEL%'
    )
    try {
        & cmd.exe /c $bat
        if ($LASTEXITCODE -ne 0) { throw "configure 失败（退出码 $LASTEXITCODE）" }
    }
    finally {
        Remove-Item $bat -Force -ErrorAction SilentlyContinue
    }
}

function Test-StaticQt {
    <# 产物校验：库存在、版本正确、确实是静态、CRT 与要求一致 #>
    param(
        [string] $InstallPrefix,
        [string] $ExpectVersion,
        [bool]   $ExpectStaticRuntime
    )

    $failed = @()

    $coreLib = Join-Path $InstallPrefix 'lib\Qt6Core.lib'
    if (Test-Path $coreLib) {
        $size = (Get-Item $coreLib).Length / 1MB
        Write-Info ("Qt6Core.lib: {0:N1} MB" -f $size)
    }
    else {
        $failed += "缺少 $coreLib"
    }

    $coreDll = Join-Path $InstallPrefix 'bin\Qt6Core.dll'
    if (Test-Path $coreDll) { $failed += "发现共享库 $coreDll，说明不是静态构建" }

    # 版本校验：优先用 qmake，缺失时退回到 Qt6ConfigVersion.cmake
    $ver = $null
    $qmake = Join-Path $InstallPrefix 'bin\qmake.exe'
    if (Test-Path $qmake) {
        $ver = (& $qmake -query QT_VERSION) | Select-Object -First 1
        Write-Info "qmake -query QT_VERSION = $ver"
        $conf = (& $qmake -query QT_CONFIG) | Out-String
        if ($conf -notmatch 'static') { $failed += 'qmake QT_CONFIG 中没有 static' }
    }
    if (-not $ver) {
        $verFile = Join-Path $InstallPrefix 'lib\cmake\Qt6\Qt6ConfigVersion.cmake'
        if (Test-Path $verFile) {
            $m = Select-String -Path $verFile -Pattern 'PACKAGE_VERSION\s+"([^"]+)"' | Select-Object -First 1
            if ($m) { $ver = $m.Matches[0].Groups[1].Value }
        }
        Write-Info "从 Qt6ConfigVersion.cmake 读到版本：$ver"
    }
    if (-not $ver) {
        $failed += '无法确定已安装的 Qt 版本（qmake 与 Qt6ConfigVersion.cmake 都不可用）'
    }
    elseif ($ExpectVersion -and $ver -ne $ExpectVersion) {
        $failed += "Qt 版本不符：期望 $ExpectVersion，实际 $ver"
    }

    if (-not $ExpectStaticRuntime) {
        Write-Info '未要求静态 CRT，跳过 /MT 强制校验'
    }

    # 用 dumpbin 读归档里的链接指令，确认 CRT 是 /MT (LIBCMT) 而不是 /MD (MSVCRT/UCRT)
    if ((Test-Path $coreLib) -and (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)) {
        $directives = (& dumpbin /directives $coreLib 2>$null) | Out-String
        $hasMt = $directives -match 'LIBCMT'
        $hasMd = $directives -match 'MSVCRT|libcmtd'
        Write-Info ("CRT 指令：LIBCMT={0} / MSVCRT={1}" -f $hasMt, $hasMd)
        if ($ExpectStaticRuntime -and -not $hasMt) { $failed += '要求 /MT（-static-runtime），但 Qt6Core.lib 未引用 LIBCMT' }
        if (-not $ExpectStaticRuntime -and $hasMt -and -not $hasMd) {
            Write-Info '提示：检测到 LIBCMT，实际是静态 CRT，但未加 -StaticRuntime'
        }
    }
    else {
        Write-Info '未找到 dumpbin，跳过 CRT 校验（其余检查继续）'
    }

    if (Test-Path $InstallPrefix) {
        $total = (Get-ChildItem $InstallPrefix -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1GB
        Write-Info ("安装目录：{0}（{1:N2} GB）" -f $InstallPrefix, $total)
    }

    if ($failed.Count -gt 0) {
        throw ("产物校验失败：`n  - " + ($failed -join "`n  - "))
    }
}

# ---------------------------------------------------------------- 主流程

try {
    Write-Step "参数"
    Write-Info "QtVersion   = $QtVersion"
    Write-Info "Modules     = $($Modules -join ', ')"
    Write-Info "SrcRoot     = $SrcRoot"
    Write-Info "BuildDir    = $BuildDir"
    Write-Info "Prefix      = $Prefix"
    Write-Info "MsvcToolset = $MsvcToolset"
    Write-Info "StaticCRT   = $([bool]$StaticRuntime)"

    if ($VerifyOnly) {
        Write-Step '仅校验已有产物'
        Import-MsvcEnvironment -Toolset $MsvcToolset
        Test-StaticQt -InstallPrefix $Prefix -ExpectVersion $QtVersion -ExpectStaticRuntime ([bool]$StaticRuntime)
        Write-Host ''
        Write-Host "校验通过（$($script:Timer.Elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Green
        return
    }

    if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }
    Write-Info "并行度      = $Jobs"

    Write-Step '初始化 MSVC 环境'
    Import-MsvcEnvironment -Toolset $MsvcToolset
    Assert-Compiler -Toolset $MsvcToolset

    foreach ($tool in @('cmake', 'ninja')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "PATH 中找不到 $tool。" }
    }
    Write-Info ("cmake = " + ((& cmake --version) | Select-Object -First 1))
    Write-Info ("ninja = " + ((& ninja --version) | Select-Object -First 1))

    Write-Step '准备源码'
    $tag = Resolve-QtTag -Version $QtVersion -Explicit $QtTag
    Get-QtSource -Tag $tag

    Write-Step '配置（静态）'
    Invoke-QtConfigure

    Write-Step "编译（并行 $Jobs）"
    $buildTimer = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Native -FilePath 'cmake' -Arguments @('--build', $BuildDir, '--parallel', "$Jobs") -FailMessage '编译失败'
    Write-Info ("编译耗时：" + $buildTimer.Elapsed.ToString('hh\:mm\:ss'))

    Write-Step '安装'
    Invoke-Native -FilePath 'cmake' -Arguments @('--install', $BuildDir) -FailMessage '安装失败'

    Write-Step '校验'
    Test-StaticQt -InstallPrefix $Prefix -ExpectVersion $QtVersion -ExpectStaticRuntime ([bool]$StaticRuntime)

    Write-Host ''
    Write-Host "构建完成，总耗时 $($script:Timer.Elapsed.ToString('hh\:mm\:ss'))，产物：$Prefix" -ForegroundColor Green
}
catch {
    Write-Host ''
    Write-Host "失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
