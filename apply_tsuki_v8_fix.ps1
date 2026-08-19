$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Patch-File {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][scriptblock]$Patch,
        [Parameter(Mandatory=$true)][scriptblock]$Validate
    )
    if (-not (Test-Path $Path)) { throw "Could not find $Path" }
    $text = Get-Content -Raw -Path $Path
    $updated = & $Patch $text
    if (-not (& $Validate $updated)) { throw "Could not safely patch $Path" }
    if ($updated -ne $text) {
        Write-Utf8NoBom -Path $Path -Text $updated
        Write-Host "Patched $Path"
    } else {
        Write-Host "Already updated: $Path"
    }
}

# MangaDex: ensure adult permission from Settings reaches content-rating search.
$mangaDexPath = Join-Path $root 'app\lib\features\reader\data\mangadex_source.dart'
Patch-File -Path $mangaDexPath -Patch {
    param($text)

    if (-not $text.Contains('Future<String?> findConservativeMatch(') -or
        -not $text.Contains('bool allowAdult = false,')) {
        $text = [regex]::Replace(
            $text,
            '  Future<String\?> findConservativeMatch\(Manga canonical\) async \{\s*final match = await _findConservativeMatchDetails\(canonical\);\s*return match\?\.id;\s*\}',
@'
  Future<String?> findConservativeMatch(
    Manga canonical, {
    bool allowAdult = false,
  }) async {
    final match = await _findConservativeMatchDetails(
      canonical,
      allowAdult: allowAdult,
    );
    return match?.id;
  }
'@,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
    }

    $text = [regex]::Replace(
        $text,
        '  Future<_MangaDexMatch\?> _findConservativeMatchDetails\(Manga canonical\) async \{',
@'
  Future<_MangaDexMatch?> _findConservativeMatchDetails(
    Manga canonical, {
    bool allowAdult = false,
  }) async {
'@
    )

    $text = [regex]::Replace(
        $text,
        '      final match = await _findConservativeMatchForQuery\(\s*query,\s*canonical,\s*expected,\s*\);',
@'
      final match = await _findConservativeMatchForQuery(
        query,
        canonical,
        expected,
        allowAdult: allowAdult,
      );
'@,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $text = [regex]::Replace(
        $text,
        '  Future<_MangaDexMatch\?> _findConservativeMatchForQuery\(\s*String query,\s*Manga canonical,\s*Set<String> expected,\s*\) async \{',
@'
  Future<_MangaDexMatch?> _findConservativeMatchForQuery(
    String query,
    Manga canonical,
    Set<String> expected, {
    required bool allowAdult,
  }) async {
'@,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $text = $text.Replace('includeAdult: canonical.isAdult,', 'includeAdult: canonical.isAdult || allowAdult,')
    return $text
} -Validate {
    param($text)
    return $text.Contains('includeAdult: canonical.isAdult || allowAdult,') -and
           $text.Contains('required bool allowAdult,')
}

# Search: every visible result gets a reactive per-manga chapter summary.
$searchPath = Join-Path $root 'app\lib\features\search\presentation\search_screen.dart'
Patch-File -Path $searchPath -Patch {
    param($text)

    # Remove older one-global-stream workaround; the family provider is precise.
    $text = $text.Replace("    ref.watch(chapterSummaryUpdatesProvider);`r`n", '')
    $text = $text.Replace("    ref.watch(chapterSummaryUpdatesProvider);`n", '')

    # Insert per-item label after each `final manga = items[index];` only when missing.
    $pattern = 'final manga = items\[index\];(?!\s*final chapterLabel)'
    $replacement = @'
final manga = items[index];
      final chapterLabel = ref
              .watch(chapterSummaryLabelProvider(manga))
              .valueOrNull ??
          manga.chapterDisplayLabel;
'@.TrimEnd()
    $text = [regex]::Replace($text, $pattern, $replacement)

    $text = $text.Replace('${manga.chapterCount} chp', '$chapterLabel chp')
    $text = $text.Replace('${manga.chapterDisplayLabel} chp', '$chapterLabel chp')
    return $text
} -Validate {
    param($text)
    return $text.Contains('chapterSummaryLabelProvider(manga)') -and
           $text.Contains("'`$chapterLabel chp'")
}

# Discover: the card itself primes/watches its manga. No top-3 dependency.
$discoverPath = Join-Path $root 'app\lib\features\discover\presentation\discover_screen.dart'
Patch-File -Path $discoverPath -Patch {
    param($text)

    $text = $text.Replace("    ref.watch(chapterSummaryUpdatesProvider);`r`n", '')
    $text = $text.Replace("    ref.watch(chapterSummaryUpdatesProvider);`n", '')

    $reactive = @'
    final chapterLabel = ref
            .watch(chapterSummaryLabelProvider(manga))
            .valueOrNull ??
        (details ?? manga).chapterDisplayLabel;
'@.TrimEnd()

    $text = [regex]::Replace(
        $text,
        '    final chapterLabel = .*?;',
        $reactive,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    if (-not $text.Contains('chapterSummaryLabelProvider(manga)')) {
        $needle = '    final details = ref.watch(catalogProvider).cached(manga.id);'
        $text = $text.Replace($needle, $needle + "`r`n`r`n" + $reactive)
    }

    $text = [regex]::Replace(
        $text,
        'final\s+chapterCount\s*=\s*details\?\.chapterCount\s*\?\?\s*manga\.chapterCount\s*;',
        ''
    )
    $text = $text.Replace("label: '`$chapterCount chp',", "label: '`$chapterLabel chp',")
    return $text
} -Validate {
    param($text)
    return $text.Contains('chapterSummaryLabelProvider(manga)') -and
           $text.Contains("label: '`$chapterLabel chp',")
}

# Details: use the same reactive label as the cards.
$detailsPath = Join-Path $root 'app\lib\features\manga_details\presentation\manga_details_screen.dart'
Patch-File -Path $detailsPath -Patch {
    param($text)

    $reactive = @'
    final chapterCountLabel = ref
            .watch(chapterSummaryLabelProvider(manga))
            .valueOrNull ??
        manga.chapterDisplayLabel;
'@.TrimEnd()

    $text = [regex]::Replace(
        $text,
        '    final chapterCountLabel = .*?;',
        $reactive,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    $text = [regex]::Replace(
        $text,
        'final\s+actualChapterCount\s*=\s*loadedChapters\.isNotEmpty\s*\?\s*loadedChapters\.length\s*:\s*manga\.chapterCount\s*;',
        $reactive.Trim()
    )

    if (-not $text.Contains('chapterSummaryLabelProvider(manga)')) {
        $needle = '    final loadedChapters ='
        $pos = $text.IndexOf($needle)
        if ($pos -ge 0) {
            $lineEnd = $text.IndexOf(';', $pos)
            if ($lineEnd -ge 0) {
                $lineEnd++
                $text = $text.Insert($lineEnd, "`r`n`r`n" + $reactive)
            }
        }
    }

    return $text
} -Validate {
    param($text)
    return $text.Contains('chapterSummaryLabelProvider(manga)') -and
           $text.Contains('chapterCountLabel')
}

Write-Host ''
Write-Host 'Tsuki V8 fixes applied.'
Write-Host 'Now run: cd app; dart format lib test; flutter analyze; flutter test'
