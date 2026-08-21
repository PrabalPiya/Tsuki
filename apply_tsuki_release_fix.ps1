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

# ---------------------------------------------------------------------------
# Library: Adult content is a separate mode, not an "include adult" switch.
# Hidden bookmarks remain persisted and reappear when the mode is switched.
# Visible bookmarks begin warming their chapter index immediately.
# ---------------------------------------------------------------------------
$libraryPath = Join-Path $root 'app\lib\features\library\presentation\library_screen.dart'
Patch-File -Path $libraryPath -Patch {
    param($text)

    if (-not $text.StartsWith("import 'dart:async';")) {
        $text = $text.Replace("import 'dart:ui';", "import 'dart:async';`r`nimport 'dart:ui';")
    }

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

    # Older builds filtered before adding to the in-memory list. Keep all
    # persisted bookmarks loaded and perform visibility filtering in the UI.
    $text = [regex]::Replace(
        $text,
        '(?s)if \(manga != null\) \{\s*repository\.remember\(manga\);\s*if \(manga\.isAdult == state\.adultContent\) \{\s*items\.add\(manga\);\s*\}\s*\}',
@'
if (manga != null) {
        repository.remember(manga);
        items.add(manga);
      }
'@,
        1
    )

    if (-not $text.Contains('repository.prewarmChapters(')) {
        $text = [regex]::Replace(
            $text,
            'repository\.remember\(manga\);\s*items\.add\(manga\);',
@'
repository.remember(manga);
        items.add(manga);
        if (manga.isAdult == state.adultContent) {
          unawaited(
            repository.prewarmChapters(
              manga,
              allowAdult: state.adultContent,
            ),
          );
        }
'@,
            1
        )
    }

    $text = $text.Replace(
        "title: const Text('Library'),",
        "title: Text(libraryState.adultContent ? 'Adult Library' : 'Library'),"
    )

    return $text
} -Validate {
    param($text)
    return $text.Contains('adultContent: value.adultContent') -and
           $text.Contains('manga.isAdult == libraryState.adultContent') -and
           $text.Contains("'Adult Library'") -and
           $text.Contains('repository.prewarmChapters(')
}

# ---------------------------------------------------------------------------
# Discover: clean four-chip metadata row, no duplicate lines below it, warmed
# chapter index before navigation, and encoding cleanup.
# ---------------------------------------------------------------------------
$discoverPath = Join-Path $root 'app\lib\features\discover\presentation\discover_screen.dart'
Patch-File -Path $discoverPath -Patch {
    param($text)

    if (-not $text.StartsWith("import 'dart:async';")) {
        $text = $text.Replace("import 'dart:ui';", "import 'dart:async';`r`nimport 'dart:ui';")
    }

    $text = $text.Replace('Preview Â· live rankings unavailable', 'Preview · live rankings unavailable')
    $text = [regex]::Replace(
        $text,
        "Swipe up for next[^']*down for previous",
        'Swipe up for next · down for previous'
    )

    # Remove the V11 identity/genre text rows; Genre now has its own fourth chip.
    $text = [regex]::Replace(
        $text,
        '(?s)\s*const SizedBox\(height: 8\),\s*Text\(\s*manga\.compactIdentityLabel,.*?const SizedBox\(height: 10\),\s*/\*\s*\* SYNOPSIS\s*\*/',
@'

                              const SizedBox(height: 12),

                              /*
                               * SYNOPSIS
                               */
'@
    )

    # Replace the existing 3-chip row with Rating / Status / Chapters / Genre.
    $chipPattern = '(?s)Row\(\s*children:\s*\[\s*Expanded\(\s*child: _InfoChip\(\s*icon: Icons\.star_rounded,\s*label: manga\.ratingLabel,\s*\),\s*\),\s*const SizedBox\(width: \d+(?:\.\d+)?\),\s*Expanded\(\s*child: _InfoChip\(\s*icon: Icons\.bolt_rounded,\s*label: manga\.statusLabel,\s*\),\s*\),\s*const SizedBox\(width: \d+(?:\.\d+)?\),\s*Expanded\(\s*child: _InfoChip\(\s*icon: Icons\.library_books_rounded,\s*label: ''\$chapterLabel chp'',\s*\),\s*\),\s*\],\s*\)'
    # PowerShell escaping around the interpolated Dart label is easier with a
    # broader bounded pattern keyed on the three icon names.
    $chipPattern = '(?s)Row\(\s*children:\s*\[\s*Expanded\(\s*child: _InfoChip\(\s*icon: Icons\.star_rounded,.*?icon: Icons\.bolt_rounded,.*?icon: Icons\.library_books_rounded,.*?\]\s*,?\s*\)'
    $chipReplacement = @'
Row(
                                children: [
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.star_rounded,
                                      label: manga.ratingLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.bolt_rounded,
                                      label: manga.statusLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.library_books_rounded,
                                      label: '$chapterLabel chp',
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Expanded(
                                    child: _InfoChip(
                                      icon: Icons.category_rounded,
                                      label: manga.genres.isEmpty
                                          ? '—'
                                          : manga.genres.first,
                                    ),
                                  ),
                                ],
                              )
'@
    $text = [regex]::Replace($text, $chipPattern, $chipReplacement, 1)

    # With the extra metadata lines removed, restore synopsis room.
    $text = [regex]::Replace(
        $text,
        '(textAlign:\s*TextAlign\.justify,\s*)maxLines:\s*3,',
        '$1maxLines: 4,',
        1
    )

    # Make the current card begin its chapter prewarm as soon as it is built.
    if (-not $text.Contains('final cardAdultMode = ref.watch(adultModeProvider);')) {
        $needle = '    final marked = ref.watch(userLibraryProvider).bookmarks.contains(manga.id);'
        $insert = @'
    final marked = ref.watch(userLibraryProvider).bookmarks.contains(manga.id);
    final cardAdultMode = ref.watch(adultModeProvider);
    unawaited(
      ref.read(catalogProvider).prewarmChapters(
            manga,
            allowAdult: cardAdultMode,
          ),
    );
'@.TrimEnd()
        $text = $text.Replace($needle, $insert)
    }

    # Never enter Details while this exact card still has a cold chapter index.
    $text = [regex]::Replace(
        $text,
        "onTap:\s*\(\)\s*\{\s*context\.push\('/manga/\$\{Uri\.encodeComponent\(manga\.id\)\}'\);\s*\},",
@'
onTap: () async {
                  await ref.read(catalogProvider).prewarmChapters(
                        manga,
                        allowAdult: cardAdultMode,
                      );
                  if (!context.mounted) return;
                  context.push('/manga/${Uri.encodeComponent(manga.id)}');
                },
'@,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )

    return $text
} -Validate {
    param($text)
    return $text.Contains('Icons.category_rounded') -and
           $text.Contains('final cardAdultMode = ref.watch(adultModeProvider);') -and
           $text.Contains('allowAdult: cardAdultMode') -and
           (-not $text.Contains('manga.compactIdentityLabel')) -and
           $text.Contains('Swipe up for next · down for previous')
}

# ---------------------------------------------------------------------------
# Details: strict mode guard, four clean metadata chips, and no chapter spinner.
# ---------------------------------------------------------------------------
$detailsPath = Join-Path $root 'app\lib\features\manga_details\presentation\manga_details_screen.dart'
Patch-File -Path $detailsPath -Patch {
    param($text)

    # Clean encoding artifacts left by earlier generated patches.
    $text = [regex]::Replace($text, "ellipsis:\s*'[^']*',", "ellipsis: '…',", 1)

    if (-not $text.Contains('This title is hidden in the current content mode.')) {
        $text = [regex]::Replace(
            $text,
            'final library = ref\.watch\(userLibraryProvider\);\s*final chaptersAsync = ref\.watch\(chapterProvider\(manga\)\);',
@'
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
'@,
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
    }

    # Remove V11 metadata text inserted between the chips and synopsis.
    $text = $text.Replace(
@'
        34 +
        42 +
        _heroInfoToSynopsisSpacing +
'@,
@'
        34 +
        _heroInfoToSynopsisSpacing +
'@
    )
    $text = [regex]::Replace(
        $text,
        '(?s)\s*const SizedBox\(height: 9\),\s*Text\(\s*manga\.compactIdentityLabel,.*?const SizedBox\(height: _heroInfoToSynopsisSpacing\),',
@'

                const SizedBox(height: _heroInfoToSynopsisSpacing),
'@
    )

    # Replace the hero's three chips with four compact equal-width chips.
    $chipPattern = '(?s)Row\(\s*children:\s*\[\s*Expanded\(\s*child: _InfoChip\(\s*icon: Icons\.star_rounded,.*?icon: Icons\.bolt_rounded,.*?icon: Icons\.library_books_rounded,.*?\]\s*,?\s*\)'
    $chipReplacement = @'
Row(
                  children: [
                    Expanded(
                      child: _InfoChip(
                        icon: Icons.star_rounded,
                        label: manga.ratingLabel,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _InfoChip(
                        icon: Icons.bolt_rounded,
                        label: manga.statusLabel,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _InfoChip(
                        icon: Icons.library_books_rounded,
                        label: '$chapterCountLabel chp',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _InfoChip(
                        icon: Icons.category_rounded,
                        label: manga.genres.isEmpty ? '—' : manga.genres.first,
                      ),
                    ),
                  ],
                )
'@
    $text = [regex]::Replace($text, $chipPattern, $chipReplacement, 1)

    # If prewarming and local-cache hydration are racing for a frame, do not
    # show a chapter loading screen/spinner. The stream will paint the list as
    # soon as the warmed index is emitted.
    $text = [regex]::Replace(
        $text,
        '(?s)loading:\s*\(\)\s*\{\s*return SliverToBoxAdapter\(.*?CircularProgressIndicator\(\).*?\);\s*\},\s*error:',
@'
loading: () => const SliverToBoxAdapter(
              child: SizedBox(height: 1),
            ),

            error:
'@,
        1
    )

    $text = $text.Replace(
        "message: 'No English chapters available from the configured sources.',",
@'
message: library.adultContent
                            ? 'No directly readable adult chapters were found from the supported public sources for this title.'
                            : 'No English chapters available from the configured sources.',
'@.TrimEnd()
    )

    return $text
} -Validate {
    param($text)
    return $text.Contains('This title is hidden in the current content mode.') -and
           $text.Contains('Icons.category_rounded') -and
           (-not $text.Contains('manga.compactIdentityLabel')) -and
           $text.Contains('SizedBox(height: 1)')
}

# Remove obsolete patch helpers so there is only one release path.
$legacyPatch = Join-Path $root 'apply_tsuki_v11_fix.ps1'
if (Test-Path $legacyPatch) { Remove-Item -Force $legacyPatch }

Write-Host ''
Write-Host 'Tsuki release UI integration patches applied.'
Write-Host 'Now run: cd app; flutter pub get; dart format lib test; flutter analyze; flutter test'
