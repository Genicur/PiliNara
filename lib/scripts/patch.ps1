param(
    [string]$platform = ""
)

$env:GIT_AUTHOR_NAME = "ci"
$env:GIT_AUTHOR_EMAIL = "example@example.com"
$env:GIT_COMMITTER_NAME = "ci"
$env:GIT_COMMITTER_EMAIL = "example@example.com"

# TODO: remove
# https://github.com/flutter/flutter/issues/182281
$NewOverScrollIndicator = "362b1de29974ffc1ed6faa826e1df870d7bec75f";

# set `gestureSettings`
$BottomSheetAndroidPatch = "lib/scripts/bottom_sheet_android.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1906
$BottomSheetIOSFlutterPatch = "lib/scripts/bottom_sheet_ios_flutter.patch"
$BottomSheetIOSPiliPlusPatch = "lib/scripts/bottom_sheet_ios_piliplus.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1662
# handle bottom scroll event
$ScrollViewPatch = "lib/scripts/scroll_view.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2106
# use `TouchGestureRecognizer` on all platforms
$TextSelectionPatch = "lib/scripts/text_selection.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/1947
$NavigatorPatch = "lib/scripts/navigator.patch"

# fix predictive back direction after popping a nested route
# (route below mounts the transition with a null back event during another
#  route's gesture; direction tween is never recomputed on later gestures)
$PredictiveBackPatch = "lib/scripts/predictive_back_page_transitions_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2107
$ImageAnimPatch = "lib/scripts/image_anim.patch"

# remove `_scheduleRebuild`
$LayoutBuilderPatch = "lib/scripts/layout_builder.patch"

# https://github.com/bggRGjQaUbCoE/PiliPlus/issues/2308
$NavigationDrawerPatch = "lib/scripts/navigation_drawer.patch"

# apply text color to icon color
$PopupMenuPatch = "lib/scripts/popup_menu.patch"

# remove `Hero` effect
$FABPatch = "lib/scripts/fab.patch"

# https://github.com/flutter/flutter/issues/139890
# https://github.com/flutter/flutter/issues/174689
# separator support
# clamp handle offset
# widgetspan selection support
# clear selection when tapping outside
# free selection if there is only one text
# clamp dragging selection behavior on Android
# show selection menu if secondary tap position is in text region on desktop
$SelectableRegionPatch = "lib/scripts/selectable_region.patch"

# https://github.com/flutter/flutter/issues/132047
# https://github.com/flutter/flutter/issues/174689
$EditableTextPatch = "lib/scripts/editable_text.patch"

# set `selectAllOnFocus` to `false` by default
$TextFieldPatch = "lib/scripts/text_field.patch"

# notify `userScrollDirection` only if position is actually changing
$ScrollPositionPatch = "lib/scripts/scroll_position.patch"

# expose `_shouldIgnorePointer`
$ScrollablePatch = "lib/scripts/scrollable.patch"

# expose
$ScaffoldPatch = "lib/scripts/scaffold.patch"

# fix nested scrollable gesture
# custom `HorizontalDragGestureRecognizer` support
$ScrollableGesturePatch = "lib/scripts/scrollable_gesture.patch"

# expose
$DraggableScrollableSheetPatch = "lib/scripts/draggable_scrollable_sheet.patch"

# expose
$TextPatch = "lib/scripts/text.patch"

# expose
$TextPainterPatch = "lib/scripts/text_painter.patch"

$SliverPatch = "lib/scripts/sliver.patch"

$RefreshIndicatorPatch = "lib/scripts/refresh_indicator.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/124078
# https://github.com/flutter/flutter/pull/183261
$NullSafetySelectableRegionPatch = "lib/scripts/null_safety_for_selectable_region.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/90223
$ModalBarrierPatch = "lib/scripts/modal_barrier.patch"

# TODO: remove
# https://github.com/flutter/flutter/issues/182466
$MouseCursorPatch = "lib/scripts/mouse_cursor.patch"

$GeetestIOSPatch = "lib/scripts/geetest_ios.patch"

$DoubleTapGesturePatch = "lib/scripts/double_tap_gesture.patch"

if ($platform.ToLower() -eq "ios") {
    git apply $BottomSheetIOSPiliPlusPatch
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$BottomSheetIOSPiliPlusPatch applied"
    } else {
        throw "$LASTEXITCODE"
    }
    git apply $GeetestIOSPatch
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$GeetestIOSPatch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}

Set-Location $env:FLUTTER_ROOT

$picks   = @()
$reverts = @()
$patches = @($ModalBarrierPatch, $TextSelectionPatch, $MouseCursorPatch,
            $ImageAnimPatch, $LayoutBuilderPatch, $NavigationDrawerPatch,
            $PopupMenuPatch, $FABPatch, $NullSafetySelectableRegionPatch,
            $SelectableRegionPatch, $EditableTextPatch, $TextFieldPatch,
            $ScrollPositionPatch, $ScrollablePatch, $ScrollableGesturePatch,
            $DraggableScrollableSheetPatch, $ScaffoldPatch, $TextPatch,
            $TextPainterPatch, $SliverPatch, $RefreshIndicatorPatch,
            $DoubleTapGesturePatch)

switch ($platform.ToLower()) {
    "android" {
        $patches += $BottomSheetAndroidPatch
        $patches += $ScrollViewPatch
        $patches += $NavigatorPatch
        $patches += $PredictiveBackPatch

        git reset --hard HEAD
    }
    "ios" {
        $patches += $ScrollViewPatch
        $patches += $BottomSheetIOSFlutterPatch
        $patches += $NavigatorPatch
    }
    "linux" {
        git reset --hard HEAD
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

foreach ($pick in $picks) {
    git stash
    git cherry-pick $pick --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$pick picked"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($revert in $reverts) {
    git stash
    git revert $revert --no-edit
    if ($LASTEXITCODE -eq 0) {
        git reset --soft HEAD~1
        Write-Host "$revert reverted"
    } else {
        throw "$LASTEXITCODE"
    }
    git stash pop
}

foreach ($patch in $patches) {
    # 幂等：补丁可能因 workflow 重跑而重复应用（例如 newlibmpv 流程里
    # pub get 之后需要重新打一遍）。已应用过的直接跳过，而不是报错。
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
        continue
    }

    git apply -R --check "$env:GITHUB_WORKSPACE/$patch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch already applied, skipped"
        continue
    }

    Write-Host "$patch FAILED and is not already applied"
    throw "$LASTEXITCODE"
}

Set-Location $env:GITHUB_WORKSPACE

$BottomSheetAndroidPatchMaterial = "lib/scripts/material/bottom_sheet_android.patch"

$BottomSheetIOSFlutterMaterialPatchMaterial = "lib/scripts/material/bottom_sheet_ios_flutter_material.patch"

$ModalBarrierPatchMaterial = "lib/scripts/material/modal_barrier_material.patch"

$NavigationDrawerPatchMaterial = "lib/scripts/material/navigation_drawer.patch"

$PopupMenuPatchMaterial = "lib/scripts/material/popup_menu.patch"

$FABPatchMaterial = "lib/scripts/material/fab.patch"

$TextFieldPatchMaterial = "lib/scripts/material/text_field.patch"

$ScaffoldPatchMaterial = "lib/scripts/material/scaffold.patch"

$RefreshIndicatorPatchMaterial = "lib/scripts/material/refresh_indicator.patch"

$TabsPatchMaterial = "lib/scripts/material/tabs.patch"

# material_ui 补丁策略
# ----------------
# 原先这里是逐个 apply 单个 .patch 文件。这些补丁是按更早的 material_ui 写的，
# 与 1.11.0 的上下文行号、代码形态都对不上，逐个打必然 "patch does not apply"。
#
# 改为：以官方 1.11.0 纯净包为基准，生成一份**完整的**统一 diff（1.11.0-full.patch），
# 一次 apply。它覆盖项目实际需要的全部改动：
#   bottom_sheet.dart          BottomSheetState typedef / 泛型状态类 / childKey
#   scaffold.dart              StandardBottomSheet 公开化 / 控制器构造 /
#                              isLocalHistoryEntry / 拖拽回调公开化
#   tabs.dart                  minimumIndicatorWidth 参数贯通 / TabBarLayoutCallback
#   text_field.dart            光标定制
#   floating_action_button.dart / navigation_drawer.dart / popup_menu.dart
#   progress_indicator.dart（refresh_indicator 依赖）
#
# 旧的单文件补丁保留在仓库中供对照，但不再参与构建。
$MaterialFullPatch = "lib/scripts/material/1.11.0-full.patch"

$patches_material = @($MaterialFullPatch)

$PubCacheDir = "~/.pub-cache"

switch ($platform.ToLower()) {
    "android" {
        # bottom_sheet_android.patch 的改动（gestureSettings）已并入 1.11.0-full.patch，
        # 此处不再追加 —— 否则同一文件被改两次，第二个补丁必然冲突。
    }
    "ios" {
        $patches_material += $BottomSheetIOSFlutterMaterialPatchMaterial
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
        $PubCacheDir = "$env:LOCALAPPDATA/Pub/Cache"
    }
    default {}
}

# 解析实际使用的 material_ui 目录。
# 注意：package_config.json 可能指向 pub.dev 缓存，也可能指向镜像
# （如 pub.flutter-io.cn）。只查 pub.dev 会在镜像环境下找不到包，
# 进而给错误的副本打补丁 —— 这正是「本地增量构建能过、CI 全量构建失败」的原因。
function Get-MaterialUiDirs {
    $dirs = @()
    foreach ($host_ in Get-ChildItem "$PubCacheDir/hosted" -Directory -ErrorAction SilentlyContinue) {
        $dirs += Get-ChildItem $host_.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "material_ui-*" }
    }
    return $dirs
}

try {
    foreach ($d in Get-MaterialUiDirs) {
        Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
}

flutter pub get

# 以 package_config.json 记录的路径为准，避免给未使用的副本打补丁
$MaterialUiDir = $null
$pkgConfig = Join-Path $env:GITHUB_WORKSPACE ".dart_tool/package_config.json"
if (Test-Path $pkgConfig) {
    $cfg = Get-Content $pkgConfig -Raw | ConvertFrom-Json
    $entry = $cfg.packages | Where-Object { $_.name -eq "material_ui" } | Select-Object -First 1
    if ($entry -and $entry.rootUri) {
        $uriPath = $entry.rootUri -replace '^file:///', ''
        $candidate = $uriPath -replace '/', '\'
        if (Test-Path $candidate) {
            $MaterialUiDir = Get-Item $candidate
        }
    }
}

if (-not $MaterialUiDir) {
    $MaterialUiDir = Get-MaterialUiDirs | Select-Object -Last 1
}

if (-not $MaterialUiDir) {
    throw "material_ui package not found in pub cache"
}

Write-Host "material_ui dir: $($MaterialUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/material" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $MaterialUiDir.FullName

# material_ui 的补丁是按旧版本编写的，新版（1.11.0）的部分改动上游已经收编
# （例如 scaffold.patch 想改的 `onDragStart: handleDragStart` 现在本来就是对的）。
# 这类补丁直接 apply 会 "patch does not apply" 并中断构建。
# 处理方式：apply 失败时用 `git apply -R --check` 判断改动是否已存在，
# 已存在则跳过；确实冲突才抛错。
foreach ($patch in $patches_material) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
        continue
    }

    git apply -R --check "$env:GITHUB_WORKSPACE/$patch" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch already applied upstream, skipped"
        continue
    }

    Write-Host "$patch FAILED and is not already applied"
    throw "$LASTEXITCODE"
}

$BottomSheetIOSFlutterPatchCupertino = "lib/scripts/cupertino/bottom_sheet_ios_flutter.patch"

$patches_cupertino = @()

switch ($platform.ToLower()) {
    "android" {
    }
    "ios" {
        $patches_cupertino += $BottomSheetIOSFlutterPatchCupertino
    }
    "linux" {
    }
    "macos" {
    }
    "windows" {
    }
    default {}
}

$CupertinoUiDir = Get-ChildItem "$PubCacheDir/hosted/pub.dev" -Directory |
    Where-Object { $_.Name -like "cupertino_ui-*" } |
    Select-Object -Last 1

if (-not $CupertinoUiDir) {
    throw "cupertino_ui package not found in pub cache"
}

Write-Host "cupertino_ui dir: $($CupertinoUiDir.FullName)"

Get-ChildItem -Path "$env:GITHUB_WORKSPACE/lib/scripts/cupertino" -Filter *.patch | ForEach-Object {
    (Get-Content $_.FullName -Raw) -replace "`r`n", "`n" | 
        Set-Content -NoNewline $_.FullName
}

cd $CupertinoUiDir.FullName

foreach ($patch in $patches_cupertino) {
    git apply "$env:GITHUB_WORKSPACE/$patch"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$patch applied"
    } else {
        throw "$LASTEXITCODE"
    }
}
