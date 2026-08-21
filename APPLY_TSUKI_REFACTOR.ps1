$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-Text([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing expected file: $Path" }
    return [IO.File]::ReadAllText((Resolve-Path $Path)).Replace("`r`n", "`n")
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path), $Text, $Utf8NoBom)
}

function Replace-Literal([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $Text = Read-Text $Path
    if (-not $Text.Contains($Old)) { throw "Patch failed ($Label): expected text not found in $Path" }
    Write-Text $Path ($Text.Replace($Old, $New))
    Write-Host "[OK] $Label"
}

function Replace-Regex([string]$Path, [string]$Pattern, [string]$Replacement, [string]$Label) {
    $Text = Read-Text $Path
    $Regex = New-Object System.Text.RegularExpressions.Regex($Pattern, [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $Regex.IsMatch($Text)) { throw "Patch failed ($Label): pattern not found in $Path" }
    $NewText = $Regex.Replace($Text, $Replacement, 1)
    Write-Text $Path $NewText
    Write-Host "[OK] $Label"
}

Write-Host "Applying Tsuki normal-content-only refactor..." -ForegroundColor Cyan

$ExpectedCommit = '47c989259a7f1d46d2154c319c557e933cd512b4'
if (Get-Command git -ErrorAction SilentlyContinue) {
    try {
        $Head = (git rev-parse HEAD 2>$null).Trim()
        if ($Head -and $Head -ne $ExpectedCommit) {
            Write-Warning "This pack was built against $ExpectedCommit but your repo is $Head. The script will still try to apply using code patterns."
        }
    } catch { }
}

# -----------------------------------------------------------------------------
# CatalogRepository: remove adult-only sources and add readable-title gating.
# -----------------------------------------------------------------------------
$Catalog = 'app/lib/core/data/catalog_repository.dart'

$adultImports = @(
"import '../../features/reader/data/adult_madara_source.dart';`n",
"import '../../features/reader/data/hitomi_source.dart';`n",
"import '../../features/reader/data/manhwa18cc_source.dart';`n",
"import '../../features/reader/data/manhwa18net_source.dart';`n",
"import '../../features/reader/data/omega_scans_source.dart';`n",
"import '../../features/reader/data/webtoon_xyz_source.dart';`n"
)
$catText = Read-Text $Catalog
foreach ($line in $adultImports) { $catText = $catText.Replace($line, '') }
Write-Text $Catalog $catText
Write-Host '[OK] Removed adult-only repository imports'

Replace-Regex $Catalog `
'  CatalogRepository\(\{.*?\n  \}\) : _config = config,.*?_indexCache = chapterIndexCache \?\? ChapterIndexCache\(\) \{' `
@'
  CatalogRepository({
    required AppConfig config,
    required MetadataProvider metadata,
    required MangaDexSource mangaDex,
    ComicKSource? comicK,
    MangaPillSource? mangaPill,
    WeebCentralSource? weebCentral,
    AsuraSource? asura,
    ChapterIndexCache? chapterIndexCache,
  }) : _config = config,
       _metadata = metadata,
       _mangaDex = mangaDex,
       _comicK = comicK ?? ComicKSource(),
       _mangaPill = mangaPill ?? MangaPillSource(),
       _weebCentral = weebCentral ?? WeebCentralSource(),
       _asura = asura ?? AsuraSource(),
       _indexCache = chapterIndexCache ?? ChapterIndexCache() {
'@ `
'CatalogRepository constructor'

# Omega Scans was previously wired as an adult source, so it must not remain.
$catText = Read-Text $Catalog
$catText = $catText.Replace("    OmegaScansSource? omegaScans,`n", '')
$catText = $catText.Replace("       _omegaScans = omegaScans ?? OmegaScansSource(),`n", '')
Write-Text $Catalog $catText

Replace-Regex $Catalog `
'  final AppConfig _config;.*?  final AsuraSource _asura;' `
@'
  final AppConfig _config;
  final MetadataProvider _metadata;
  final MangaDexSource _mangaDex;
  final ComicKSource _comicK;
  final MangaPillSource _mangaPill;
  final WeebCentralSource _weebCentral;
  final AsuraSource _asura;
'@ `
'CatalogRepository source fields'

Replace-Literal $Catalog `
'  Manga? cached(String id) => _cache[id];

  void remember(Manga manga) {
    _cache[manga.id] = manga;
  }
' `
@'
  Manga? cached(String id) {
    final value = _cache[id];
    return value == null || value.isAdult ? null : value;
  }

  void remember(Manga manga) {
    if (!manga.isAdult) _cache[manga.id] = manga;
  }

  Future<bool> hasReadableChapters(Manga manga) async {
    if (manga.isAdult) return false;
    if (_config.useDemoData) return manga.metadataChapterCount > 0;

    final summary = MangaChapterRegistry.summaryFor(manga.id);
    if (summary != null &&
        (summary.indexCount > 0 || summary.latestNumber != null)) {
      return true;
    }

    final local = await localChapters(manga, allowAdult: false);
    if (local != null &&
        local.any((chapter) => chapter.hasDirectlyReadableCopy)) {
      return true;
    }

    try {
      final probe = await _safeLatestPrimary(
        manga,
        allowAdult: false,
      ).timeout(_firstChapterDeadline);
      return probe?.chapter.hasDirectlyReadableCopy == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Manga>> filterReadableManga(
    List<Manga> items, {
    int targetCount = 24,
    int concurrency = 4,
  }) async {
    final safe = items.where((manga) => !manga.isAdult).toList(growable: false);
    if (_config.useDemoData) {
      return safe
          .where((manga) => manga.metadataChapterCount > 0)
          .take(targetCount)
          .toList(growable: false);
    }

    final accepted = <Manga>[];
    final width = concurrency < 1 ? 1 : concurrency;
    for (var start = 0;
        start < safe.length && accepted.length < targetCount;
        start += width) {
      final batch = safe.skip(start).take(width).toList(growable: false);
      final checks = await Future.wait(batch.map(hasReadableChapters));
      for (var i = 0; i < batch.length; i++) {
        if (checks[i]) accepted.add(batch[i]);
        if (accepted.length >= targetCount) break;
      }
    }
    return accepted;
  }
'@ `
'Readable manga availability helpers'

Replace-Regex $Catalog `
'      final result = _dedupe\(values\);\n      if \(!_config\.useDemoData\) \{.*?\n      return result;' `
@'
      final safe = _dedupe(values)
          .where((manga) => !manga.isAdult)
          .toList(growable: false);
      final result = await filterReadableManga(safe);
      if (!_config.useDemoData) {
        for (final manga in result.take(3)) {
          unawaited(prewarmChapters(manga, allowAdult: false));
        }
        for (final manga in result.skip(3).take(5)) {
          unawaited(primeChapterSummary(manga, allowAdult: false));
        }
      }
      return result;
'@ `
'Search returns readable non-adult manga only'

Replace-Regex $Catalog `
'      final result = _dedupe\(values\)\n          \.where\(\(manga\) => manga\.isAdult == request\.adultOnly\)\n          \.toList\(growable: false\);\n      if \(!_config\.useDemoData\) \{.*?\n      return result;' `
@'
      final safe = _dedupe(values)
          .where((manga) => !manga.isAdult)
          .toList(growable: false);
      final result = await filterReadableManga(safe);
      if (!_config.useDemoData) {
        for (final manga in result.take(3)) {
          unawaited(prewarmChapters(manga, allowAdult: false));
        }
        for (final manga in result.skip(3).take(5)) {
          unawaited(primeChapterSummary(manga, allowAdult: false));
        }
      }
      return result;
'@ `
'Browse returns readable non-adult manga only'

$catText = Read-Text $Catalog
$catText = $catText.Replace('.where((manga) => manga.isAdult == request.adultOnly)', '.where((manga) => !manga.isAdult)')
$catText = $catText.Replace('allowAdult: request.adultOnly', 'allowAdult: false')
Write-Text $Catalog $catText

Replace-Regex $Catalog `
'  Future<Manga\?> details\(String id\) async \{.*?\n  \}' `
@'
  Future<Manga?> details(String id) async {
    final value = _cache[id];
    if (value != null) return value.isAdult ? null : value;

    final loaded = await _metadata.getById(id);
    if (loaded == null || loaded.isAdult) return null;
    _cache[id] = loaded;
    return loaded;
  }
'@ `
'Adult titles rejected by details lookup'

Replace-Regex $Catalog `
'  List<Future<List<CanonicalChapter>> Function\(\)> _loadersFor\(.*?\n  \}\n\n  Future<List<CanonicalChapter>> _loadInitialProgressively' `
@'
  List<Future<List<CanonicalChapter>> Function()> _loadersFor(
    Manga manga, {
    required bool allowAdult,
  }) {
    if (manga.isAdult) return const <Future<List<CanonicalChapter>> Function()>[];
    return <Future<List<CanonicalChapter>> Function()>[
      () => _loadWeebCentral(manga, allowAdult: false),
      () => _loadComicK(manga),
      () => _loadMangaDex(manga, allowAdult: false),
      () => _loadAsura(manga),
      () => _loadMangaPill(manga),
    ];
  }

  Future<List<CanonicalChapter>> _loadInitialProgressively
'@ `
'Normal-only chapter source loaders'

Replace-Regex $Catalog `
"    final sourceOrder = manga\.isAdult \|\| allowAdult\n        \? const <String>\[.*?\n        : const <String>\['weebcentral', 'comick', 'mangadex', 'mangapill'\];" `
"    const sourceOrder = <String>['weebcentral', 'comick', 'mangadex', 'mangapill', 'asura'];" `
'Normal-only latest chapter probes'

Replace-Regex $Catalog `
"    if \(sourceName == 'manhwa18cc'\) \{.*?\n    return null;\n  \}\n\n  CanonicalChapter\? _latestChapterFrom" `
@'
    if (sourceName == 'asura') {
      final values = await _loadAsura(manga);
      return _latestChapterFrom(values);
    }
    return null;
  }

  CanonicalChapter? _latestChapterFrom
'@ `
'Removed adult latest-source branches'

Replace-Regex $Catalog `
'  Future<List<CanonicalChapter>> _loadSourceByName\(.*?\n  \}\n\n  bool _isNewerThanIndex' `
@'
  Future<List<CanonicalChapter>> _loadSourceByName(
    Manga manga,
    String sourceName, {
    required bool allowAdult,
  }) {
    if (manga.isAdult) return Future.value(const <CanonicalChapter>[]);
    return switch (sourceName) {
      'weebcentral' => _loadWeebCentral(manga, allowAdult: false),
      'comick' => _loadComicK(manga),
      'mangadex' => _loadMangaDex(manga, allowAdult: false),
      'mangapill' => _loadMangaPill(manga),
      'asura' => _loadAsura(manga),
      _ => Future.value(const <CanonicalChapter>[]),
    };
  }

  bool _isNewerThanIndex
'@ `
'Removed adult source dispatch'

Replace-Regex $Catalog `
'  Future<List<CanonicalChapter>> _loadManhwa18Cc\(Manga manga\) =>.*?  Future<List<CanonicalChapter>> _loadMangaPill' `
'  Future<List<CanonicalChapter>> _loadMangaPill' `
'Removed adult source loading methods'

Replace-Regex $Catalog `
'  String _mappingKey\(Manga manga, String sourceName\) \{.*?\n  \}\n\n  String _chapterCacheKey\(Manga manga, bool allowAdult\) \{.*?\n  \}' `
@'
  String _mappingKey(Manga manga, String sourceName) => '${manga.id}|$sourceName';

  String _chapterCacheKey(Manga manga, bool allowAdult) => '${manga.id}|safe';
'@ `
'Removed adult cache namespaces'

Replace-Regex $Catalog `
"        if \(copy\.sourceId == _omegaScans\.id\) \{.*?        if \(copy\.sourceId == _webtoonXyz\.id\) \{\n          return await _webtoonXyz\.getChapterPages\(copy\.chapterId\);\n        \}\n" `
'' `
'Removed adult page-source dispatch'

# Defensive guards: adult titles cannot use the normal chapter methods even if a
# stale caller supplies allowAdult=true.
$catText = Read-Text $Catalog
$catText = $catText.Replace('if (manga.isAdult != allowAdult) return const <CanonicalChapter>[];', 'if (manga.isAdult) return const <CanonicalChapter>[];')
$catText = $catText.Replace('if (_config.useDemoData || manga.isAdult != allowAdult) return;', 'if (_config.useDemoData || manga.isAdult) return;')
$catText = $catText.Replace('if (manga.isAdult != allowAdult) return const [];', 'if (manga.isAdult) return const [];')
$catText = $catText.Replace('allowAdult: allowAdult', 'allowAdult: false')
$catText = $catText.Replace('includeAdult: includeAdult', 'includeAdult: false')
Write-Text $Catalog $catText
Write-Host '[OK] Enforced normal-only chapter calls'

# -----------------------------------------------------------------------------
# AniList: adult classification remains only as a deny-only guard.
# -----------------------------------------------------------------------------
$Ani = 'app/lib/features/search/data/anilist_metadata_provider.dart'
$aniText = Read-Text $Ani
$aniText = $aniText.Replace('adultOnly: includeAdult,', 'adultOnly: false,')
$aniText = $aniText.Replace("'isAdult': request.adultOnly,", "'isAdult': false,")
$aniText = $aniText.Replace('.where((manga) => manga.isAdult == request.adultOnly)', '.where((manga) => !manga.isAdult)')
$aniText = $aniText.Replace('isAdult: $adultOnly,', 'isAdult: false,')
$aniText = $aniText.Replace('.where((manga) => manga.isAdult == adultOnly)', '.where((manga) => !manga.isAdult)')
Write-Text $Ani $aniText
Write-Host '[OK] AniList permanently requests non-adult manga'

# -----------------------------------------------------------------------------
# Home: remove mode state, hide titles that have no readable chapters, logout.
# -----------------------------------------------------------------------------
$Home = 'app/lib/features/home/presentation/home_screen.dart'
$homeText = Read-Text $Home
if (-not $homeText.Contains("../../../shared/widgets/logout_button.dart")) {
    $homeText = $homeText.Replace("import '../../../shared/widgets/cover_art.dart';", "import '../../../shared/widgets/cover_art.dart';`nimport '../../../shared/widgets/logout_button.dart';")
}
$homeText = [regex]::Replace($homeText, 'bookmarkedManga: value\.bookmarkedManga,\s*adultContent: value\.adultContent,', 'bookmarkedManga: value.bookmarkedManga,')
$homeText = [regex]::Replace($homeText, '(?s)\s*// Adult mode is a separate view of the same persisted library\. Hidden\s*// mode bookmarks/progress remain saved but are not fetched or rendered\.\s*if \(manga\.isAdult != state\.adultContent\) continue;', "`n      if (manga.isAdult) continue;`n      if (!await repository.hasReadableChapters(manga)) continue;", 1)
$homeText = $homeText.Replace('allowAdult: state.adultContent', 'allowAdult: false')
$homeText = $homeText.Replace('repository.chapters(manga, allowAdult: state.adultContent).ignore();', 'repository.chapters(manga, allowAdult: false).ignore();')
$homeText = [regex]::Replace($homeText, '\s*final adultContentEnabled = libraryState\.adultContent;', '')
$homeText = $homeText.Replace('.where((entry) => entry.manga.isAdult == adultContentEnabled)', '.where((entry) => !entry.manga.isAdult)')
$homeText = [regex]::Replace($homeText, "(?s)Padding\(\s*padding: const EdgeInsets\.only\(right: 16\),\s*child: IconButton\(\s*onPressed: \(\) => context\.push\('/settings'\),\s*icon: const Icon\(Icons\.settings_outlined\),\s*tooltip: 'Settings',\s*\),\s*\)", "const Padding(`n            padding: EdgeInsets.only(right: 16),`n            child: LogoutButton(),`n          )", 1)
Write-Text $Home $homeText
Write-Host '[OK] Home normal-only + logout + chapter availability'

# -----------------------------------------------------------------------------
# Discover: static safe mode, logout, compact one-line information chips.
# -----------------------------------------------------------------------------
$Discover = 'app/lib/features/discover/presentation/discover_screen.dart'
$discText = Read-Text $Discover
if (-not $discText.Contains("../../../shared/widgets/logout_button.dart")) {
    $discText = $discText.Replace("import '../../../shared/widgets/one_time_hint.dart';", "import '../../../shared/widgets/one_time_hint.dart';`nimport '../../../shared/widgets/logout_button.dart';")
}
$discText = [regex]::Replace($discText, '(?s)\s*final adultMode = ref\.watch\(adultModeProvider\);\s*ref\.listen<bool>\(adultModeProvider,.*?\n    \}\);', '')
$discText = $discText.Replace("title: Text(adultMode ? 'Adult Discover' : 'Discover'),", "title: const Text('Discover'),")
$discText = [regex]::Replace($discText, "(?s)Padding\(\s*padding: const EdgeInsets\.only\(right: 16\),\s*child: IconButton\(\s*onPressed: \(\) \{\s*context\.push\('/settings'\);\s*\},\s*icon: const Icon\(Icons\.settings_outlined\),\s*tooltip: 'Settings',\s*\),\s*\)", "const Padding(`n            padding: EdgeInsets.only(right: 16),`n            child: LogoutButton(),`n          )", 1)
$discText = [regex]::Replace($discText, '\s*final cardAdultMode = ref\.watch\(adultModeProvider\);', '')
$discText = $discText.Replace('allowAdult: cardAdultMode', 'allowAdult: false')
$discText = $discText.Replace('padding: const EdgeInsets.symmetric(horizontal: 8),', 'padding: const EdgeInsets.symmetric(horizontal: 5),')
$discText = $discText.Replace('Icon(icon, size: 14, color: AppColors.accent)', 'Icon(icon, size: 12.5, color: AppColors.accent)')
$discText = $discText.Replace('style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)', 'style: const TextStyle(fontSize: 10.8, fontWeight: FontWeight.w800)')
Write-Text $Discover $discText
Write-Host '[OK] Discover normal-only + logout + compact info row'

# -----------------------------------------------------------------------------
# Library: safe readable bookmarks only, no mode-specific empty states, logout.
# -----------------------------------------------------------------------------
$Library = 'app/lib/features/library/presentation/library_screen.dart'
$libText = Read-Text $Library
if (-not $libText.Contains("../../../shared/widgets/logout_button.dart")) {
    $libText = $libText.Replace("import '../../../shared/widgets/one_time_hint.dart';", "import '../../../shared/widgets/one_time_hint.dart';`nimport '../../../shared/widgets/logout_button.dart';")
}
$libText = [regex]::Replace($libText, 'bookmarkedManga: value\.bookmarkedManga,\s*adultContent: value\.adultContent,', 'bookmarkedManga: value.bookmarkedManga,')
$libText = [regex]::Replace($libText, '(?s)      if \(manga != null\) \{\s*repository\.remember\(manga\);\s*items\.add\(manga\);\s*if \(manga\.isAdult == state\.adultContent\) \{\s*unawaited\(\s*repository\.prewarmChapters\(manga, allowAdult: state\.adultContent\),\s*\);\s*\}\s*\}', @'
      if (manga != null &&
          !manga.isAdult &&
          await repository.hasReadableChapters(manga)) {
        repository.remember(manga);
        items.add(manga);
        unawaited(repository.prewarmChapters(manga, allowAdult: false));
      }
'@)
$libText = [regex]::Replace($libText, '(?s)\s*/\*\s*\* Adult visibility filter only\.\s*\*/\s*final items = allItems\s*\.where\(\(manga\) => manga\.isAdult == libraryState\.adultContent\)\s*\.toList\(\);', "`n    final items = itemsState.valueOrNull ?? const <Manga>[];")
$libText = $libText.Replace("title: Text(libraryState.adultContent ? 'Adult Library' : 'Library'),", "title: const Text('Library'),")
$libText = [regex]::Replace($libText, "(?s)Padding\(\s*padding: const EdgeInsets\.only\(right: 16\),\s*child: IconButton\(\s*onPressed: \(\) \{\s*context\.push\('/settings'\);\s*\},\s*icon: const Icon\(Icons\.settings_outlined\),\s*tooltip: 'Settings',\s*\),\s*\)", "const Padding(`n            padding: EdgeInsets.only(right: 16),`n            child: LogoutButton(),`n          )", 1)
$libText = $libText.Replace('_buildContent(libraryState, itemsState, items, allItems)', '_buildContent(libraryState, itemsState, items)')
$libText = [regex]::Replace($libText, '    List<Manga> items,\s*List<Manga> allItems,', '    List<Manga> items,', 1)
$libText = [regex]::Replace($libText, '(?s)\n    if \(items\.isEmpty && allItems\.isNotEmpty\) \{.*?\n    \}\n\n    if \(items\.isEmpty\)', "`n    if (items.isEmpty)")
Write-Text $Library $libText
Write-Host '[OK] Library normal-only + logout + chapter availability'

# -----------------------------------------------------------------------------
# Details: adult is a hard reject, generic chapterless message, compact chips.
# -----------------------------------------------------------------------------
$Details = 'app/lib/features/manga_details/presentation/manga_details_screen.dart'
$detailText = Read-Text $Details
$detailText = [regex]::Replace($detailText, '(?s)    if \(manga\.isAdult != library\.adultContent\) \{.*?\n    \}\n\n    final chaptersAsync', @'
    if (manga.isAdult) {
      return Scaffold(
        body: _ModernMessage(
          icon: Icons.visibility_off_rounded,
          message: "This title isn't available in Tsuki.",
          retryLabel: 'Go Back',
          onRetry: () {
            if (context.canPop()) context.pop();
          },
        ),
      );
    }

    final chaptersAsync
'@)
$detailText = [regex]::Replace($detailText, "message: library\.adultContent\s*\? 'No directly readable adult chapters were found from the supported public sources for this title\.'\s*: 'No English chapters available from the configured sources\.'", "message: 'No readable English chapters are available for this title.'")
$detailText = $detailText.Replace('padding: const EdgeInsets.symmetric(horizontal: 8),', 'padding: const EdgeInsets.symmetric(horizontal: 5),')
$detailText = $detailText.Replace('Icon(icon, size: 14, color: AppColors.accent)', 'Icon(icon, size: 12.5, color: AppColors.accent)')
$detailText = $detailText.Replace('style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)', 'style: const TextStyle(fontSize: 10.8, fontWeight: FontWeight.w800)')
Write-Text $Details $detailText
Write-Host '[OK] Details safe reject + compact one-line info chips'

# -----------------------------------------------------------------------------
# Reader: no mode, no adult path.
# -----------------------------------------------------------------------------
$Reader = 'app/lib/features/reader/presentation/reader_screen.dart'
$readerText = Read-Text $Reader
$readerText = [regex]::Replace($readerText, "(?s)      final adultMode = ref\.read\(userLibraryProvider\)\.adultContent;\s*if \(manga\.isAdult != adultMode\) \{\s*_setFatal\('This title is hidden in the current content mode\.'\);\s*return;\s*\}\s*\n\s*final chapters = await repository\.chapters\(manga, allowAdult: adultMode\);", @'
      if (manga.isAdult) {
        _setFatal("This title isn't available in Tsuki.");
        return;
      }

      final chapters = await repository.chapters(manga, allowAdult: false);
'@)
Write-Text $Reader $readerText
Write-Host '[OK] Reader normal-content-only'

# -----------------------------------------------------------------------------
# Delete the removed feature and adult-only adapters.
# -----------------------------------------------------------------------------
$Delete = @(
  'app/lib/features/settings/presentation/settings_screen.dart',
  'app/lib/features/reader/data/adult_madara_source.dart',
  'app/lib/features/reader/data/hitomi_source.dart',
  'app/lib/features/reader/data/manhwa18cc_source.dart',
  'app/lib/features/reader/data/manhwa18net_source.dart',
  'app/lib/features/reader/data/omega_scans_source.dart',
  'app/lib/features/reader/data/webtoon_xyz_source.dart',
  'apply_tsuki_v11_fix.ps1'
)
foreach ($Path in $Delete) {
    if (Test-Path $Path) {
        Remove-Item $Path -Force
        Write-Host "[OK] Removed $Path"
    }
}

# -----------------------------------------------------------------------------
# Clean source references that should no longer exist.
# -----------------------------------------------------------------------------
$checks = @(
  'adultModeProvider',
  '.adultContent',
  "push('/settings')",
  'Icons.settings_outlined',
  'Adult Search',
  'Adult Discover',
  'Adult Library'
)
foreach ($needle in $checks) {
    $matches = Get-ChildItem app/lib -Recurse -Filter *.dart | Select-String -SimpleMatch $needle
    if ($matches) {
        Write-Warning "Remaining '$needle' references:`n$($matches | Out-String)"
    }
}

Write-Host ''
Write-Host 'Core refactor applied.' -ForegroundColor Green
Write-Host 'Next run from the app folder:' -ForegroundColor Cyan
Write-Host '  dart format lib test tool'
Write-Host '  flutter analyze'
Write-Host '  flutter test'
