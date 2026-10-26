# Оптимизация Android TV (Haier DVB2K, Android TV 11) через ADB без root — версия для Windows.
# Запуск: powershell -ExecutionPolicy Bypass -File scripts\tv-optimize.ps1 <команда> [аргумент]
# Команды те же, что у tv-optimize.sh: connect, info, scan, debloat, optional, disable, perf, dns, launcher, restore.
param([string]$Command = "help", [string]$Arg = "")

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path -Parent $PSScriptRoot
$Lists = Join-Path $Root "packages"
$StateDir = Join-Path $Root "state"
$Adb = if ($env:ADB) { $env:ADB } else { "adb" }
$StockLauncher = "com.google.android.tvlauncher"
$AltLaunchers = @("com.spocky.projengmenu", "me.efesser.flauncher", "com.wolf.firelauncher")
$AnimKeys = @("window_animation_scale", "transition_animation_scale", "animator_duration_scale")

function Die($msg) { Write-Host "Ошибка: $msg" -ForegroundColor Red; exit 1 }

function Shell { & $Adb shell @args | ForEach-Object { $_.TrimEnd("`r") } }

function Require-Device {
    if (-not (Get-Command $Adb -ErrorAction SilentlyContinue)) { Die "adb не найден. Распакуйте platform-tools и добавьте папку в PATH." }
    & $Adb get-state 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Die "ТВ не подключён. Выполните: tv-optimize.ps1 connect <IP телевизора>" }
}

function Read-List($name) {
    Get-Content (Join-Path $Lists "$name.txt") -Encoding UTF8 |
        ForEach-Object { ($_ -replace "#.*", "").Trim() } | Where-Object { $_ }
}

function Describe($pkg) {
    foreach ($f in Get-ChildItem $Lists -Filter *.txt) {
        foreach ($line in Get-Content $f.FullName -Encoding UTF8) {
            if ($line -match "^$([regex]::Escape($pkg))\s+#\s*(.*)$") { return $Matches[1] }
        }
    }
    return ""
}

function Is-Protected($pkg) {
    foreach ($rule in Read-List "never") {
        if ($rule.EndsWith("*")) { if ($pkg.StartsWith($rule.TrimEnd("*"))) { return $true } }
        elseif ($pkg -eq $rule) { return $true }
    }
    return $false
}

function Packages($flag) {
    $cmd = @("pm", "list", "packages"); if ($flag) { $cmd += $flag }
    Shell @cmd | ForEach-Object { $_ -replace "^package:", "" }
}

function Confirm($question) { (Read-Host "$question [y/N]") -match "^[YyДд]$" }

function State-File {
    $serial = (& $Adb get-serialno).Trim() -replace "[:/]", "_"
    Join-Path $StateDir "disabled-$serial.txt"
}

function Disable-Pkg($pkg, [switch]$Force) {
    if ((Is-Protected $pkg) -and -not $Force) { Write-Host "  пропущен (защищён, см. packages\never.txt): $pkg"; return }
    $out = Shell pm disable-user --user 0 $pkg
    if ("$out" -match "disabled") {
        Write-Host "  отключён: $pkg"
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        $sf = State-File
        if (-not ((Test-Path $sf) -and (Get-Content $sf) -contains $pkg)) { Add-Content $sf $pkg }
    } else { Write-Host "  не удалось отключить: $pkg" }
}

switch ($Command) {
    "connect" {
        if (-not $Arg) { Die "укажите IP телевизора: tv-optimize.ps1 connect 192.168.1.50" }
        $target = if ($Arg.Contains(":")) { $Arg } else { "${Arg}:5555" }
        & $Adb connect $target
        Write-Host "Если на ТВ появился запрос «Разрешить отладку по USB?» — отметьте «Всегда», нажмите OK и повторите connect."
    }
    "info" {
        Require-Device
        Write-Host "Модель:   $(Shell getprop ro.product.model)"
        Write-Host "Android:  $(Shell getprop ro.build.version.release)"
        Write-Host "Чипсет:   $(Shell getprop ro.board.platform)"
        Shell cat /proc/meminfo | Where-Object { $_ -match "^(MemTotal|MemAvailable):" } | ForEach-Object { "Память:   $_" }
        Write-Host "Лаунчер:  $(Shell cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN | Select-Object -Last 1)"
    }
    "scan" {
        Require-Device
        $all = Packages ""; $on = Packages "-e"
        foreach ($list in "safe", "optional") {
            Write-Host "== packages\$list.txt =="
            foreach ($pkg in Read-List $list) {
                if ($all -notcontains $pkg) { continue }
                $status = if ($on -contains $pkg) { "ВКЛ " } else { "выкл" }
                Write-Host ("  [{0}] {1,-42} {2}" -f $status, $pkg, (Describe $pkg))
            }
        }
        Write-Host "== Установленные вами приложения =="
        Packages "-3" | Sort-Object | ForEach-Object { "  $_" }
        Write-Host "== Системные пакеты, похожие на рекламу/рекомендации/магазины производителя =="
        Write-Host "   (проверьте название в интернете, прежде чем отключать: tv-optimize.ps1 disable <пакет>)"
        $known = @(Read-List "safe") + @(Read-List "optional")
        $all | Where-Object { $_ -match "haier|ads|advert|promo|recommend|ott|store|market|launcher|weather|tvcloud|dataservice" -and $known -notcontains $_ } |
            Sort-Object | ForEach-Object { "  $_" }
    }
    "debloat" {
        Require-Device
        $on = Packages "-e"
        $targets = @(Read-List "safe" | Where-Object { $on -contains $_ })
        if ($targets.Count -eq 0) { Write-Host "Нечего отключать — всё из safe.txt уже отключено или не установлено."; break }
        Write-Host "Будут отключены:"
        $targets | ForEach-Object { Write-Host ("  {0,-42} {1}" -f $_, (Describe $_)) }
        if (-not (Confirm "Продолжить?")) { Write-Host "Отменено."; break }
        $targets | ForEach-Object { Disable-Pkg $_ }
    }
    "optional" {
        Require-Device
        $on = Packages "-e"
        foreach ($pkg in Read-List "optional") {
            if ($on -contains $pkg -and (Confirm "Отключить $pkg ($(Describe $pkg))?")) { Disable-Pkg $pkg }
        }
    }
    "disable" {
        Require-Device
        if (-not $Arg) { Die "укажите пакет: tv-optimize.ps1 disable com.example.app" }
        if ((Packages "") -notcontains $Arg) { Die "пакет $Arg не установлен" }
        if (Is-Protected $Arg) {
            Write-Host "Пакет $Arg в списке защищённых. Отключение может сломать эфир, пульт или загрузку ТВ."
            if (Confirm "Всё равно отключить? (вернуть: tv-optimize.ps1 restore)") { Disable-Pkg $Arg -Force }
        } else { Disable-Pkg $Arg }
    }
    "perf" {
        Require-Device
        $AnimKeys | ForEach-Object { Shell settings put global $_ 0.5 | Out-Null }
        Write-Host "Анимации ускорены в 2 раза."
        Shell pm trim-caches 999G | Out-Null
        Write-Host "Кэш приложений очищен."
        Shell cat /proc/meminfo | Where-Object { $_ -match "^MemAvailable:" } | ForEach-Object { "Свободно: $_" }
    }
    "dns" {
        Require-Device
        $dnsHost = if ($Arg) { $Arg } else { "dns.adguard-dns.com" }
        if ($dnsHost -eq "off") {
            Shell settings put global private_dns_mode off | Out-Null
            Shell settings delete global private_dns_specifier | Out-Null
            Write-Host "Private DNS выключен."
        } else {
            Shell settings put global private_dns_mode hostname | Out-Null
            Shell settings put global private_dns_specifier $dnsHost | Out-Null
            Write-Host "Private DNS: $dnsHost. Реклама внутри многих приложений и баннеры будут блокироваться."
            Write-Host "Если пропадёт интернет — выполните: tv-optimize.ps1 dns off"
        }
    }
    "launcher" {
        Require-Device
        $all = Packages ""
        $alt = $AltLaunchers | Where-Object { $all -contains $_ } | Select-Object -First 1
        if (-not $alt) { Die "сначала установите из Play Маркета Projectivy Launcher или FLauncher, затем повторите." }
        Write-Host "Найден лаунчер: $alt"
        Write-Host "Стандартный лаунчер ($StockLauncher) с рекламными рядами будет отключён, кнопка Home откроет $alt."
        if (-not (Confirm "Продолжить?")) { Write-Host "Отменено."; break }
        Disable-Pkg $StockLauncher -Force
        Shell am start -a android.intent.action.MAIN -c android.intent.category.HOME | Out-Null
        Write-Host "Если на ТВ появится выбор лаунчера — выберите $alt и «Всегда»."
    }
    "restore" {
        Require-Device
        if (-not (Confirm "Включить обратно все отключённые этим скриптом пакеты и сбросить настройки?")) { break }
        $off = Packages "-d"; $sf = State-File
        $candidates = @(Read-List "safe") + @(Read-List "optional") + @($StockLauncher)
        if (Test-Path $sf) { $candidates += Get-Content $sf }
        $candidates | Select-Object -Unique | Where-Object { $off -contains $_ } | ForEach-Object {
            Shell pm enable --user 0 $_ | Out-Null; Write-Host "  включён: $_"
        }
        if (Test-Path $sf) { Remove-Item $sf }
        $AnimKeys | ForEach-Object { Shell settings put global $_ 1 | Out-Null }
        Shell settings put global private_dns_mode off | Out-Null
        Write-Host "Готово. Перезагрузите ТВ: adb reboot"
    }
    default {
        Write-Host @"
Использование: tv-optimize.ps1 <команда> [аргумент]

  connect <IP>        подключиться к ТВ по сети (порт 5555)
  info                модель, версия Android, свободная память
  scan                что установлено из списков + сторонние и подозрительные пакеты
  debloat             отключить пакеты из packages\safe.txt (с подтверждением)
  optional            по одному спросить про пакеты из packages\optional.txt
  disable <пакет>     отключить конкретный пакет (например, найденный через scan)
  perf                ускорить анимации (0.5x) и очистить кэш приложений
  dns [хост|off]      Private DNS для блокировки рекламы (по умолчанию dns.adguard-dns.com)
  launcher            перейти на альтернативный лаунчер (Projectivy / FLauncher / Wolf)
  restore             вернуть всё как было
"@
    }
}
