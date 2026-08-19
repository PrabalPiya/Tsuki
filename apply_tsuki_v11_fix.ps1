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

# MangaDex: make Adult content mode reach MangaDex adult ratings.
$mangaDexPath = Join-Path $root 'app\lib\features\reader\data\mangadex_source.dart'
Patch-File -Path $mangaDexPath -Patch {
    param($text)

    if (-not $text.Contains('required bool allowAdult,')) {
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
    }

    $text = $text.Replace('includeAdult: canonical.isAdult,', 'includeAdult: canonical.isAdult || allowAdult,')
    return $text
} -Validate {
    param($text)
    return $text.Contains('includeAdult: canonical.isAdult || allowAdult,') -and
           $text.Contains('required bool allowAdult,')
}

# Library: strict mode separation. Both bookmark sets remain persisted.
$libraryPath = Join-Path $root 'app\lib\features\library\presentation\library_screen.dart'
Patch-File -Path $libraryPath -Patch {
    param($text)

    if (-not $text.Contains('adultContent: value.adultContent')) {
        $text = [regex]::Replace(
            $text,
            '\(value\) =>\s*\(bookmarks: value\.bookmarks, bookmarkedManga: value\.bookmarkedManga\),',
@'
(value) => (
        bookmarks: value.bookmarks,
        bookmarkedManga: value.bookmarkedManga,
        adultContent: value.adultContent,
      ),
'@,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
    }

    $text = $text.Replace(
        '.where((manga) => libraryState.adultContent || !manga.isAdult)',
        '.where((manga) => manga.isAdult == libraryState.adultContent)'
    )

    # Keep both bookmark sets loaded in memory; visibility is controlled only
    # by the strict mode filter below. This preserves hidden-mode data and lets
    # the empty-state message distinguish hidden bookmarks from no bookmarks.
    $text = $text.Replace(
@'
      if (manga != null) {
        repository.remember(manga);
        if (manga.isAdult == state.adultContent) {
          items.add(manga);
        }
      }
'@,
@'
      if (manga != null) {
        repository.remember(manga);
        items.add(manga);
      }
'@
    )

    $text = $text.Replace(
        "title: const Text('Library'),",
        "title: Text(libraryState.adultContent ? 'Adult Library' : 'Library'),"
    )

    $text = [regex]::Replace(
        $text,
        "if \(items\.isEmpty && allItems\.isNotEmpty && !libraryState\.adultContent\) \{.*?\n    \}",
@'
if (items.isEmpty && allItems.isNotEmpty) {
      return _LibraryMessage(
        icon: Icons.visibility_off_rounded,
        title: libraryState.adultContent
            ? 'No adult bookmarks in this mode'
            : 'Adult bookmarks hidden',
        message: libraryState.adultContent
            ? 'Your normal bookmarks remain saved and return when Adult content is turned off.'
            : 'Your adult bookmarks remain saved and return when Adult content is turned on.',
      );
    }
'@,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    return $text
} -Validate {
    param($text)
    return $text.Contains('adultContent: value.adultContent') -and
           $text.Contains('manga.isAdult == libraryState.adultContent') -and
           $text.Contains("'Adult Library'")
}

# Discover: strict adult/normal title and reset card position when mode changes.
$discoverPath = Join-Path $root 'app\lib\features\discover\presentation\discover_screen.dart'
Patch-File -Path $discoverPath -Patch {
    param($text)

    if (-not $text.Contains('final adultMode = ref.watch(')) {
        $needle = '    final ranking = ref.watch(rankingsProvider(RankingPeriod.values[_period]));'
        $insert = @'
    final adultMode = ref.watch(adultModeProvider);

    ref.listen<bool>(adultModeProvider, (previous, next) {
      if (previous != null && previous != next) {
        _resetDiscover();
      }
    });

'@
        $text = $text.Replace($needle, $insert + $needle)
    } else {
        $modePattern = [regex]::new(
            'final adultMode = ref\.watch\([\s\S]*?\);',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        $text = $modePattern.Replace(
            $text,
            'final adultMode = ref.watch(adultModeProvider);',
            1
        )
    }

    $text = $text.Replace(
        "title: const Text('Discover'),",
        "title: Text(adultMode ? 'Adult Discover' : 'Discover'),"
    )
    $text = [regex]::Replace(
        $text,
        "'Preview[^']*live rankings unavailable'",
        "'Preview · live rankings unavailable'"
    )

    # The two new metadata lines take space previously used by the synopsis.
    # Keep the card balanced on small phones instead of letting content collide
    # with the bookmark action.
    $text = $text.Replace(
        '                                maxLines: 4,',
        '                                maxLines: 3,'
    )

    if (-not $text.Contains('manga.compactIdentityLabel')) {
        $pattern = '(?s)\s*const SizedBox\(height: 12\),\s*/\*\s*\* SYNOPSIS\s*\*/'
        $replacement = @'

                              const SizedBox(height: 8),

                              Text(
                                manga.compactIdentityLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.muted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),

                              if (manga.displayGenres.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  manga.displayGenres.take(2).join(' • '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.muted,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],

                              const SizedBox(height: 10),

                              /*
                               * SYNOPSIS
                               */
'@
        $text = [regex]::Replace($text, $pattern, $replacement, 1)
    }
    return $text
} -Validate {
    param($text)
    return $text.Contains('adultModeProvider') -and
           $text.Contains("adultMode ? 'Adult Discover' : 'Discover'") -and
           $text.Contains('manga.compactIdentityLabel')
}

# Details: a title from the other mode cannot remain visible through a route.
# Empty adult source results stop showing an endless finding state and explain
# that no directly readable public source matched the title.
$detailsPath = Join-Path $root 'app\lib\features\manga_details\presentation\manga_details_screen.dart'
Patch-File -Path $detailsPath -Patch {
    param($text)

    if (-not $text.Contains('This title is hidden in the current content mode.')) {
        $needle = "    final library = ref.watch(userLibraryProvider);`r`n`r`n    final chaptersAsync = ref.watch(chapterProvider(manga));"
        if (-not $text.Contains($needle)) {
            $needle = "    final library = ref.watch(userLibraryProvider);`n`n    final chaptersAsync = ref.watch(chapterProvider(manga));"
        }
        $replacement = @'
    final library = ref.watch(userLibraryProvider);

    if (manga.isAdult != library.adultContent) {
      return Scaffold(
        body: _ModernMessage(
          icon: Icons.visibility_off_rounded,
          message: 'This title is hidden in the current content mode.',
          retryLabel: 'Go Back',
          onRetry: () {
            if (context.canPop()) context.pop();
          },
        ),
      );
    }

    final chaptersAsync = ref.watch(chapterProvider(manga));
'@.TrimEnd()
        $text = $text.Replace($needle, $replacement)
    }

    $text = $text.Replace(
        "message: 'No English chapters available from the configured sources.',",
@'
message: library.adultContent
                            ? 'No directly readable adult chapters were found from the supported public sources for this title.'
                            : 'No English chapters available from the configured sources.',
'@.TrimEnd()
    )

    if (-not $text.Contains('manga.popularityLabel')) {
        $text = $text.Replace(
@'
        _heroTitleToInfoSpacing +
        34 +
        _heroInfoToSynopsisSpacing +
'@,
@'
        _heroTitleToInfoSpacing +
        34 +
        42 +
        _heroInfoToSynopsisSpacing +
'@
        )

        $needle = '                const SizedBox(height: _heroInfoToSynopsisSpacing),'
        $insert = @'
                const SizedBox(height: 9),

                Text(
                  manga.compactIdentityLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .82),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  <String>[
                    if (manga.volumeCount > 0) '${manga.volumeCount} volumes',
                    if ((manga.popularity ?? 0) > 0)
                      'Popularity ${manga.popularityLabel}',
                    ...manga.displayGenres.take(2),
                  ].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: .70),
                    fontSize: 11,
                  ),
                ),

                const SizedBox(height: _heroInfoToSynopsisSpacing),
'@
        $text = $text.Replace($needle, $insert.TrimEnd())
    }
    return $text
} -Validate {
    param($text)
    return $text.Contains('This title is hidden in the current content mode.') -and
           $text.Contains('No directly readable adult chapters were found') -and
           $text.Contains('manga.popularityLabel')
}

Write-Host ''
Write-Host 'Tsuki V11 UI/source integration patches applied.'
Write-Host 'Now run: cd app; dart format lib test; flutter analyze; flutter test'
