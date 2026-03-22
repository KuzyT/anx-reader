import 'dart:convert';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/translation_cache.dart';
import 'package:anx_reader/enums/convert_chinese_mode.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/enums/reading_info.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/enums/translation_level.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/enums/code_highlight_theme.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/page/settings_page/subpage/fonts.dart';
import 'package:anx_reader/widgets/common/anx_segmented_button.dart';
import 'package:anx_reader/widgets/reading_page/ai_status_overlay.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

class ReadingMoreSettings extends StatefulWidget {
  const ReadingMoreSettings({super.key});

  @override
  State<ReadingMoreSettings> createState() => _ReadingMoreSettingsState();
}

enum ClearCacheScope { page, chapter, book }

class _ReadingMoreSettingsState extends State<ReadingMoreSettings> {
  static const String _wordWiseCacheLevel = 'word_wise';
  static const String _wordWiseWordCacheLevel = 'word_wise_words';
  static const String _useGlobalLangCode = '__global__';
  static final RegExp _wordTokenPattern = RegExp(
    r"[A-Za-zÀ-ÖØ-öø-ÿĀ-žЀ-ӿ]+(?:['’-][A-Za-zÀ-ÖØ-öø-ÿĀ-žЀ-ӿ]+)*",
  );
  static final RegExp _japaneseKanaPattern = RegExp(r'[\u3040-\u30ff]');
  static final RegExp _hangulPattern = RegExp(r'[\uac00-\ud7af]');
  static final RegExp _cjkPattern = RegExp(r'[\u4e00-\u9fff]');
  static final RegExp _traditionalHintPattern =
      RegExp(r'[體學國書門開語讀麼這為過還會點對裡畫萬與關時後來]');
  static final RegExp _cyrillicPattern = RegExp(r'[\u0400-\u04FF]');
  static final RegExp _ukrainianHintPattern = RegExp(r'[іїєґ]');
  static final RegExp _greekPattern = RegExp(r'[\u0370-\u03ff]');
  static final RegExp _arabicPattern = RegExp(r'[\u0600-\u06ff]');
  static final RegExp _devanagariPattern = RegExp(r'[\u0900-\u097f]');
  static final RegExp _tamilPattern = RegExp(r'[\u0b80-\u0bff]');
  static final RegExp _teluguPattern = RegExp(r'[\u0c00-\u0c7f]');
  static final RegExp _thaiPattern = RegExp(r'[\u0e00-\u0e7f]');

  static const Map<LangListEnum, Set<String>> _latinStopWords = {
    LangListEnum.english: {
      'the',
      'and',
      'of',
      'to',
      'in',
      'that',
      'is',
      'for',
      'with',
      'you',
      'was',
      'are',
    },
    LangListEnum.spanish: {
      'el',
      'la',
      'de',
      'que',
      'y',
      'en',
      'los',
      'las',
      'un',
      'una',
      'para',
      'con',
    },
    LangListEnum.french: {
      'le',
      'la',
      'les',
      'de',
      'des',
      'et',
      'en',
      'un',
      'une',
      'pour',
      'avec',
      'que',
    },
    LangListEnum.german: {
      'der',
      'die',
      'das',
      'und',
      'ist',
      'ein',
      'eine',
      'mit',
      'nicht',
      'den',
      'von',
      'zu',
    },
    LangListEnum.italian: {
      'il',
      'la',
      'di',
      'e',
      'che',
      'un',
      'una',
      'per',
      'con',
      'non',
      'del',
      'della',
    },
    LangListEnum.portuguese: {
      'de',
      'que',
      'e',
      'o',
      'a',
      'do',
      'da',
      'em',
      'um',
      'uma',
      'com',
      'para',
      'não',
      'nao',
    },
  };

  static const Set<String> _ptBrMarkers = {
    'você',
    'vocês',
    'ônibus',
    'trem',
    'celular',
    'legal',
    'cara',
  };

  static const Set<String> _ptPtMarkers = {
    'tu',
    'autocarro',
    'comboio',
    'telemóvel',
    'telemovel',
    'facto',
    'fixe',
    'rapariga',
  };

  final isReading =
      epubPlayerKey.currentState != null && epubPlayerKey.currentState!.mounted;

  List<String> _extractWordCacheKeys(List<String> texts) {
    final keys = <String>{};
    for (final text in texts) {
      for (final match in _wordTokenPattern.allMatches(text)) {
        final token = (match.group(0) ?? '').trim().toLowerCase();
        if (token.isNotEmpty) {
          keys.add(token);
        }
      }
    }
    return keys.toList();
  }

  int _countWordHits(List<String> words, Set<String> markers) {
    var score = 0;
    for (final word in words) {
      if (markers.contains(word)) score++;
    }
    return score;
  }

  LangListEnum _resolvePortugueseVariant(String lowerText, List<String> words) {
    var brScore = _countWordHits(words, _ptBrMarkers);
    var ptScore = _countWordHits(words, _ptPtMarkers);

    if (lowerText.contains('a gente')) {
      brScore += 2;
    }
    if (lowerText.contains('vocês') || lowerText.contains('voces')) {
      brScore += 1;
    }
    if (lowerText.contains('vocês')) {
      ptScore += 1;
    }

    if (brScore == 0 && ptScore == 0) {
      return LangListEnum.portuguese;
    }
    if (brScore >= ptScore + 1) {
      return LangListEnum.portugueseBrazil;
    }
    if (ptScore >= brScore + 1) {
      return LangListEnum.portuguesePortugal;
    }
    return LangListEnum.portuguese;
  }

  LangListEnum? _detectSourceLanguageFromText(String rawText) {
    final text = rawText.trim();
    if (text.length < 24) return null;

    if (_japaneseKanaPattern.hasMatch(text)) return LangListEnum.japanese;
    if (_hangulPattern.hasMatch(text)) return LangListEnum.korean;
    if (_greekPattern.hasMatch(text)) return LangListEnum.greek;
    if (_arabicPattern.hasMatch(text)) return LangListEnum.arabic;
    if (_devanagariPattern.hasMatch(text)) return LangListEnum.hindi;
    if (_tamilPattern.hasMatch(text)) return LangListEnum.tamil;
    if (_teluguPattern.hasMatch(text)) return LangListEnum.telugu;
    if (_thaiPattern.hasMatch(text)) return LangListEnum.thai;

    if (_cyrillicPattern.hasMatch(text)) {
      final lowerCyr = text.toLowerCase();
      if (_ukrainianHintPattern.hasMatch(lowerCyr)) {
        return LangListEnum.ukrainian;
      }
      return LangListEnum.russian;
    }

    if (_cjkPattern.hasMatch(text)) {
      if (_traditionalHintPattern.hasMatch(text)) {
        return LangListEnum.traditionalChinese;
      }
      return LangListEnum.simplifiedChinese;
    }

    final lower = text.toLowerCase();
    final words = _wordTokenPattern
        .allMatches(lower)
        .map((m) => (m.group(0) ?? '').trim().toLowerCase())
        .where((w) => w.length >= 2)
        .toList();
    if (words.length < 6) return null;

    final scores = <LangListEnum, int>{};
    for (final entry in _latinStopWords.entries) {
      scores[entry.key] = _countWordHits(words, entry.value);
    }

    LangListEnum? bestLang;
    var bestScore = 0;
    var secondScore = 0;
    for (final entry in scores.entries) {
      final score = entry.value;
      if (score > bestScore) {
        secondScore = bestScore;
        bestScore = score;
        bestLang = entry.key;
      } else if (score > secondScore) {
        secondScore = score;
      }
    }

    if (bestLang == null || bestScore < 2) return null;
    if (bestScore == secondScore) return null;

    if (bestLang == LangListEnum.portuguese) {
      return _resolvePortugueseVariant(lower, words);
    }
    return bestLang;
  }

  Future<LangListEnum?> _detectSourceLanguageForCurrentBook() async {
    final text = await epubPlayerKey.currentState?.theChapterContent() ?? '';
    if (text.trim().isEmpty) return null;
    return _detectSourceLanguageFromText(text);
  }

  Future<void> _refreshInterlinearView() async {
    await epubPlayerKey.currentState?.webViewController.evaluateJavascript(
      source: '''
(() => {
  const reader = window.reader;
  const translator = reader && reader.view && reader.view.translator;
  if (translator && typeof translator.retranslateAll === 'function') {
    translator.retranslateAll();
  }
})()
''',
    );
  }

  Future<int> _clearBookTranslationCacheAndRefresh(int bookId) async {
    final count = await translationCacheDao.clearForBook(bookId);
    await _refreshInterlinearView();
    return count;
  }

  Future<void> _showClearCacheDialog() async {
    final bookId = epubPlayerKey.currentState!.widget.book.id;
    final currentLevelEnum = Prefs().translationLevel;
    final isWordLevel = currentLevelEnum != TranslationLevelEnum.full;
    final currentLevelDbKey = isWordLevel ? _wordWiseCacheLevel : 'full';
    final displayLevelName =
        isWordLevel ? 'Word-by-word' : currentLevelEnum.displayName;

    ClearCacheScope scope = ClearCacheScope.page;
    bool currentLevelOnly = true;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(L10n.of(context).translationClearCacheTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<ClearCacheScope>(
                    title:
                        Text(L10n.of(context).translationClearCacheCurrentPage),
                    value: ClearCacheScope.page,
                    groupValue: scope,
                    onChanged: (v) => setDialogState(() => scope = v!),
                  ),
                  RadioListTile<ClearCacheScope>(
                    title: Text(
                        L10n.of(context).translationClearCacheCurrentChapter),
                    value: ClearCacheScope.chapter,
                    groupValue: scope,
                    onChanged: (v) => setDialogState(() => scope = v!),
                  ),
                  RadioListTile<ClearCacheScope>(
                    title:
                        Text(L10n.of(context).translationClearCacheWholeBook),
                    value: ClearCacheScope.book,
                    groupValue: scope,
                    onChanged: (v) => setDialogState(() => scope = v!),
                  ),
                  const Divider(),
                  SwitchListTile(
                    title: Text(L10n.of(context)
                        .translationClearCacheOnlyLevel(displayLevelName)),
                    value: currentLevelOnly,
                    onChanged: (v) =>
                        setDialogState(() => currentLevelOnly = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(L10n.of(context).commonCancel),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await _confirmClearCache(bookId, scope,
                        currentLevelOnly ? currentLevelDbKey : null);
                  },
                  child: Text(
                    L10n.of(context).storageClearCache,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmClearCache(
      int bookId, ClearCacheScope scope, String? level) async {
    List<String>? originals;

    if (scope == ClearCacheScope.page || scope == ClearCacheScope.chapter) {
      final jsMethod = scope == ClearCacheScope.page
          ? '''
(() => {
  const reader = window.reader;
  const translator = reader && reader.view && reader.view.translator;
  if (!translator || typeof translator.getVisibleOriginalTexts !== 'function') {
    return [];
  }
  return translator.getVisibleOriginalTexts() || [];
})()
'''
          : '''
(() => {
  const reader = window.reader;
  const translator = reader && reader.view && reader.view.translator;
  if (!translator || typeof translator.getChapterOriginalTexts !== 'function') {
    return [];
  }
  return translator.getChapterOriginalTexts() || [];
})()
''';

      final result = await epubPlayerKey.currentState?.webViewController
          .evaluateJavascript(source: jsMethod);

      if (result != null) {
        try {
          final decoded = result is String ? jsonDecode(result) : result;
          if (decoded is List) {
            originals = decoded.map((e) => e.toString()).toList();
          }
        } catch (e) {
          debugPrint('Error parsing JS result for clear cache: $result \n $e');
        }
      }

      // CRITICAL: If we failed to get originals for a restrictive scope,
      // ABORT to avoid clearing the whole book.
      if (originals == null || originals.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(L10n.of(context).translationClearCacheResolveTextError),
            backgroundColor: Colors.red,
          ));
        }
        return;
      }
    }

    var totalCount = await translationCacheDao.clearSpecific(bookId,
        level: level, originals: originals);

    final shouldClearWordCache = level == _wordWiseCacheLevel ||
        (level == null && scope != ClearCacheScope.book);
    if (shouldClearWordCache) {
      if (scope == ClearCacheScope.book) {
        // For whole-book "current level only" in word-wise mode:
        // clear both sentence cache and dedicated per-word cache.
        final extra = await translationCacheDao.clearSpecific(
          bookId,
          level: _wordWiseWordCacheLevel,
        );
        totalCount += extra;
      } else {
        final sourceTexts = originals ?? const <String>[];
        final wordKeys = _extractWordCacheKeys(sourceTexts);
        if (wordKeys.isNotEmpty) {
          final extra = await translationCacheDao.clearSpecific(
            bookId,
            level: _wordWiseWordCacheLevel,
            originals: wordKeys,
          );
          totalCount += extra;
        }
      }
    }

    // Refresh UI: trigger re-translation observation in WebView
    await _refreshInterlinearView();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(L10n.of(context).translationClearCacheSuccess(totalCount)),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget convertChinese() {
      const iconStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);
      return StatefulBuilder(
        builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.of(context).readingPageConvertChinese,
                  style: Theme.of(context).textTheme.titleMedium),
              Row(
                children: [
                  Expanded(
                    child: AnxSegmentedButton<ConvertChineseMode>(
                      segments: [
                        SegmentButtonItem(
                          label: L10n.of(context).readingPageOriginal,
                          value: ConvertChineseMode.none,
                          icon: const Text("原", style: iconStyle),
                        ),
                        SegmentButtonItem(
                          label: L10n.of(context).readingPageSimplified,
                          value: ConvertChineseMode.t2s,
                          icon: const Text("简", style: iconStyle),
                        ),
                        SegmentButtonItem(
                          label: L10n.of(context).readingPageTraditional,
                          value: ConvertChineseMode.s2t,
                          icon: const Text("繁", style: iconStyle),
                        ),
                      ],
                      selected: {Prefs().readingRules.convertChineseMode},
                      onSelectionChanged: (value) {
                        setState(() {
                          // Prefs().readingRules.convertChineseMode =
                          //     ConvertChineseMode.values.byName(value.first);
                          Prefs().readingRules = Prefs()
                              .readingRules
                              .copyWith(convertChineseMode: value.first);
                          epubPlayerKey.currentState
                              ?.changeReadingRules(Prefs().readingRules);
                        });
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Icon(Icons.error_outline),
                  Expanded(
                    child: Text(
                      L10n.of(context).readingPageConvertChineseTips,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    }

    // Widget bionicReading() {
    //   return StatefulBuilder(
    //     builder: (context, setState) => ListTile(
    //       contentPadding: EdgeInsets.zero,
    //       title: Text(L10n.of(context).readingPageBionicReading,
    //           style: Theme.of(context).textTheme.titleMedium),
    //       subtitle: GestureDetector(
    //         child: Text(
    //           textAlign: TextAlign.start,
    //           L10n.of(context).readingPageBionicReadingTips,
    //           style: const TextStyle(
    //             fontSize: 12,
    //             color: Color(0xFF666666),
    //             decoration: TextDecoration.underline,
    //           ),
    //         ),
    //         onTap: () {
    //           launchUrl(
    //             Uri.parse('https://github.com/Anxcye/anx-reader/issues/49'),
    //             mode: LaunchMode.externalApplication,
    //           );
    //         },
    //       ),
    //       trailing: Switch(
    //         value: Prefs().readingRules.bionicReading,
    //         onChanged: (value) {
    //           setState(() {
    //             Prefs().readingRules =
    //                 Prefs().readingRules.copyWith(bionicReading: value);
    //             epubPlayerKey.currentState?
    //                 .changeReadingRules(Prefs().readingRules);
    //           });
    //         },
    //       ),
    //     ),
    //   );
    // }

    Widget columnCount() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.of(context).readingPageColumnCount,
                style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                Expanded(
                  child: AnxSegmentedButton<int>(
                    segments: [
                      SegmentButtonItem(
                        label: L10n.of(context).readingPageAuto,
                        value: 0,
                        icon: const Icon(Icons.auto_awesome),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context).readingPageSingle,
                        value: 1,
                        icon: const Icon(EvaIcons.book),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context).readingPageDouble,
                        value: 2,
                        icon: const Icon(EvaIcons.book_open),
                      ),
                    ],
                    selected: {Prefs().bookStyle.maxColumnCount},
                    onSelectionChanged: (value) {
                      setState(() {
                        final newBookStyle = Prefs()
                            .bookStyle
                            .copyWith(maxColumnCount: value.first);
                        Prefs().saveBookStyleToPrefs(newBookStyle);
                        epubPlayerKey.currentState?.changeStyle(newBookStyle);
                      });
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget columnThreshold() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(L10n.of(context).readingPageColumnThreshold,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '${Prefs().bookStyle.columnThreshold.toInt()}px',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (Prefs().bookStyle.maxColumnCount == 0)
              Text(
                L10n.of(context).readingPageColumnThresholdTip,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
              ),
            Slider(
              value: Prefs().bookStyle.columnThreshold,
              min: 400,
              max: 1200,
              divisions: 40,
              label: '${Prefs().bookStyle.columnThreshold.toInt()}px',
              onChanged: Prefs().bookStyle.maxColumnCount == 0
                  ? (value) {
                      setState(() {
                        final newBookStyle =
                            Prefs().bookStyle.copyWith(columnThreshold: value);
                        Prefs().saveBookStyleToPrefs(newBookStyle);
                        epubPlayerKey.currentState?.changeStyle(newBookStyle);
                      });
                    }
                  : null,
            ),
          ],
        ),
      );
    }

    Widget writingMode() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.of(context).readingPageWritingDirection,
                style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                Expanded(
                  child: AnxSegmentedButton<WritingModeEnum>(
                    segments: [
                      SegmentButtonItem(
                        label: L10n.of(context).readingPageWritingDirectionAuto,
                        value: WritingModeEnum.auto,
                        icon: const Icon(EvaIcons.activity_outline),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context)
                            .readingPageWritingDirectionVertical,
                        value: WritingModeEnum.verticalRl,
                        icon: const Icon(Bootstrap.arrows_vertical),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context)
                            .readingPageWritingDirectionHorizontal,
                        value: WritingModeEnum.horizontalTb,
                        icon: const Icon(Bootstrap.arrows),
                      ),
                    ],
                    selected: {Prefs().writingMode},
                    onSelectionChanged: (value) {
                      setState(() {
                        final newBookStyle =
                            Prefs().bookStyle.copyWith(maxColumnCount: 1);
                        Prefs().saveBookStyleToPrefs(newBookStyle);
                        Prefs().writingMode = value.first;
                        epubPlayerKey.currentState?.changeStyle(newBookStyle);
                      });
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget translationMode() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(L10n.of(context).translationMode,
                style: Theme.of(context).textTheme.titleMedium),
            if (!isReading)
              Text(L10n.of(context).readingPageTranslationModeTip,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
            Row(
              children: [
                Expanded(
                  child: AnxSegmentedButton<TranslationModeEnum>(
                    enabled: isReading,
                    segments: [
                      SegmentButtonItem(
                        label: L10n.of(context).readingPageOriginal,
                        value: TranslationModeEnum.off,
                        icon: const Icon(Icons.translate_outlined),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context).translationOnly,
                        value: TranslationModeEnum.translationOnly,
                        icon: const Icon(Icons.g_translate),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context).bilingual,
                        value: TranslationModeEnum.bilingual,
                        icon: const Icon(Icons.compare),
                      ),
                      SegmentButtonItem(
                        label: L10n.of(context).translationInterlinearShort,
                        value: TranslationModeEnum.interlinear,
                        icon: const Icon(Icons.format_line_spacing),
                      ),
                    ],
                    selected: {
                      epubPlayerKey.currentState != null
                          ? Prefs().getBookTranslationMode(
                              epubPlayerKey.currentState!.widget.book.id)
                          : TranslationModeEnum.off
                    },
                    onSelectionChanged: (value) {
                      setState(() {
                        final currentBookId =
                            epubPlayerKey.currentState!.widget.book.id;
                        final newMode = value.first;

                        Prefs().setBookTranslationMode(currentBookId, newMode);

                        epubPlayerKey.currentState?.setTranslationMode(newMode);
                      });
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget buildInfoDropdown(
      BuildContext context,
      String label,
      ReadingInfoEnum currentValue,
      Function(ReadingInfoEnum) onChanged,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          DropdownButton<ReadingInfoEnum>(
            isDense: true,
            isExpanded: true,
            value: currentValue,
            onChanged: (value) {
              if (value != null) {
                onChanged(value);
              }
            },
            underline: Container(),
            dropdownColor: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
            items: ReadingInfoEnum.values.map((info) {
              return DropdownMenuItem<ReadingInfoEnum>(
                value: info,
                child: Text(
                  info.getL10n(context),
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
          ),
        ],
      );
    }

    Widget readingInfo() {
      return StatefulBuilder(
        builder: (context, setState) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                L10n.of(context).readingPageHeaderSettings,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageLeft,
                      Prefs().readingInfo.headerLeft,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                headerLeft: value,
                              );
                          Prefs().readingInfo = newRules;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageCenter,
                      Prefs().readingInfo.headerCenter,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                headerCenter: value,
                              );
                          Prefs().readingInfo = newRules;
                          // epubPlayerKey.currentState
                          //     ?.changeReadingInfo(newRules);
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageRight,
                      Prefs().readingInfo.headerRight,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                headerRight: value,
                              );
                          Prefs().readingInfo = newRules;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(L10n.of(context).readingSettingsMargin),
                  Expanded(
                    child: Slider(
                      value: Prefs().pageHeaderMargin.toDouble(),
                      min: 0,
                      max: 80,
                      divisions: 40,
                      label: Prefs().pageHeaderMargin.toStringAsFixed(0),
                      onChanged: (value) {
                        setState(() {
                          Prefs().pageHeaderMargin = value;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                ],
              ),
              const Divider(),
              Text(L10n.of(context).readingPageFooterSettings,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageLeft,
                      Prefs().readingInfo.footerLeft,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                footerLeft: value,
                              );
                          Prefs().readingInfo = newRules;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageCenter,
                      Prefs().readingInfo.footerCenter,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                footerCenter: value,
                              );
                          Prefs().readingInfo = newRules;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: buildInfoDropdown(
                      context,
                      L10n.of(context).readingPageRight,
                      Prefs().readingInfo.footerRight,
                      (value) {
                        setState(() {
                          final newRules = Prefs().readingInfo.copyWith(
                                footerRight: value,
                              );
                          Prefs().readingInfo = newRules;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(L10n.of(context).readingSettingsMargin),
                  Expanded(
                    child: Slider(
                      value: Prefs().pageFooterMargin.toDouble(),
                      min: 0,
                      max: 80,
                      divisions: 40,
                      label: Prefs().pageFooterMargin.toStringAsFixed(0),
                      onChanged: (value) {
                        setState(() {
                          // final newRules = Prefs().readingInfo.copyWith(
                          //       headerFontSize: value.toInt(),
                          //     );
                          // Prefs().readingInfo = newRules;
                          // epubPlayerKey.currentState?.changeReadingInfo();
                          Prefs().pageFooterMargin = value;
                          epubPlayerKey.currentState?.changeReadingInfo();
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    }

    Widget downloadFonts() {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(L10n.of(context).downloadFonts),
        leading: const Icon(Icons.font_download_outlined),
        trailing: const Icon(Icons.arrow_forward_ios),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const FontsSettingPage(),
            ),
          );
        },
      );
    }

    Widget codeHighlightTheme() {
      return StatefulBuilder(
        builder: (context, setState) {
          final lightThemes = [
            CodeHighlightThemeEnum.defaultTheme,
            CodeHighlightThemeEnum.github,
            CodeHighlightThemeEnum.oneLight,
            CodeHighlightThemeEnum.materialLight,
          ];

          final darkThemes = [
            CodeHighlightThemeEnum.vsDark,
            CodeHighlightThemeEnum.oneDark,
            CodeHighlightThemeEnum.dracula,
            CodeHighlightThemeEnum.materialDark,
            CodeHighlightThemeEnum.nord,
            CodeHighlightThemeEnum.nightOwl,
            CodeHighlightThemeEnum.solarizedDark,
            CodeHighlightThemeEnum.atomDark,
          ];

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(L10n.of(context).codeHighlightTheme,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              // Quick toggle: Off / Light / Dark
              Row(
                children: [
                  Expanded(
                    child: AnxSegmentedButton<String>(
                      segments: [
                        SegmentButtonItem(
                          label: L10n.of(context).codeHighlightOff,
                          value: 'off',
                          icon: const Icon(Icons.code_off),
                        ),
                        SegmentButtonItem(
                          label: L10n.of(context).codeHighlightLight,
                          value: 'light',
                          icon: const Icon(Icons.light_mode),
                        ),
                        SegmentButtonItem(
                          label: L10n.of(context).codeHighlightDark,
                          value: 'dark',
                          icon: const Icon(Icons.dark_mode),
                        ),
                      ],
                      selected: {
                        Prefs().codeHighlightTheme == CodeHighlightThemeEnum.off
                            ? 'off'
                            : Prefs().codeHighlightTheme.isLight
                                ? 'light'
                                : 'dark'
                      },
                      onSelectionChanged: (value) {
                        setState(() {
                          if (value.first == 'off') {
                            Prefs().codeHighlightTheme =
                                CodeHighlightThemeEnum.off;
                          } else if (value.first == 'light') {
                            Prefs().codeHighlightTheme =
                                CodeHighlightThemeEnum.defaultTheme;
                          } else {
                            Prefs().codeHighlightTheme =
                                CodeHighlightThemeEnum.vsDark;
                          }
                          epubPlayerKey.currentState?.changeStyle(null);
                        });
                      },
                    ),
                  ),
                ],
              ),
              // Detailed theme selection (only show if not off)
              if (Prefs().codeHighlightTheme != CodeHighlightThemeEnum.off) ...[
                const SizedBox(height: 16),
                // Light themes section
                if (Prefs().codeHighlightTheme.isLight) ...[
                  Text(L10n.of(context).codeHighlightLightThemes,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: lightThemes.map((theme) {
                      final isSelected = Prefs().codeHighlightTheme == theme;
                      return ChoiceChip(
                        label: Text(theme.displayName),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              Prefs().codeHighlightTheme = theme;
                              epubPlayerKey.currentState?.changeStyle(null);
                            });
                          }
                        },
                      );
                    }).toList(),
                  ),
                ],
                // Dark themes section
                if (Prefs().codeHighlightTheme.isDark) ...[
                  Text(L10n.of(context).codeHighlightDarkThemes,
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: darkThemes.map((theme) {
                      final isSelected = Prefs().codeHighlightTheme == theme;
                      return ChoiceChip(
                        label: Text(theme.displayName),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              Prefs().codeHighlightTheme = theme;
                              epubPlayerKey.currentState?.changeStyle(null);
                            });
                          }
                        },
                      );
                    }).toList(),
                  ),
                ],
              ],
            ],
          );
        },
      );
    }

    Widget aiBatchSizeWidget() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(L10n.of(context).translationAiBatchSize,
                    style: Theme.of(context).textTheme.titleMedium),
                Text('${Prefs().aiBatchSize}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            Slider(
              value: Prefs().aiBatchSize.toDouble(),
              min: 5,
              max: 50,
              divisions: 9,
              label: '${Prefs().aiBatchSize}',
              onChanged: (value) {
                setState(() {
                  Prefs().aiBatchSize = value.toInt();
                  epubPlayerKey.currentState?.setAiBatchSize(value.toInt());
                });
              },
            ),
          ],
        ),
      );
    }

    Widget aiWorkersWidget() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('AI Workers', // TODO: move to L10n
                    style: Theme.of(context).textTheme.titleMedium),
                Text('${Prefs().aiTranslateWorkers}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            Slider(
              value: Prefs().aiTranslateWorkers.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${Prefs().aiTranslateWorkers}',
              onChanged: (value) {
                setState(() {
                  Prefs().aiTranslateWorkers = value.toInt();
                  epubPlayerKey.currentState?.setAiWorkers(value.toInt());
                });
              },
            ),
          ],
        ),
      );
    }

    Widget showAiTranslationStatusWidget() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(L10n.of(context).translationAiStatusLogsTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton.icon(
                      onPressed: () => showAiTranslationLogsModal(context),
                      icon: const Icon(Icons.receipt_long, size: 16),
                      label: Text(L10n.of(context).translationLogsShort),
                    ),
                    Switch(
                      value: Prefs().showAiTranslationStatus,
                      onChanged: (value) {
                        setState(() {
                          Prefs().showAiTranslationStatus = value;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget translationLevel() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Text(L10n.of(context).translationLevelLabel,
                style: Theme.of(context).textTheme.titleMedium),
            if (!isReading)
              Text(L10n.of(context).translationOnlyWhileReading,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.grey)),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<TranslationLevelEnum>(
                    isExpanded: true,
                    value: Prefs().translationLevel,
                    underline: Container(),
                    dropdownColor:
                        Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                    items: TranslationLevelEnum.values.map((level) {
                      return DropdownMenuItem<TranslationLevelEnum>(
                        value: level,
                        child: Text(level.displayName),
                      );
                    }).toList(),
                    onChanged: isReading
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                Prefs().translationLevel = value;
                                epubPlayerKey.currentState
                                    ?.setTranslationLevel(value);
                              });
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    Widget translationColorsWidget() {
      return StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Colorize Translation Levels', // TODO: L10n
                    style: Theme.of(context).textTheme.titleMedium),
                Switch(
                  value: Prefs().translationColorEnabled,
                  onChanged: (val) {
                    setState(() {
                      Prefs().translationColorEnabled = val;
                      epubPlayerKey.currentState?.setTranslationColors(
                        Prefs().translationColorEnabled,
                        jsonEncode(Prefs().translationLevelColors),
                      );
                    });
                  },
                ),
              ],
            ),
            if (Prefs().translationColorEnabled)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...['0', 'a1', 'a2', 'b1', 'b2', 'c1', 'c2'].map((level) {
                    final colors = Prefs().translationLevelColors;
                    final hexString = colors[level] ?? '#000000';
                    final colorInt =
                        int.tryParse(hexString.replaceFirst('#', '0xff')) ??
                            0xff000000;
                    final color = Color(colorInt);

                    return GestureDetector(
                      onTap: () {
                        showDialog(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('Select color for $level'),
                            content: SingleChildScrollView(
                              child: BlockPicker(
                                pickerColor: color,
                                onColorChanged: (newColor) {
                                  setState(() {
                                    final newHexStr =
                                        '#${newColor.value.toRadixString(16).substring(2).toUpperCase()}';
                                    final newColors = Map<String, String>.from(
                                        Prefs().translationLevelColors);
                                    newColors[level] = newHexStr;
                                    Prefs().translationLevelColors = newColors;
                                    epubPlayerKey.currentState
                                        ?.setTranslationColors(
                                      Prefs().translationColorEnabled,
                                      jsonEncode(
                                          Prefs().translationLevelColors),
                                    );
                                  });
                                },
                              ),
                            ),
                            actions: [
                              TextButton(
                                child: const Text('Close'),
                                onPressed: () => Navigator.of(ctx).pop(),
                              ),
                            ],
                          ),
                        );
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.grey),
                        ),
                        child: Center(
                          child: Text(
                            level.toUpperCase(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    );
                  }),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () {
                      setState(() {
                        Prefs().translationLevelColors = {
                          "0": "#2D2D2D",
                          "a1": "#1A7A3C",
                          "a2": "#1A7575",
                          "b1": "#1655A8",
                          "b2": "#6B1FA8",
                          "c1": "#8F4700",
                          "c2": "#A81A1A"
                        };
                        epubPlayerKey.currentState?.setTranslationColors(
                          Prefs().translationColorEnabled,
                          jsonEncode(Prefs().translationLevelColors),
                        );
                      });
                    },
                    tooltip: 'Reset colors',
                  )
                ],
              ),
          ],
        ),
      );
    }

    Widget clearTranslationCacheButton() {
      if (epubPlayerKey.currentState == null) return const SizedBox.shrink();

      return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _showClearCacheDialog(),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(L10n.of(context).translationClearCacheTitle),
            ),
          ),
        ],
      );
    }

    Future<void> showInterlinearSettingsDialog() async {
      final playerState = epubPlayerKey.currentState;
      if (playerState == null) return;

      final bookId = playerState.widget.book.id;
      var selectedSourceCode =
          Prefs().getBookInterlinearSourceLangOverride(bookId)?.code ??
              _useGlobalLangCode;
      var isDetecting = false;
      var globalAiRefineEnabled = Prefs().aiRefineWordLevelsGlobal;
      var bookAiRefineMode = Prefs().getBookAiRefineWordLevelsMode(bookId);

      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final globalFrom =
                  Prefs().fullTextTranslateFrom.getNative(context);

              return SafeArea(
                child: FractionallySizedBox(
                  heightFactor: 0.9,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Interlinear Translation Settings',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Source language for this book',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        DropdownButton<String>(
                          isExpanded: true,
                          value: selectedSourceCode,
                          underline: Container(),
                          dropdownColor:
                              Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                          items: [
                            DropdownMenuItem(
                              value: _useGlobalLangCode,
                              child: Text('Use global ($globalFrom)'),
                            ),
                            ...LangListEnum.values.map((lang) {
                              return DropdownMenuItem(
                                value: lang.code,
                                child: Text(lang.getNative(context)),
                              );
                            }),
                          ],
                          onChanged: (nextValue) async {
                            if (nextValue == null ||
                                nextValue == selectedSourceCode) {
                              return;
                            }

                            setDialogState(
                                () => selectedSourceCode = nextValue);
                            if (nextValue == _useGlobalLangCode) {
                              Prefs().setBookInterlinearSourceLangOverride(
                                  bookId, null);
                            } else {
                              Prefs().setBookInterlinearSourceLangOverride(
                                  bookId, getLang(nextValue));
                            }

                            final cleared =
                                await _clearBookTranslationCacheAndRefresh(
                                    bookId);
                            if (!mounted || !dialogContext.mounted) return;

                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(L10n.of(context)
                                  .translationClearCacheSuccess(cleared)),
                              duration: const Duration(seconds: 2),
                            ));
                            setState(() {});
                          },
                        ),
                        const SizedBox(height: 6),
                        FilledButton.tonalIcon(
                          onPressed: isDetecting
                              ? null
                              : () async {
                                  setDialogState(() => isDetecting = true);
                                  final detected =
                                      await _detectSourceLanguageForCurrentBook();
                                  if (!mounted || !dialogContext.mounted) {
                                    return;
                                  }

                                  setDialogState(() => isDetecting = false);
                                  if (detected == null) {
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(const SnackBar(
                                      content: Text(
                                          'Could not detect source language from the current chapter.'),
                                      duration: Duration(seconds: 2),
                                    ));
                                    return;
                                  }

                                  Prefs().setBookInterlinearSourceLangOverride(
                                      bookId, detected);
                                  setDialogState(
                                      () => selectedSourceCode = detected.code);

                                  final cleared =
                                      await _clearBookTranslationCacheAndRefresh(
                                          bookId);
                                  if (!mounted || !dialogContext.mounted) {
                                    return;
                                  }

                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                          'Detected: ${detected.getNative(context)}. ${L10n.of(context).translationClearCacheSuccess(cleared)}'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  setState(() {});
                                },
                          icon: isDetecting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome),
                          label: Text(isDetecting
                              ? 'Detecting...'
                              : 'Auto detect from current chapter'),
                        ),
                        const SizedBox(height: 8),
                        const Divider(height: 20),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                              'AI refine levels for non-AI translation (global)'),
                          value: globalAiRefineEnabled,
                          onChanged: (value) {
                            setDialogState(() => globalAiRefineEnabled = value);
                            Prefs().aiRefineWordLevelsGlobal = value;
                            setState(() {});
                          },
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Per-book override',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        DropdownButton<String>(
                          isExpanded: true,
                          value: bookAiRefineMode,
                          underline: Container(),
                          dropdownColor:
                              Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                          items: const [
                            DropdownMenuItem(
                              value: 'inherit',
                              child: Text('Use global'),
                            ),
                            DropdownMenuItem(
                              value: 'enabled',
                              child: Text('Only for this book (enabled)'),
                            ),
                            DropdownMenuItem(
                              value: 'disabled',
                              child: Text('Disable for this book'),
                            ),
                          ],
                          onChanged: (nextValue) {
                            if (nextValue == null) return;
                            setDialogState(() => bookAiRefineMode = nextValue);
                            Prefs()
                                .setBookAiRefineWordLevelsMode(bookId, nextValue);
                            setState(() {});
                          },
                        ),
                        const SizedBox(height: 8),
                        const Divider(height: 20),
                        translationLevel(),
                        translationColorsWidget(),
                        showAiTranslationStatusWidget(),
                        aiBatchSizeWidget(),
                        aiWorkersWidget(),
                        const SizedBox(height: 8),
                        clearTranslationCacheButton(),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    }

    return Container(
      padding: const EdgeInsets.all(18.0),
      child: Column(
        children: [
          downloadFonts(),
          const Divider(height: 20),
          writingMode(),
          translationMode(),
          if (epubPlayerKey.currentState != null &&
              Prefs().getBookTranslationMode(
                      epubPlayerKey.currentState!.widget.book.id) ==
                  TranslationModeEnum.interlinear) ...[
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showInterlinearSettingsDialog(),
                  icon: const Icon(Icons.tune),
                  label: const Text('Interlinear settings'),
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              'Level, colors, source language, workers, cache',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Colors.grey),
            ),
          ],
          columnCount(),
          columnThreshold(),
          convertChinese(),
          const Divider(height: 15),
          codeHighlightTheme(),
          const Divider(height: 15),
          readingInfo(),
          // const Divider(height: 8),
          // bionicReading(),
        ],
      ),
    );
  }
}
