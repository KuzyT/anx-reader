import 'dart:async';
import 'dart:convert';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'dart:ui';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/dao/translation_cache.dart';
import 'package:anx_reader/dao/vocabulary.dart';
import 'package:anx_reader/enums/page_turn_mode.dart';
import 'package:anx_reader/enums/reading_info.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/enums/translation_level.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/models/font_model.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/models/reading_rules.dart';
import 'package:anx_reader/models/search_result_model.dart';
import 'package:anx_reader/models/toc_item.dart';
import 'package:anx_reader/page/book_player/image_viewer.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/book_toc.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/ai.dart';
import 'package:anx_reader/service/translate/word_wise.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/service/ai_translation_status_service.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/tts_factory.dart';
import 'package:anx_reader/service/tts/system_tts.dart';
import 'package:anx_reader/service/tts/online_tts.dart';
import 'package:anx_reader/service/tts/tts_service.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/service/tts/models/tts_sentence.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/utils/coordinates_to_part.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/js/convert_dart_color_to_js.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:anx_reader/utils/webView/webview_console_message.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/context_menu/context_menu.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/diagram.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/types_and_icons.dart';
import 'package:anx_reader/widgets/reading_page/style_widget.dart';
import 'package:anx_reader/widgets/reading_page/vocabulary_word_dialog.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsx_plus/iconsx_plus.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:url_launcher/url_launcher.dart';

import 'minute_clock.dart';

class EpubPlayer extends ConsumerStatefulWidget {
  final Book book;
  final String? cfi;
  final Function showOrHideAppBarAndBottomBar;
  final Function onLoadEnd;
  final List<ReadTheme> initialThemes;
  final Function updateParent;

  const EpubPlayer(
      {super.key,
      required this.showOrHideAppBarAndBottomBar,
      required this.book,
      this.cfi,
      required this.onLoadEnd,
      required this.initialThemes,
      required this.updateParent});

  @override
  ConsumerState<EpubPlayer> createState() => EpubPlayerState();
}

class _WordSegment {
  final String rawText;
  final String? normalizedWord;

  const _WordSegment._(this.rawText, this.normalizedWord);

  const _WordSegment.text(String value) : this._(value, null);
  const _WordSegment.word(String value, String normalized)
      : this._(value, normalized);

  bool get isWord => normalizedWord != null;
}

class _WordWiseNonAiResult {
  final Map<String, String> sentenceTranslations;
  final Map<String, _WordCacheEntry> wordCacheUpdates;
  final Set<String> wordsNeedingLevelRefine;

  const _WordWiseNonAiResult({
    required this.sentenceTranslations,
    required this.wordCacheUpdates,
    required this.wordsNeedingLevelRefine,
  });
}

class _WordCacheEntry {
  final String translation;
  final String? level;

  const _WordCacheEntry({
    required this.translation,
    required this.level,
  });
}

class EpubPlayerState extends ConsumerState<EpubPlayer>
    with TickerProviderStateMixin {
  late InAppWebViewController webViewController;
  late ContextMenu contextMenu;
  String cfi = '';
  double percentage = 0.0;
  String chapterTitle = '';
  String chapterHref = '';
  int chapterCurrentPage = 0;
  int chapterTotalPages = 0;
  OverlayEntry? contextMenuEntry;
  AnimationController? _animationController;
  Animation<double>? _animation;
  bool showHistory = false;
  bool canGoBack = false;
  bool canGoForward = false;
  late Book book;
  String? backgroundColor;
  String? textColor;
  Timer? styleTimer;
  String bookmarkCfi = '';
  bool bookmarkExists = false;
  WritingModeEnum writingMode = WritingModeEnum.horizontalTb;
  String? _lastSelectionContextText;
  bool _selectionClearLocked = false;
  bool _selectionClearPending = false;

  // Scroll wheel debounce
  Timer? _scrollDebounceTimer;
  double _accumulatedScrollDelta = 0;
  static const double _scrollThreshold = 50.0;

  // Semaphore for N concurrent translation workers
  static int _activeTranslationWorkers = 0;
  static int get _maxTranslationWorkers => Prefs().aiTranslateWorkers;
  static final _translationWaitQueue = <Completer<void>>[];
  static const String _wordWiseCacheLevel = 'word_wise';
  static const String _wordWiseWordCacheLevel = 'word_wise_words';
  static final RegExp _wordTokenPattern = wordWiseTokenPattern;
  static final RegExp _wordHasLetterPattern =
      RegExp(r'[\p{L}\p{N}]', unicode: true);
  static const Set<String> _validCefrLevels = {
    '0',
    'a1',
    'a2',
    'b1',
    'b2',
    'c1',
    'c2',
  };
  final Set<int> _activeWordLevelRefineBooks = <int>{};
  final Map<int, Set<String>> _pendingWordLevelRefineWords = {};

  void _aiDebugLog(String message) {
    if (EnvVar.enableAiConsoleLogs) {
      debugPrint(message);
    }
  }

  String _clipStatusPayload(String payload, {int maxLength = 4000}) {
    if (payload.length <= maxLength) return payload;
    final kept = payload.substring(0, maxLength);
    return '$kept\n... [truncated ${payload.length - maxLength} chars]';
  }

  LangListEnum _resolveBookSourceLanguage([int? bookId]) {
    final targetBookId = bookId ?? widget.book.id;
    final override = Prefs().getBookInterlinearSourceLangOverride(targetBookId);
    return override ?? Prefs().fullTextTranslateFrom;
  }

  String _cacheLevel(String format,
          {LangListEnum? from, LangListEnum? to, TranslateService? service}) =>
      translationCacheLevel(
          format,
          (from ?? _resolveBookSourceLanguage()).code,
          (to ?? Prefs().fullTextTranslateTo).code,
          (service ?? Prefs().fullTextTranslateService).name);

  Future<Map<String, String>> _readCachedTranslations(
      int bookId, String key, List<String> texts,
      {required bool wordWise}) async {
    final cached =
        await translationCacheDao.getTranslations(bookId, key, texts);
    cached.removeWhere((text, value) {
      if (isTranslationFailure(value)) return true;
      if (!wordWise) return false;
      final parsed = WordWiseText(text, value);
      return !parsed.sourceMatches || parsed.missingWords.isNotEmpty;
    });
    if (wordWise && cached.isNotEmpty) {
      final words = cached.keys
          .expand((text) => wordWiseTokenPattern.allMatches(text))
          .map((match) => _normalizeWordForCache(match[0]!))
          .toSet()
          .toList();
      final raw = await translationCacheDao.getTranslations(
          bookId, key.replaceFirst('word_wise:', 'word_wise_words:'), words);
      final levels = <String, String>{};
      for (final entry in raw.entries) {
        final level = _decodeWordCacheEntry(entry.value).level;
        if (level != null) levels[entry.key] = level;
      }
      for (final entry in cached.entries.toList()) {
        cached[entry.key] =
            WordWiseText(entry.key, entry.value).withLevels(levels).markedText;
      }
    }
    return cached;
  }

  // to know anytime if we are on top of navigation stack
  bool get _isTopOfNavigationStack =>
      ModalRoute.of(context)?.isCurrent ?? false;

  void prevPage() {
    webViewController.evaluateJavascript(source: '''
      if (typeof clearSelection === 'function') { clearSelection(); }
      prevPage();
      ''');
  }

  void nextPage() {
    webViewController.evaluateJavascript(source: '''
      if (typeof clearSelection === 'function') { clearSelection(); }
      nextPage();
      ''');
  }

  void prevChapter() {
    webViewController.evaluateJavascript(source: '''
      prevSection()
      ''');
  }

  void nextChapter() {
    webViewController.evaluateJavascript(source: '''
      nextSection()
      ''');
  }

  void setTranslationMode(TranslationModeEnum mode) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setTranslationMode) {
        reader.view.setTranslationMode('${mode.code}');
      }
      ''');
  }

  void setTranslationLevel(TranslationLevelEnum level) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setTranslationLevel) {
        reader.view.setTranslationLevel('${level.code}');
      }
      ''');
  }

  void setAiBatchSize(int size) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setAiBatchSize) {
        reader.view.setAiBatchSize($size);
      }
      ''');
  }

  void setAiWorkers(int n) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setAiWorkers) {
        reader.view.setAiWorkers($n);
      }
      ''');
  }

  void setTranslationColors(bool enabled, String colorsJson) {
    webViewController.evaluateJavascript(source: '''
      if (typeof reader.view !== 'undefined' && reader.view.setTranslationColors) {
        reader.view.setTranslationColors($enabled, '$colorsJson');
      }
      ''');
  }

  void _applyTranslationSettings() {
    unawaited(refreshVocabulary());
    setTranslationLevel(Prefs().translationLevel);
    setAiBatchSize(Prefs().aiBatchSize);
    setAiWorkers(Prefs().aiTranslateWorkers);
    setTranslationMode(Prefs().getBookTranslationMode(widget.book.id));
    setTranslationColors(Prefs().translationColorEnabled,
        jsonEncode(Prefs().translationLevelColors));
  }

  Future<void> refreshVocabulary() async {
    final source = _resolveBookSourceLanguage();
    try {
      final statuses = source == LangListEnum.auto
          ? <String, String>{}
          : await vocabularyDao.statuses(source.code);
      if (!mounted || source != _resolveBookSourceLanguage()) return;
      await webViewController.evaluateJavascript(
          source:
              'if (typeof reader !== "undefined" && reader.view?.setVocabularyStatuses) reader.view.setVocabularyStatuses(${jsonEncode(statuses)});');
    } catch (error) {
      AnxLog.warning('Could not refresh vocabulary: $error');
    }
  }

  bool _vocabularyDialogOpen = false;

  Future<void> _openVocabularyWord(List<dynamic> args) async {
    if (!mounted ||
        !_isTopOfNavigationStack ||
        _vocabularyDialogOpen ||
        args.isEmpty ||
        args.first is! Map) {
      return;
    }
    final payload = args.first as Map;
    String? text(String key, int limit) {
      final value = payload[key];
      return value is String && value.length <= limit ? value : null;
    }

    final word = text('word', 240),
        translation = text('translation', 2000),
        contextText = text('contextText', 12000),
        position = text('cfi', 2048);
    if (word == null ||
        word.trim().isEmpty ||
        translation == null ||
        contextText == null ||
        position == null) {
      return;
    }
    _vocabularyDialogOpen = true;
    removeOverlay();
    try {
      final source = await showVocabularyWordDialog(context,
          book: widget.book,
          word: word,
          translation: translation,
          contextText: contextText,
          chapter: chapterTitle,
          cfi: position,
          sourceLanguage: _resolveBookSourceLanguage(),
          targetLanguage: Prefs().fullTextTranslateTo, onSpeak: () async {
        await audioHandler.stop();
        final tts = TtsFactory().current;
        if (tts is SystemTts) {
          await tts.speakWithVoice(
              word, SystemTtsProvider().resolveVoice(null));
        } else if (tts is OnlineTts) {
          await tts.speakWithVoice(word, tts.backend.resolveVoice(null));
        }
      },
          onExplain: EnvVar.enableAIFeature
              ? (source, target) => AiTranslateProvider.classifyInBackground(
                  () => AiTranslateProvider().translateTextOnly(
                      word, source, target,
                      contextText: contextText, ref: ref))
              : null);
      if (source != null && mounted) {
        Prefs().setBookInterlinearSourceLangOverride(widget.book.id, source);
        await refreshVocabulary();
      }
    } finally {
      _vocabularyDialogOpen = false;
      if (mounted) restoreReaderFocus();
    }
  }

  Future<void> addVocabularySelection(String word, String position) async {
    if (word.trim().isEmpty || word.length > 240) {
      AnxToast.show(L10n.of(context).vocabularySelectionTooLong);
      return;
    }
    final originalContext = _lastSelectionContextText ?? word;
    await _openVocabularyWord([
      {
        'word': word.trim(),
        'translation': '',
        'contextText': originalContext,
        'cfi': position
      }
    ]);
  }

  Future<void> goToPercentage(double value) async {
    await webViewController.evaluateJavascript(source: '''
      goToPercent($value); 
      ''');
  }

  void setSelectionClearLocked(bool locked) {
    _selectionClearLocked = locked;
    if (!locked && _selectionClearPending) {
      _selectionClearPending = false;
      _lastSelectionContextText = null;
      removeOverlay();
      restoreReaderFocus();
    }
  }

  void restoreReaderFocus() {
    readingPageKey.currentState?.requestReaderFocus();
  }

  void changeTheme(ReadTheme readTheme) {
    textColor = readTheme.textColor;
    backgroundColor = readTheme.backgroundColor;

    String bc = convertDartColorToJs(readTheme.backgroundColor);
    String tc = convertDartColorToJs(readTheme.textColor);

    webViewController.evaluateJavascript(source: '''
      changeStyle({
        backgroundColor: '#$bc',
        fontColor: '#$tc',
      })
      ''');
  }

  void changeStyle(BookStyle? bookStyle) {
    styleTimer?.cancel();
    String bgimgUrl = Prefs().bgimg.getEffectiveUrl(
          isDarkMode: isDarkMode,
          autoAdjust: Prefs().autoAdjustReadingTheme,
        );

    styleTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      BookStyle style = bookStyle ?? Prefs().bookStyle;
      webViewController.evaluateJavascript(source: '''
      changeStyle({
        fontSize: ${style.fontSize},
        spacing: ${style.lineHeight},
        fontWeight: ${style.fontWeight},
        paragraphSpacing: ${style.paragraphSpacing},
        topMargin: ${style.topMargin},
        bottomMargin: ${style.bottomMargin},
        sideMargin: ${style.sideMargin},
        letterSpacing: ${style.letterSpacing},
        textIndent: ${style.indent},
        maxColumnCount: ${style.maxColumnCount},
        columnThreshold: ${style.columnThreshold},
        writingMode: '${Prefs().writingMode.code}',
        textAlign: '${Prefs().textAlignment.code}',
        backgroundImage: '$bgimgUrl',
        bgimgBlur: ${Prefs().bgimg.blur},
        bgimgOpacity: ${Prefs().bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
        customCSS: `${Prefs().customCSS.replaceAll('`', '\\`')}`,
        customCSSEnabled: ${Prefs().customCSSEnabled},
        useBookStyles: ${Prefs().useBookStyles},
        headingFontSize: ${style.headingFontSize},
        codeHighlightTheme: '${Prefs().codeHighlightTheme.code}',
      })
      ''');
    });
  }

  void changeBgimgEffect() {
    if (!mounted) return;
    final bgimg = Prefs().bgimg;
    final bgimgUrl = bgimg.getEffectiveUrl(
      isDarkMode: isDarkMode,
      autoAdjust: Prefs().autoAdjustReadingTheme,
    );
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        backgroundImage: '$bgimgUrl',
        bgimgBlur: ${bgimg.blur},
        bgimgOpacity: ${bgimg.opacity},
        bgimgFit: '${Prefs().bgimgFit.code}',
      })
    ''');
  }

  void changeReadingRules(ReadingRules readingRules) {
    webViewController.evaluateJavascript(source: '''
      readingFeatures({
        convertChineseMode: '${readingRules.convertChineseMode.name}',
        bionicReadingMode: ${readingRules.bionicReading},
      })
    ''');
  }

  void changeFont(FontModel font) {
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        fontName: '${font.name}',
        fontPath: '${font.path}',
      })
    ''');
  }

  void changePageTurnStyle(PageTurn pageTurnStyle) {
    webViewController.evaluateJavascript(source: '''
      changeStyle({
        pageTurnStyle: '${pageTurnStyle.name}',
      })
    ''');
  }

  void goToHref(String href) =>
      webViewController.evaluateJavascript(source: "goToHref('$href')");

  void goToCfi(String cfi) => webViewController.evaluateJavascript(
      source: 'goToCfi(${jsonEncode(cfi)})');

  void addAnnotation(BookNote bookNote) {
    final noteContent =
        (bookNote.content).replaceAll('\n', ' ').replaceAll("'", "\\'");
    webViewController.evaluateJavascript(source: '''
      addAnnotation({
        id: ${bookNote.id},
        type: '${bookNote.type}',
        value: '${bookNote.cfi}',
        color: '#${bookNote.color}',
        note: '$noteContent',
      })
      ''');
  }

  void addBookmark(BookmarkModel bookmark) {
    webViewController.evaluateJavascript(source: '''
      addAnnotation({
        id: ${bookmark.id},
        type: 'bookmark',
        value: '${bookmark.cfi}',
        color: '#000000',
        note: 'None',
      })
      ''');
  }

  void addBookmarkHere() {
    webViewController.evaluateJavascript(source: '''
      addBookmarkHere()
      ''');
  }

  void removeAnnotation(String cfi) =>
      webViewController.evaluateJavascript(source: "removeAnnotation('$cfi')");

  void clearSearch() {
    ref.read(tocSearchProvider.notifier).clear();
    _clearSearchHighlights();
  }

  void search(String text) {
    final sanitized = text.trim();
    if (sanitized.isEmpty) {
      clearSearch();
      return;
    }
    _clearSearchHighlights();
    ref.read(tocSearchProvider.notifier).start(sanitized);
    webViewController.evaluateJavascript(source: '''
      search('$sanitized', {
        'scope': 'book',
        'matchCase': false,
        'matchDiacritics': false,
        'matchWholeWords': false,
      })
    ''');
  }

  Future<void> runAiBookSearch(String keyword) async {
    ref.read(tocSearchProvider.notifier).start(keyword);
    final escaped = jsonEncode(keyword);
    await webViewController.evaluateJavascript(source: 'clearSearch()');
    await webViewController.evaluateJavascript(
      source:
          'search($escaped, {"scope":"book","matchCase":false,"matchDiacritics":false,"matchWholeWords":false})',
    );
  }

  void _clearSearchHighlights() {
    webViewController.evaluateJavascript(source: "clearSearch()");
  }

  Future<void> initTts({String? fromCfi}) async {
    if (fromCfi != null && fromCfi.isNotEmpty) {
      await webViewController.evaluateJavascript(
          source: "window.ttsFromCfi('$fromCfi')");
    } else {
      await webViewController.evaluateJavascript(source: "window.ttsHere()");
    }
  }

  void ttsStop() => webViewController.evaluateJavascript(source: "ttsStop()");

  Future<String> ttsNext() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsNext()"))
      ?.value;

  Future<String> ttsPrev() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsPrev()"))
      ?.value;

  Future<String> ttsPrevSection() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsPrevSection()"))
      ?.value;

  Future<String> ttsNextSection() async => (await webViewController
          .callAsyncJavaScript(functionBody: "return await ttsNextSection()"))
      ?.value;

  Future<String> ttsPrepare() async =>
      (await webViewController.evaluateJavascript(source: "ttsPrepare()"));

  TtsSentence? _parseTtsSentence(dynamic value) {
    if (value is Map<dynamic, dynamic>) {
      try {
        return TtsSentence.fromMap(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  List<TtsSentence> _parseTtsSentences(dynamic value) {
    if (value is! List) return const [];

    final sentences = <TtsSentence>[];
    for (final item in value) {
      final sentence = _parseTtsSentence(item);
      if (sentence != null) {
        sentences.add(sentence);
      }
    }
    return sentences;
  }

  Future<TtsSentence?> ttsCurrentDetail() async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsCurrentDetail()',
    );
    return _parseTtsSentence(result?.value);
  }

  Future<List<TtsSentence>> ttsCollectDetails({
    required int count,
    bool includeCurrent = false,
    int offset = 1,
  }) async {
    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return ttsCollectDetails($count, ${includeCurrent ? 'true' : 'false'}, $offset)',
    );
    return _parseTtsSentences(result?.value);
  }

  Future<void> ttsHighlightByCfi(String cfi) async {
    await webViewController.callAsyncJavaScript(
      functionBody: 'return ttsHighlightByCfi(${jsonEncode(cfi)})',
    );
  }

  Future<bool> isFootNoteOpen() async => (await webViewController
      .evaluateJavascript(source: "window.isFootNoteOpen()"));

  void backHistory() {
    webViewController.evaluateJavascript(source: "back()");
  }

  void forwardHistory() {
    webViewController.evaluateJavascript(source: "forward()");
  }

  void refreshToc() {
    webViewController.evaluateJavascript(source: "refreshToc()");
  }

  Future<String> theChapterContent() async =>
      await webViewController.evaluateJavascript(
        source: "theChapterContent()",
      );

  Future<String> previousContent(int count) async =>
      await webViewController.evaluateJavascript(
        source: "previousContent($count)",
      );

  Future<String> _getCurrentChapterContent({int? maxCharacters}) async {
    final raw = await theChapterContent();
    return _normalizeChapterContent(raw, maxCharacters);
  }

  Future<String> _getChapterContentByHref(
    String href, {
    int? maxCharacters,
  }) async {
    if (href.isEmpty) {
      return '';
    }

    final result = await webViewController.callAsyncJavaScript(
      functionBody:
          'return await getChapterContentByHref("${href.replaceAll('"', '\\"')}")',
    );

    final value = result?.value;
    if (value is String) {
      return _normalizeChapterContent(value, maxCharacters);
    }
    return '';
  }

  String _normalizeChapterContent(String? content, int? maxCharacters) {
    if (content == null || content.isEmpty) {
      return '';
    }
    final trimmed = content.trim();
    if (maxCharacters != null &&
        maxCharacters > 0 &&
        trimmed.length > maxCharacters) {
      return trimmed.substring(0, maxCharacters);
    }
    return trimmed;
  }

  void _registerChapterContentBridge() {
    ref.read(chapterContentBridgeProvider.notifier).state =
        ChapterContentHandlers(
      fetchCurrentChapter: ({int? maxCharacters}) =>
          _getCurrentChapterContent(maxCharacters: maxCharacters),
      fetchChapterByHref: (href, {int? maxCharacters}) =>
          _getChapterContentByHref(href, maxCharacters: maxCharacters),
    );
  }

  Future<void> _handleExternalLink(dynamic rawLink) async {
    String? normalizeExternalLink(dynamic raw) {
      if (raw == null) {
        return null;
      }
      if (raw is String && raw.trim().isNotEmpty) {
        return raw.trim();
      }
      if (raw is Map && raw['href'] is String) {
        final href = raw['href'].toString().trim();
        return href.isEmpty ? null : href;
      }
      return null;
    }

    final link = normalizeExternalLink(rawLink);
    if (!mounted || link == null) {
      return;
    }

    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme.isEmpty || uri.scheme == 'javascript') {
      AnxLog.warning('Ignored invalid external link: $link');
      return;
    }

    final shouldOpen = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = L10n.of(dialogContext);
        return AlertDialog(
          title: Text(l10n.readingPageOpenExternalLinkTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.readingPageOpenExternalLinkMessage),
              const SizedBox(height: 8),
              SelectableText(link),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.readingPageOpenExternalLinkAction),
            ),
          ],
        );
      },
    );

    if (shouldOpen != true) {
      return;
    }

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened) {
      AnxLog.warning('Failed to open external link: $link');
    }
  }

  void onClick(Map<String, dynamic> location) {
    readingPageKey.currentState?.resetAwakeTimer();
    if (contextMenuEntry != null) {
      removeOverlay();
      return;
    }
    final x = location['x'];
    final y = location['y'];
    final part = coordinatesToPart(x, y);

    PageTurningType action;
    final pageTurnMode = PageTurnMode.fromCode(Prefs().pageTurnMode);

    if (pageTurnMode == PageTurnMode.simple) {
      // Use predefined page turning types
      final currentPageTurningType = Prefs().pageTurningType;
      final pageTurningType = pageTurningTypes[currentPageTurningType];
      action = pageTurningType[part];

      // Apply swap if enabled
      if (Prefs().swapPageTurnArea) {
        if (action == PageTurningType.prev) {
          action = PageTurningType.next;
        } else if (action == PageTurningType.next) {
          action = PageTurningType.prev;
        }
      }
    } else {
      // Use custom configuration
      final customConfig = Prefs().customPageTurnConfig;
      action = PageTurningType.values[customConfig[part]];
    }

    // Disable mouse/touch page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      // Only allow menu action, disable prev/next page turning
      if (action == PageTurningType.prev || action == PageTurningType.next) {
        return;
      }
    }

    switch (action) {
      case PageTurningType.prev:
        prevPage();
        break;
      case PageTurningType.next:
        nextPage();
        break;
      case PageTurningType.menu:
        widget.showOrHideAppBarAndBottomBar(true);
        break;
      case PageTurningType.none:
        break;
    }
  }

  Future<void> renderAnnotations(InAppWebViewController controller) async {
    List<BookNote> annotationList =
        await bookNoteDao.selectBookNotesByBookId(widget.book.id);
    String allAnnotations =
        jsonEncode(annotationList.map((e) => e.toJson()).toList())
            .replaceAll('\'', '\\\'');
    controller.evaluateJavascript(source: '''
     const allAnnotations = $allAnnotations
     renderAnnotations()
    ''');
  }

  void getThemeColor() {
    if (Prefs().autoAdjustReadingTheme) {
      List<ReadTheme> themes = widget.initialThemes;
      final isDayMode =
          Theme.of(navigatorKey.currentContext!).brightness == Brightness.light;
      backgroundColor =
          isDayMode ? themes[0].backgroundColor : themes[1].backgroundColor;
      textColor = isDayMode ? themes[0].textColor : themes[1].textColor;
    } else {
      backgroundColor = Prefs().readTheme.backgroundColor;
      textColor = Prefs().readTheme.textColor;
    }
  }

  String _normalizeWordForCache(String word) => vocabularyWordKey(word);

  _WordCacheEntry _decodeWordCacheEntry(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return const _WordCacheEntry(translation: '', level: null);
    }

    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          final translation = (decoded['t'] ?? '').toString();
          final rawLevel = decoded['l']?.toString();
          final normalizedLevel = rawLevel == null
              ? null
              : _normalizeCefrLevel(rawLevel, allowNull: true);
          return _WordCacheEntry(
            translation: translation,
            level: normalizedLevel,
          );
        }
      } catch (_) {}
    }

    // Backward compatibility: legacy cache stored only translation string.
    return _WordCacheEntry(translation: trimmed, level: null);
  }

  String _encodeWordCacheEntry(_WordCacheEntry entry) {
    return jsonEncode({
      't': entry.translation,
      'l': entry.level,
    });
  }

  Map<String, String> _encodeWordCacheUpdates(
      Map<String, _WordCacheEntry> entries) {
    final encoded = <String, String>{};
    for (final entry in entries.entries) {
      encoded[entry.key] = _encodeWordCacheEntry(entry.value);
    }
    return encoded;
  }

  bool _shouldTranslateWord(String normalizedWord) {
    if (normalizedWord.isEmpty) return false;
    return _wordHasLetterPattern.hasMatch(normalizedWord);
  }

  List<_WordSegment> _tokenizeWordSegments(String text) {
    if (text.isEmpty) return const [];

    final segments = <_WordSegment>[];
    var lastEnd = 0;

    for (final match in _wordTokenPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        segments.add(_WordSegment.text(text.substring(lastEnd, match.start)));
      }

      final raw = match.group(0) ?? '';
      final normalized = _normalizeWordForCache(raw);
      if (_shouldTranslateWord(normalized)) {
        segments.add(_WordSegment.word(raw, normalized));
      } else {
        segments.add(_WordSegment.text(raw));
      }
      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      segments.add(_WordSegment.text(text.substring(lastEnd)));
    }

    return segments;
  }

  String _escapeMarkerValue(String value) {
    return value.replaceAll('[', '(').replaceAll(']', ')').replaceAll('|', '/');
  }

  Map<String, _WordCacheEntry> _extractWordCacheEntriesFromMarkerText(
      String markedText) {
    final result = <String, _WordCacheEntry>{};
    if (markedText.isEmpty) return result;

    final markerPattern =
        RegExp(r'\[([^\[\]\|]+)\|([^\[\]\|]*)(?:\|([^\[\]\|]*))?\]');
    for (final match in markerPattern.allMatches(markedText)) {
      final originalWord = (match.group(1) ?? '').trim();
      final translatedWord = (match.group(2) ?? '').trim();
      final levelRaw = (match.group(3) ?? '').trim();
      final normalizedWord = _normalizeWordForCache(originalWord);
      if (normalizedWord.isEmpty || translatedWord.isEmpty) continue;

      final normalizedLevel = _normalizeCefrLevel(levelRaw, allowNull: true);
      result[normalizedWord] = _WordCacheEntry(
        translation: translatedWord,
        level: normalizedLevel,
      );
    }
    return result;
  }

  int _firstCasedLetterIndex(String text) {
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch.toLowerCase() != ch.toUpperCase()) {
        return i;
      }
    }
    return -1;
  }

  String _alignTranslationCaseWithSource(String source, String translation) {
    if (source.isEmpty || translation.isEmpty) return translation;

    final sourceIdx = _firstCasedLetterIndex(source);
    final translationIdx = _firstCasedLetterIndex(translation);
    if (sourceIdx < 0 || translationIdx < 0) return translation;

    final srcChar = source[sourceIdx];
    final transChar = translation[translationIdx];

    final sourceIsUpper = srcChar == srcChar.toUpperCase();
    final sourceIsLower = srcChar == srcChar.toLowerCase();
    if (!sourceIsUpper && !sourceIsLower) return translation;

    final desiredChar =
        sourceIsUpper ? transChar.toUpperCase() : transChar.toLowerCase();
    if (desiredChar == transChar) return translation;

    return translation.substring(0, translationIdx) +
        desiredChar +
        translation.substring(translationIdx + 1);
  }

  String? _normalizeCefrLevel(String raw, {bool allowNull = false}) {
    final normalized = raw.trim().toLowerCase();
    if (allowNull &&
        (normalized.isEmpty ||
            normalized == 'null' ||
            normalized == 'none' ||
            normalized == '?')) {
      return null;
    }
    return _validCefrLevels.contains(normalized) ? normalized : null;
  }

  bool _isAiWordLevelRefineEnabledForBook([int? bookId]) {
    return Prefs().isAiRefineWordLevelsEnabledForBook(bookId ?? widget.book.id);
  }

  void _scheduleAiWordLevelRefinement(Set<String> words) {
    if (words.isEmpty) return;
    if (!_isAiWordLevelRefineEnabledForBook()) {
      AiTranslationStatusService().addLog(
        message:
            'AI refine skipped: disabled for current book (${widget.book.id})',
      );
      return;
    }

    final normalizedWords =
        words.map(_normalizeWordForCache).where((w) => w.isNotEmpty).toSet();
    if (normalizedWords.isEmpty) return;
    AiTranslationStatusService().addLog(
      message:
          'AI refine scheduled: ${normalizedWords.length} words (book ${widget.book.id})',
    );

    final bucket = _pendingWordLevelRefineWords.putIfAbsent(
        widget.book.id, () => <String>{});
    bucket.addAll(normalizedWords);

    if (_activeWordLevelRefineBooks.contains(widget.book.id)) {
      return;
    }

    _activeWordLevelRefineBooks.add(widget.book.id);
    unawaited(_runAiWordLevelRefinementQueue(widget.book.id));
  }

  Future<void> _queueRefineForVisibleTextsFromWordCache(
    List<String> sourceTexts, {
    List<String> markedTexts = const <String>[],
  }) async {
    final cacheKey = _cacheLevel(_wordWiseWordCacheLevel);
    if (sourceTexts.isEmpty) return;
    if (!_isAiWordLevelRefineEnabledForBook()) return;

    final candidateWords = <String>{};
    for (final text in sourceTexts) {
      final segments = _tokenizeWordSegments(text);
      for (final segment in segments) {
        if (segment.isWord && segment.normalizedWord != null) {
          candidateWords.add(segment.normalizedWord!);
        }
      }
    }
    if (candidateWords.isEmpty) return;

    final raw = await translationCacheDao.getTranslations(
      widget.book.id,
      cacheKey,
      candidateWords.toList(growable: false),
    );
    if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) return;
    final decodedCache = <String, _WordCacheEntry>{};
    for (final entry in raw.entries) {
      final word = _normalizeWordForCache(entry.key);
      if (word.isEmpty) continue;
      decodedCache[word] = _decodeWordCacheEntry(entry.value);
    }

    final missingInWordCache =
        candidateWords.where((word) => !decodedCache.containsKey(word)).toSet();

    if (missingInWordCache.isNotEmpty && markedTexts.isNotEmpty) {
      final seeded = <String, _WordCacheEntry>{};
      for (final marked in markedTexts) {
        final entries = _extractWordCacheEntriesFromMarkerText(marked);
        for (final entry in entries.entries) {
          if (missingInWordCache.contains(entry.key)) {
            seeded[entry.key] = entry.value;
          }
        }
      }

      if (seeded.isNotEmpty) {
        await translationCacheDao.insertTranslations(
          widget.book.id,
          cacheKey,
          _encodeWordCacheUpdates(seeded),
        );
        decodedCache.addAll(seeded);
        AiTranslationStatusService().addLog(
          message:
              'AI refine seeded word cache from sentence markers: ${seeded.length} words',
        );
      }
    }

    final needsRefine = <String>{};
    for (final entry in decodedCache.entries) {
      final word = entry.key;
      final decoded = entry.value;
      final hasTranslation = decoded.translation.trim().isNotEmpty;
      final hasLevel = (decoded.level ?? '').trim().isNotEmpty;
      if (hasTranslation && !hasLevel) {
        needsRefine.add(word);
      }
    }

    if (needsRefine.isEmpty) return;
    AiTranslationStatusService().addLog(
      message:
          'AI refine queued from cache: ${needsRefine.length} words (visible page/chunk)',
    );
    if (mounted && cacheKey == _cacheLevel(_wordWiseWordCacheLevel)) {
      _scheduleAiWordLevelRefinement(needsRefine);
    }
  }

  Future<void> _runAiWordLevelRefinementQueue(int bookId) async {
    final updatedLevels = <String, String>{};
    final cacheKey = _cacheLevel(_wordWiseWordCacheLevel);
    try {
      while (true) {
        if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) break;
        final words = _pendingWordLevelRefineWords.remove(bookId) ?? <String>{};
        if (words.isEmpty) break;
        if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) break;
        AiTranslationStatusService().addLog(
          message:
              'AI refine queue: processing ${words.length} words (book $bookId)',
        );

        final updated =
            await _refineWordLevelsOnce(bookId, words.toList(growable: false));
        updatedLevels.addAll(updated);
      }

      if (updatedLevels.isNotEmpty &&
          mounted &&
          cacheKey == _cacheLevel(_wordWiseWordCacheLevel)) {
        await webViewController.evaluateJavascript(
            source:
                'window.reader?.view?.translator?.updateWordLevels(${jsonEncode(updatedLevels)})');
      }
    } catch (e) {
      _aiDebugLog('⚠️ [AI LEVEL REFINE QUEUE ERROR] $e');
    } finally {
      _activeWordLevelRefineBooks.remove(bookId);
      final pending = _pendingWordLevelRefineWords[bookId];
      if (mounted && pending != null && pending.isNotEmpty) {
        _scheduleAiWordLevelRefinement(pending);
      }
    }
  }

  Future<Map<String, String>> _refineWordLevelsOnce(
      int bookId, List<String> words) async {
    final cacheKey = _cacheLevel(_wordWiseWordCacheLevel);
    if (words.isEmpty) return {};
    if (!_isAiWordLevelRefineEnabledForBook(bookId)) {
      AiTranslationStatusService().addLog(
        message: 'AI refine skipped in worker: disabled for book $bookId',
      );
      return {};
    }

    final rawCache = await translationCacheDao.getTranslations(
      bookId,
      cacheKey,
      words,
    );
    if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) return {};

    final needLevels = <String>[];
    final decoded = <String, _WordCacheEntry>{};
    for (final entry in rawCache.entries) {
      final word = _normalizeWordForCache(entry.key);
      final cacheEntry = _decodeWordCacheEntry(entry.value);
      decoded[word] = cacheEntry;
      if (cacheEntry.translation.trim().isNotEmpty &&
          (cacheEntry.level == null || cacheEntry.level!.isEmpty)) {
        needLevels.add(word);
      }
    }

    if (needLevels.isEmpty) {
      AiTranslationStatusService().addLog(
        message:
            'AI refine worker: no words with translation+missing level in current batch',
      );
      return {};
    }
    AiTranslationStatusService().addLog(
      message:
          'AI refine worker: ${needLevels.length}/${words.length} words need CEFR levels',
    );

    final sourceLang = _resolveBookSourceLanguage(bookId);
    final chunkSize = Prefs().aiBatchSize <= 0
        ? 20
        : (Prefs().aiBatchSize > 60 ? 60 : Prefs().aiBatchSize);

    final levelUpdates = <String, String?>{};
    for (var i = 0; i < needLevels.length; i += chunkSize) {
      final end = (i + chunkSize > needLevels.length)
          ? needLevels.length
          : i + chunkSize;
      final chunk = needLevels.sublist(i, end);
      final chunkLevels = await _requestWordLevelsFromAi(chunk, sourceLang);
      if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) {
        return {};
      }
      levelUpdates.addAll(chunkLevels);
    }

    if (levelUpdates.isEmpty) {
      AiTranslationStatusService().addLog(
        message: 'AI refine worker: AI returned no usable level mappings',
      );
      return {};
    }

    final cacheUpdates = <String, _WordCacheEntry>{};
    var skippedMissingExisting = 0;
    var skippedNullLevel = 0;
    var skippedSameLevel = 0;
    for (final entry in levelUpdates.entries) {
      final word = _normalizeWordForCache(entry.key);
      final existing = decoded[word];
      if (existing == null) {
        skippedMissingExisting++;
        continue;
      }
      final normalizedLevel =
          entry.value == null ? null : _normalizeCefrLevel(entry.value!);
      if (normalizedLevel == null) {
        skippedNullLevel++;
        continue;
      }
      if (existing.level == normalizedLevel) {
        skippedSameLevel++;
        continue;
      }

      cacheUpdates[word] = _WordCacheEntry(
        translation: existing.translation,
        level: normalizedLevel,
      );
    }
    AiTranslationStatusService().addLog(
      message:
          'AI refine worker: levelUpdates=${levelUpdates.length}, cacheUpdates=${cacheUpdates.length}, skipped(null=$skippedNullLevel, same=$skippedSameLevel, missing=$skippedMissingExisting)',
    );

    if (cacheUpdates.isEmpty) {
      AiTranslationStatusService().addLog(
        message:
            'AI refine worker: no cache updates after normalization/filtering',
      );
      return {};
    }
    AiTranslationStatusService().addLog(
      message:
          'AI refine worker: applying ${cacheUpdates.length} level updates to cache',
    );

    await translationCacheDao.insertTranslations(
      bookId,
      cacheKey,
      _encodeWordCacheUpdates(cacheUpdates),
    );
    return cacheUpdates.map((word, entry) => MapEntry(word, entry.level!));
  }

  Future<Map<String, String?>> _requestWordLevelsFromAi(
      List<String> words, LangListEnum sourceLang) async {
    final cacheKey = _cacheLevel(_wordWiseWordCacheLevel);
    if (words.isEmpty) return {};

    final statusService = AiTranslationStatusService();
    final requestId = statusService.beginRequest(
      itemsCount: words.length,
      source: 'ai_refine_levels',
      message: 'AI refine started: ${words.length} words (${sourceLang.code})',
    );
    final stopwatch = Stopwatch()..start();

    try {
      final payload = generatePromptClassifyWordLevels(
        jsonEncode(words),
        sourceLang.code,
      );
      final messages = payload.buildMessages();
      final response = await AiTranslateProvider.classifyInBackground(() async {
        if (!mounted || cacheKey != _cacheLevel(_wordWiseWordCacheLevel)) {
          return '';
        }
        var text = '';
        await for (final chunk in aiGenerateStream(messages, ref: ref)) {
          text = chunk;
        }
        return text;
      });
      final parsed = _parseWordLevelMapFromAi(response, words);
      final nonNullCount =
          parsed.values.where((value) => (value ?? '').isNotEmpty).length;
      stopwatch.stop();
      statusService.endRequest(
        requestId,
        message:
            'AI refine finished: ${parsed.length}/${words.length} words, non-null=$nonNullCount (${stopwatch.elapsedMilliseconds}ms)',
        requestPayload: _clipStatusPayload(jsonEncode(words)),
        responsePayload: _clipStatusPayload(response),
      );
      return parsed;
    } catch (e) {
      _aiDebugLog('⚠️ [AI LEVEL REQUEST ERROR] $e');
      stopwatch.stop();
      statusService.endRequest(
        requestId,
        isError: true,
        message: 'AI refine failed: ${words.length} words',
        requestPayload: _clipStatusPayload(jsonEncode(words)),
        responsePayload: _clipStatusPayload(e.toString()),
      );
      return {};
    }
  }

  Map<String, String?> _parseWordLevelMapFromAi(
      String response, List<String> requestedWords) {
    if (response.trim().isEmpty) return {};

    String cleaned = splitReasoningEnvelope(response).answerContent.trim();
    final fenceRegex = RegExp(r'```(?:json)?\s*\n?([\s\S]*?)\n?\s*```');
    final fenceMatch = fenceRegex.firstMatch(cleaned);
    if (fenceMatch != null) {
      cleaned = fenceMatch.group(1)!.trim();
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (_) {
      final objectMatch = RegExp(r'\{[\s\S]*\}').firstMatch(cleaned);
      if (objectMatch == null) return {};
      try {
        decoded = jsonDecode(objectMatch.group(0)!);
      } catch (_) {
        return {};
      }
    }

    final result = <String, String?>{};
    if (decoded is Map) {
      for (final entry in decoded.entries) {
        final word = _normalizeWordForCache(entry.key.toString());
        if (word.isEmpty) continue;
        final level = entry.value?.toString();
        final normalized =
            level == null ? null : _normalizeCefrLevel(level, allowNull: true);
        result[word] = normalized;
      }
    }

    if (decoded is List) {
      for (final item in decoded) {
        if (item is List && item.length >= 2) {
          final word = _normalizeWordForCache(item[0].toString());
          final levelRaw = item[1]?.toString();
          final level = levelRaw == null
              ? null
              : _normalizeCefrLevel(levelRaw, allowNull: true);
          if (word.isNotEmpty) {
            result[word] = level;
          }
        }
      }
    }

    // Keep only requested words.
    final requested = requestedWords.map(_normalizeWordForCache).toSet();
    result.removeWhere((word, _) => !requested.contains(word));
    return result;
  }

  Future<_WordWiseNonAiResult> _translateWordWiseWithNonAi({
    required List<String> texts,
    required TranslateService service,
    required LangListEnum from,
    required LangListEnum to,
    required String pageInfo,
  }) async {
    final sentenceTranslations = <String, String>{};
    final wordCacheUpdates = <String, _WordCacheEntry>{};
    final wordsNeedingLevelRefine = <String>{};
    final sentenceSegments = <String, List<_WordSegment>>{};
    final uniqueWords = <String>{};

    for (final text in texts) {
      final segments = _tokenizeWordSegments(text);
      sentenceSegments[text] = segments;
      for (final segment in segments) {
        if (segment.isWord) {
          uniqueWords.add(segment.normalizedWord!);
        }
      }
    }

    final rawWordCache = uniqueWords.isEmpty
        ? <String, String>{}
        : await translationCacheDao.getTranslations(
            widget.book.id,
            _cacheLevel(_wordWiseWordCacheLevel,
                from: from, to: to, service: service),
            uniqueWords.toList(),
          );
    final wordCache = <String, _WordCacheEntry>{};
    for (final entry in rawWordCache.entries) {
      final word = _normalizeWordForCache(entry.key);
      wordCache[word] = _decodeWordCacheEntry(entry.value);
    }

    final missingWords =
        uniqueWords.where((word) => !wordCache.containsKey(word)).toList();
    final unresolvedWords = Set<String>.from(missingWords);
    var rateLimited = false;

    final int wordsPerRequest = Prefs().aiBatchSize <= 0
        ? 1
        : (Prefs().aiBatchSize > 100 ? 100 : Prefs().aiBatchSize);

    for (var start = 0; start < missingWords.length; start += wordsPerRequest) {
      final end = (start + wordsPerRequest > missingWords.length)
          ? missingWords.length
          : start + wordsPerRequest;
      final chunkWords = missingWords.sublist(start, end);
      if (chunkWords.isEmpty) continue;

      final statusService = AiTranslationStatusService();
      final requestId = statusService.beginRequest(
        itemsCount: chunkWords.length,
        source: 'non_ai_word_translate_${service.name}',
        message:
            'Word translate started (${service.name}): ${chunkWords.length} words',
      );
      final stopwatch = Stopwatch()..start();

      try {
        final chunkResults = await service.provider.translateBatch(
          chunkWords,
          from,
          to,
          level: 'full',
          pageInfo: pageInfo,
          ref: ref,
        );

        for (var i = 0; i < chunkWords.length; i++) {
          final word = chunkWords[i];
          final translatedWord =
              (i < chunkResults.length ? chunkResults[i] : '').trim();

          if (translatedWord == '__ANX_RATE_LIMIT__') rateLimited = true;
          if (isTranslationFailure(translatedWord)) continue;
          if (translatedWord.toLowerCase() == word.toLowerCase()) {
            final cacheEntry =
                const _WordCacheEntry(translation: '', level: null);
            wordCache[word] = cacheEntry;
            wordCacheUpdates[word] = cacheEntry;
            unresolvedWords.remove(word);
            continue;
          }

          final cacheEntry =
              _WordCacheEntry(translation: translatedWord, level: null);
          wordCache[word] = cacheEntry;
          wordCacheUpdates[word] = cacheEntry;
          wordsNeedingLevelRefine.add(word);
          unresolvedWords.remove(word);
        }
        stopwatch.stop();
        statusService.endRequest(
          requestId,
          message:
              'Word translate finished (${service.name}): ${chunkWords.length} words (${stopwatch.elapsedMilliseconds}ms)',
          requestPayload: _clipStatusPayload(jsonEncode(chunkWords)),
          responsePayload: _clipStatusPayload(jsonEncode(chunkResults)),
        );
      } catch (e) {
        rateLimited = rateLimited || e.toString().contains('429');
        _aiDebugLog('⚠️ [NON-AI WORD CHUNK ERROR] $e');
        stopwatch.stop();
        statusService.endRequest(
          requestId,
          isError: true,
          message:
              'Word translate failed (${service.name}): ${chunkWords.length} words',
          requestPayload: _clipStatusPayload(jsonEncode(chunkWords)),
          responsePayload: _clipStatusPayload(e.toString()),
        );

        // Failed words remain unresolved; completed word-cache entries survive retry.
      }
    }

    for (final text in texts) {
      final segments = sentenceSegments[text] ?? const <_WordSegment>[];
      final hasUnresolvedWord = segments.any((segment) =>
          segment.isWord &&
          unresolvedWords.contains(segment.normalizedWord ?? ''));

      final buffer = StringBuffer();
      var hasMarker = false;

      for (final segment in segments) {
        if (!segment.isWord) {
          buffer.write(segment.rawText);
          continue;
        }

        final cacheEntry = wordCache[segment.normalizedWord ?? ''];
        if (cacheEntry == null) {
          buffer.write(segment.rawText);
          continue;
        }
        final translatedWord = cacheEntry.translation.trim();
        if (translatedWord.isEmpty) {
          buffer.write('[${segment.rawText}||0]');
          hasMarker = true;
          continue;
        }
        if ((cacheEntry.level ?? '').trim().isEmpty) {
          wordsNeedingLevelRefine.add(segment.normalizedWord ?? '');
        }

        final adjustedTranslation =
            _alignTranslationCaseWithSource(segment.rawText, translatedWord);

        hasMarker = true;
        final normalizedLevel =
            _normalizeCefrLevel(cacheEntry.level ?? '', allowNull: true);
        final original = _escapeMarkerValue(segment.rawText);
        final translated = _escapeMarkerValue(adjustedTranslation);
        if (normalizedLevel == null) {
          buffer.write('[$original|$translated]');
        } else {
          buffer.write('[$original|$translated|$normalizedLevel]');
        }
      }

      if (hasUnresolvedWord) {
        sentenceTranslations[text] = rateLimited
            ? '__ANX_RATE_LIMIT__'
            : '__ANX_PARTIAL__${buffer.toString()}';
      } else if (!hasMarker) {
        sentenceTranslations[text] = text;
      } else {
        sentenceTranslations[text] = buffer.toString();
      }
    }

    return _WordWiseNonAiResult(
      sentenceTranslations: sentenceTranslations,
      wordCacheUpdates: wordCacheUpdates,
      wordsNeedingLevelRefine: wordsNeedingLevelRefine,
    );
  }

  Future<void> setHandler(InAppWebViewController controller) async {
    controller.addJavaScriptHandler(
        handlerName: 'onVocabularyWordTap', callback: _openVocabularyWord);
    controller.addJavaScriptHandler(
        handlerName: 'onLoadEnd',
        callback: (args) {
          widget.onLoadEnd();
          _applyTranslationSettings();
        });

    controller.addJavaScriptHandler(
        handlerName: 'onRelocated',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          if (cfi == location['cfi']) return;
          // if (chapterHref != location['chapterHref']) {
          //   refreshToc();
          // }
          setState(() {
            cfi = location['cfi'] ?? '';
            percentage =
                double.tryParse(location['percentage'].toString()) ?? 0.0;
            chapterTitle = location['chapterTitle'] ?? '';
            chapterHref = location['chapterHref'] ?? '';
            chapterCurrentPage = location['chapterCurrentPage'] ?? 0;
            chapterTotalPages = location['chapterTotalPages'] ?? 0;
            bookmarkExists = location['bookmark']['exists'] ?? false;
            bookmarkCfi = location['bookmark']['cfi'] ?? '';
            writingMode =
                WritingModeEnum.fromCode(location['writingMode'] ?? '');
          });
          ref.read(currentReadingProvider.notifier).update(
                cfi: cfi,
                percentage: percentage,
                chapterTitle: chapterTitle,
                chapterHref: chapterHref,
                chapterCurrentPage: chapterCurrentPage,
                chapterTotalPages: chapterTotalPages,
              );
          widget.updateParent();
          saveReadingProgress();
          readingPageKey.currentState?.resetAwakeTimer();
        });
    controller.addJavaScriptHandler(
        handlerName: 'onClick',
        callback: (args) {
          Map<String, dynamic> location = args[0];
          onClick(location);
        });
    controller.addJavaScriptHandler(
      handlerName: 'onExternalLink',
      callback: (args) async {
        final payload = args.isNotEmpty ? args.first : null;
        await _handleExternalLink(payload);
        if (!mounted) return null;
      },
    );
    controller.addJavaScriptHandler(
        handlerName: 'onSetToc',
        callback: (args) {
          List<dynamic> t = args[0];
          final toc = t.map((i) => TocItem.fromJson(i)).toList();
          ref.read(bookTocProvider.notifier).setToc(toc);
        });
    controller.addJavaScriptHandler(
        handlerName: 'onSelectionEnd',
        callback: (args) {
          removeOverlay();
          Map<String, dynamic> location = args[0];
          String cfi = location['cfi'];
          String text = location['text'];
          bool footnote = location['footnote'];
          final rawContextText = location['contextText']?.toString();
          _lastSelectionContextText =
              (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
          double left = (location['pos']['left'] as num).toDouble();
          double top = (location['pos']['top'] as num).toDouble();
          double right = (location['pos']['right'] as num).toDouble();
          double bottom = (location['pos']['bottom'] as num).toDouble();
          showContextMenu(
            context,
            left,
            top,
            right,
            bottom,
            text,
            cfi,
            null,
            footnote,
            writingMode.isVertical ? Axis.vertical : Axis.horizontal,
            contextText: _lastSelectionContextText,
          );
        });
    controller.addJavaScriptHandler(
        handlerName: 'onSelectionCleared',
        callback: (args) {
          if (_selectionClearLocked) {
            _selectionClearPending = true;
            return;
          }
          _lastSelectionContextText = null;
          removeOverlay();
          restoreReaderFocus();
        });
    controller.addJavaScriptHandler(
        handlerName: 'onAnnotationClick',
        callback: (args) {
          Map<String, dynamic> annotation = args[0];

          if (annotation['annotation'] == null) {
            // Check if TTS is active and the click is on the currently read text
            final currentTtsState = TtsHandler().ttsStateNotifier.value;
            if (currentTtsState == TtsStateEnum.playing ||
                currentTtsState == TtsStateEnum.paused) {
              if (currentTtsState == TtsStateEnum.playing) {
                audioHandler.pause();
              } else {
                audioHandler.play();
              }
              return;
            }
          }

          int id = annotation['annotation']['id'];
          String cfi = annotation['annotation']['value'];
          String note = annotation['annotation']['note'];
          final rawContextText = annotation['contextText']?.toString();
          _lastSelectionContextText =
              (rawContextText?.trim().isEmpty ?? true) ? null : rawContextText;
          double left = (annotation['pos']['left'] as num).toDouble();
          double top = (annotation['pos']['top'] as num).toDouble();
          double right = (annotation['pos']['right'] as num).toDouble();
          double bottom = (annotation['pos']['bottom'] as num).toDouble();
          showContextMenu(
            context,
            left,
            top,
            right,
            bottom,
            note,
            cfi,
            id,
            false,
            writingMode.isVertical ? Axis.vertical : Axis.horizontal,
            contextText: _lastSelectionContextText,
          );
        });
    controller.addJavaScriptHandler(
      handlerName: 'onSearch',
      callback: (args) {
        Map<String, dynamic> search = args[0];
        setState(() {
          final tocSearch = ref.read(tocSearchProvider.notifier);
          if (search['process'] != null) {
            final progress = search['process'].toDouble();
            tocSearch.updateProgress(progress);
          } else {
            tocSearch.addResult(SearchResultModel.fromJson(search));
          }
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'renderAnnotations',
      callback: (args) {
        renderAnnotations(controller);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPushState',
      callback: (args) {
        Map<String, dynamic> state = args[0];
        if (!mounted) return;
        setState(() {
          canGoBack = state['canGoBack'];
          canGoForward = state['canGoForward'];
          showHistory = canGoBack || canGoForward;
        });
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onImageClick',
      callback: (args) {
        String image = args[0];
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => ImageViewer(
                      image: image,
                      bookName: widget.book.title,
                    )));
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onFootnoteClose',
      callback: (args) {
        removeOverlay();
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onPullUp',
      callback: (args) {
        widget.showOrHideAppBarAndBottomBar(true);
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'handleBookmark',
      callback: (args) async {
        Map<String, dynamic> detail = args[0]['detail'];
        bool remove = args[0]['remove'];
        String cfi = detail['cfi'] ?? '';
        double percentage = double.parse(detail['percentage'].toString());
        String content = detail['content'];

        if (remove) {
          ref.read(bookmarkProvider(widget.book.id).notifier).removeBookmark(
                cfi: cfi,
              );
          bookmarkCfi = '';
          bookmarkExists = false;
        } else {
          BookmarkModel bookmark = await ref
              .read(BookmarkProvider(widget.book.id).notifier)
              .addBookmark(
                BookmarkModel(
                  bookId: widget.book.id,
                  cfi: cfi,
                  percentage: percentage,
                  content: content,
                  chapter: chapterTitle,
                  updateTime: DateTime.now(),
                  createTime: DateTime.now(),
                ),
              );
          if (!mounted) return null;
          bookmarkCfi = cfi;
          bookmarkExists = true;
          addBookmark(bookmark);
        }
        if (!mounted) return null;
        widget.updateParent();
        setState(() {});
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'translateText',
      callback: (args) async {
        try {
          if (!mounted) return 'Translation cancelled';
          String text = args[0];
          _aiDebugLog('🌐 [TRANSLATE REQUEST] "$text"');
          final service = Prefs().fullTextTranslateService;
          final from = _resolveBookSourceLanguage();
          final to = Prefs().fullTextTranslateTo;

          final result = await service.provider
              .translateTextOnly(text, from, to, isFullText: true, ref: ref);
          if (!mounted) return 'Translation cancelled';
          _aiDebugLog('✅ [TRANSLATE RESPONSE] "$text" → "$result"');
          return result;
        } catch (e) {
          _aiDebugLog('❌ [TRANSLATE ERROR] "${args[0]}" → $e');
          AnxLog.severe('Translation error: $e');
          if (!mounted) return 'Translation cancelled';
          return 'Translation error: $e';
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'checkTranslationCache',
      callback: (args) async {
        try {
          if (!mounted) return "{}";
          final String textsJsonStr = args[0];
          final String level = args.length > 1 ? args[1] : 'full';
          final List<dynamic> textsList = jsonDecode(textsJsonStr);
          final texts = textsList.map((e) => e.toString()).toList();
          final bookId = widget.book.id;
          // Use unified 'word_wise' cache key for all interlinear levels (A1-C2)
          // This allows switching levels without re-translating
          final cacheLevel =
              _cacheLevel(level != 'full' ? _wordWiseCacheLevel : 'full');

          final cached = await _readCachedTranslations(
              bookId, cacheLevel, texts,
              wordWise: level != 'full');
          if (!mounted ||
              cacheLevel !=
                  _cacheLevel(level != 'full' ? _wordWiseCacheLevel : 'full')) {
            return "{}";
          }
          if (level != 'full' &&
              Prefs().fullTextTranslateService != TranslateService.ai) {
            unawaited(_queueRefineForVisibleTextsFromWordCache(
                cached.keys.toList(),
                markedTexts: cached.values.toList()));
          }
          return jsonEncode(cached);
        } catch (e) {
          _aiDebugLog('❌ [CACHE CHECK ERROR] $e');
          AnxLog.severe('Cache check error: $e');
          if (!mounted) return "{}";
          return "{}";
        }
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'onTranslationRetry',
      callback: (args) async {
        try {
          final raw = args.isNotEmpty ? args[0] : null;
          final payload = raw is Map
              ? raw.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};

          int parseInt(dynamic value, {int fallback = 0}) {
            if (value is int) return value;
            return int.tryParse(value?.toString() ?? '') ?? fallback;
          }

          bool parseBool(dynamic value) {
            if (value is bool) return value;
            final str = value?.toString().toLowerCase();
            return str == 'true' || str == '1';
          }

          final attempt = parseInt(payload['attempt']);
          final maxAttempts = parseInt(payload['maxAttempts'], fallback: 5);
          final delayMs = parseInt(payload['delayMs']);
          final isRateLimit = parseBool(payload['isRateLimit']);
          final isBlocked = parseBool(payload['isBlocked']);
          final textPreview = payload['textPreview']?.toString() ?? '';

          final message = isBlocked
              ? 'Retry stopped after $attempt/$maxAttempts attempts until page relocate'
              : isRateLimit
                  ? 'Rate-limit retry #$attempt in ${(delayMs / 1000).toStringAsFixed(0)}s'
                  : 'Retry #$attempt/$maxAttempts in ${delayMs}ms';

          AiTranslationStatusService().addLog(
            message: message,
            isError: isBlocked,
            requestPayload: textPreview.isEmpty ? null : textPreview,
          );
        } catch (e) {
          _aiDebugLog('❌ [RETRY LOG BRIDGE ERROR] $e');
        }
        return true;
      },
    );
    controller.addJavaScriptHandler(
      handlerName: 'translateBatch',
      callback: (args) async {
        final texts = (jsonDecode(args[0] as String) as List).cast<String>();
        final level = args.length > 1 ? args[1] as String : 'full';
        final pageInfo = args.length > 2 ? args[2] as String : '';
        final service = Prefs().fullTextTranslateService;
        final from = _resolveBookSourceLanguage(),
            to = Prefs().fullTextTranslateTo;
        final bookId = widget.book.id;
        final wordWise = level != 'full';
        final key = _cacheLevel(wordWise ? _wordWiseCacheLevel : 'full',
            from: from, to: to, service: service);
        bool current() =>
            mounted &&
            key == _cacheLevel(wordWise ? _wordWiseCacheLevel : 'full');
        List<String> ordered(Map<String, String> cache) =>
            texts.map((text) => cache[text] ?? '__ANX_RETRY__').toList();
        var hasSlot = false;
        try {
          // Warm cache bypasses busy provider workers entirely.
          var cached = await _readCachedTranslations(bookId, key, texts,
              wordWise: wordWise);
          if (!current()) {
            return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
          }
          if (texts.every(cached.containsKey)) {
            return jsonEncode(ordered(cached));
          }
          while (_activeTranslationWorkers >=
              _maxTranslationWorkers.clamp(1, 10)) {
            final waiter = Completer<void>();
            _translationWaitQueue.add(waiter);
            await waiter.future;
            if (!current()) {
              return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
            }
          }
          _activeTranslationWorkers++;
          hasSlot = true;
          // Another request may have completed while this one waited.
          cached = await _readCachedTranslations(bookId, key, texts,
              wordWise: wordWise);
          final missing =
              texts.where((text) => !cached.containsKey(text)).toSet().toList();
          if (!current()) {
            return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
          }
          if (missing.isEmpty) return jsonEncode(ordered(cached));
          final completed = <String, String>{}, failures = <String, String>{};
          if (wordWise && service != TranslateService.ai) {
            final result = await _translateWordWiseWithNonAi(
                texts: missing,
                service: service,
                from: from,
                to: to,
                pageInfo: pageInfo);
            if (!current()) {
              return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
            }
            await translationCacheDao.insertTranslations(
                bookId,
                _cacheLevel(_wordWiseWordCacheLevel,
                    from: from, to: to, service: service),
                _encodeWordCacheUpdates(result.wordCacheUpdates));
            for (final entry in result.sentenceTranslations.entries) {
              if (isTranslationFailure(entry.value)) {
                failures[entry.key] = entry.value;
              } else {
                completed[entry.key] = entry.value;
              }
            }
            if (current()) {
              _scheduleAiWordLevelRefinement(result.wordsNeedingLevelRefine);
            }
          } else {
            final partialKey = '$key:partial';
            final partials = wordWise
                ? await translationCacheDao.getTranslations(
                    bookId, partialKey, missing)
                : <String, String>{};
            final fresh =
                missing.where((text) => !partials.containsKey(text)).toList();
            final initial = fresh.isEmpty
                ? <String>[]
                : await service.provider.translateBatch(fresh, from, to,
                    level: level, pageInfo: pageInfo, ref: ref);
            if (!current()) {
              return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
            }
            final initialMap = <String, String>{};
            for (var i = 0; i < fresh.length; i++) {
              initialMap[fresh[i]] =
                  i < initial.length ? initial[i] : '__ANX_RETRY__';
            }
            for (final text in missing) {
              final value =
                  partials[text] ?? initialMap[text] ?? '__ANX_RETRY__';
              if (isTranslationFailure(value)) {
                failures[text] = value;
                continue;
              }
              if (!wordWise) {
                completed[text] = value;
                continue;
              }
              var parsed = WordWiseText(text, value);
              if (!parsed.sourceMatches) parsed = WordWiseText(text, text);
              if (parsed.missingWords.isNotEmpty) {
                // Keep good annotations; only request omissions with their sentence context.
                final repairs = <String>[];
                final words = parsed.missingWords;
                final size = Prefs().aiBatchSize.clamp(1, 60);
                for (var i = 0; i < words.length; i += size) {
                  final chunk =
                      words.sublist(i, (i + size).clamp(0, words.length));
                  final reply = await service.provider.translateBatch(
                      chunk, from, to,
                      level: level,
                      pageInfo: pageInfo,
                      contextText: text,
                      ref: ref);
                  repairs.addAll(List.generate(
                      chunk.length,
                      (index) => index < reply.length
                          ? reply[index]
                          : '__ANX_RETRY__'));
                  if (!current()) {
                    return jsonEncode(
                        List.filled(texts.length, '__ANX_CANCELLED__'));
                  }
                }
                parsed = parsed.repair(repairs);
              }
              if (parsed.missingWords.isEmpty) {
                completed[text] = parsed.markedText;
              } else {
                await translationCacheDao.insertTranslations(
                    bookId, partialKey, {text: parsed.markedText});
                failures[text] = '__ANX_PARTIAL__${parsed.markedText}';
              }
            }
          }
          if (!current()) {
            return jsonEncode(List.filled(texts.length, '__ANX_CANCELLED__'));
          }
          await translationCacheDao.insertTranslations(bookId, key, completed);
          return jsonEncode(texts
              .map((text) =>
                  cached[text] ??
                  completed[text] ??
                  failures[text] ??
                  '__ANX_RETRY__')
              .toList());
        } catch (error) {
          AnxLog.warning('Batch translation failed: $error');
          final limited = error.toString().contains('429');
          return jsonEncode(List.filled(
              texts.length, limited ? '__ANX_RATE_LIMIT__' : '__ANX_RETRY__'));
        } finally {
          if (hasSlot) {
            _activeTranslationWorkers--;
            if (_translationWaitQueue.isNotEmpty) {
              _translationWaitQueue.removeAt(0).complete();
            }
          }
        }
      },
    );
  }

  Future<void> onWebViewCreated(InAppWebViewController controller) async {
    if (AnxPlatform.isAndroid) {
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
    }
    webViewController = controller;
    setHandler(controller);
    _registerChapterContentBridge();

    // Initialize translation mode based on book-specific settings
    Future.delayed(const Duration(milliseconds: 300), () {
      _applyTranslationSettings();
    });
  }

  void removeOverlay() {
    _selectionClearLocked = false;
    _selectionClearPending = false;
    if (contextMenuEntry == null || contextMenuEntry?.mounted == false) return;
    contextMenuEntry?.remove();
    contextMenuEntry = null;
  }

  Future<void> _handlePointerEvents(PointerEvent event) async {
    if (await isFootNoteOpen() || Prefs().pageTurnStyle == PageTurn.scroll) {
      return;
    }
    // Disable scroll wheel page turning when keyboard shortcuts are enabled
    if (Prefs().keyboardShortcutTurnPage) {
      return;
    }
    if (event is PointerScrollEvent) {
      _accumulatedScrollDelta += event.scrollDelta.dy;

      _scrollDebounceTimer?.cancel();
      _scrollDebounceTimer = Timer(const Duration(milliseconds: 80), () {
        if (_accumulatedScrollDelta.abs() >= _scrollThreshold) {
          if (_accumulatedScrollDelta > 0) {
            nextPage();
          } else {
            prevPage();
          }
        }
        _accumulatedScrollDelta = 0;
      });
    }
  }

  @override
  void initState() {
    book = widget.book;
    getThemeColor();

    contextMenu = ContextMenu(
      settings: ContextMenuSettings(hideDefaultSystemContextMenuItems: true),
      onCreateContextMenu: (hitTestResult) async {
        // webViewController.evaluateJavascript(source: "showContextMenu()");
      },
      onHideContextMenu: () {
        // removeOverlay();
      },
    );
    if (Prefs().openBookAnimation) {
      _animationController = AnimationController(
        duration: const Duration(milliseconds: 600),
        vsync: this,
      );
      _animation =
          Tween<double>(begin: 1.0, end: 0.0).animate(_animationController!);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _animationController!.forward();
      });
    }
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
  }

  Future<void> saveReadingProgress() async {
    if (cfi == '' || widget.cfi != null) return;
    Book book = widget.book;
    book.lastReadPosition = cfi;
    book.readingPercentage = percentage;
    await bookDao.updateBook(book);
    if (mounted) {
      ref.read(bookListProvider.notifier).refresh();
    }
  }

  @override
  void dispose() {
    _scrollDebounceTimer?.cancel();
    _animationController?.dispose();
    saveReadingProgress();
    removeOverlay();
    super.dispose();
  }

  InAppWebViewSettings initialSettings = InAppWebViewSettings(
    supportZoom: false,
    transparentBackground: true,
    isInspectable: kDebugMode,
    useHybridComposition: true,
  );

  bool get isDarkMode =>
      Theme.of(navigatorKey.currentContext!).brightness == Brightness.dark;

  void changeReadingInfo() {
    setState(() {});
  }

  Widget _buildHistoryCapsule() {
    final l10n = L10n.of(context);
    final buttonColor = Color(int.parse('0x$textColor')).withAlpha(200);

    // Common button style for all history navigation buttons
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(32),
      ),
    );

    // Helper method to create history navigation buttons
    Widget createHistoryButton(
        IconData icon, String label, VoidCallback onPressed) {
      return TextButton.icon(
        icon: Icon(icon, size: 18, color: buttonColor),
        label: Text(label, style: TextStyle(color: buttonColor, fontSize: 14)),
        onPressed: onPressed,
        style: buttonStyle,
      );
    }

    // Build buttons list
    final List<Widget> buttons = [];

    if (canGoBack) {
      buttons.add(createHistoryButton(
        Icons.arrow_back,
        l10n.historyBack,
        backHistory,
      ));
    }

    buttons.add(createHistoryButton(
      Icons.close,
      l10n.historyClose,
      () => setState(() => showHistory = false),
    ));

    if (canGoForward) {
      buttons.add(createHistoryButton(
        Icons.arrow_forward,
        l10n.historyForward,
        forwardHistory,
      ));
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 40),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainer
                    .withAlpha(123),
                borderRadius: BorderRadius.circular(32),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outline,
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: buttons,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget readingInfoWidget() {
    if (chapterCurrentPage == 0 && percentage == 0.0) {
      return const SizedBox();
    }

    final readingInfoColor = Color(int.parse('0x$textColor')).withAlpha(150);
    final iconColor = Color(int.parse('0x$textColor'));

    Widget getWidget(ReadingInfoEnum readingInfoEnum, TextStyle textStyle) {
      final batteryTextStyle = TextStyle(
        color: iconColor,
        fontSize: (textStyle.fontSize ?? 10) - 1,
      );
      final batteryIconSize = (textStyle.fontSize ?? 10) * 2.7;

      final chapterTitleWidget = Text(
        (chapterCurrentPage == 1 ? widget.book.title : chapterTitle),
        style: textStyle,
      );

      final chapterProgressWidget = Text(
        '$chapterCurrentPage/$chapterTotalPages',
        style: textStyle,
      );

      final bookProgressWidget =
          Text('${(percentage * 100).toStringAsFixed(2)}%', style: textStyle);

      final timeWidget = MinuteClock(textStyle: textStyle);

      final batteryWidget = FutureBuilder(
          future: Battery().batteryLevel,
          builder: (context, snapshot) {
            if (snapshot.hasData) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        0, (textStyle.fontSize ?? 10) * 0.08, 2, 0),
                    child: Text('${snapshot.data}', style: batteryTextStyle),
                  ),
                  Icon(
                    HeroIcons.battery_0,
                    size: batteryIconSize,
                    color: iconColor,
                  ),
                ],
              );
            } else {
              return const SizedBox();
            }
          });

      Widget batteryAndTimeWidget() => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              batteryWidget,
              const SizedBox(width: 5),
              timeWidget,
            ],
          );

      switch (readingInfoEnum) {
        case ReadingInfoEnum.chapterTitle:
          return chapterTitleWidget;
        case ReadingInfoEnum.chapterProgress:
          return chapterProgressWidget;
        case ReadingInfoEnum.bookProgress:
          return bookProgressWidget;
        case ReadingInfoEnum.battery:
          return batteryWidget;
        case ReadingInfoEnum.time:
          return timeWidget;
        case ReadingInfoEnum.batteryAndTime:
          return batteryAndTimeWidget();
        case ReadingInfoEnum.none:
          return const SizedBox(width: 30);
      }
    }

    final readingInfo = Prefs().readingInfo;

    final headerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.header.fontSize,
    );
    final footerTextStyle = TextStyle(
      color: readingInfoColor,
      fontSize: readingInfo.footer.fontSize,
    );

    List<Widget> headerWidgets = [
      getWidget(readingInfo.header.left, headerTextStyle),
      getWidget(readingInfo.header.center, headerTextStyle),
      getWidget(readingInfo.header.right, headerTextStyle),
    ];

    List<Widget> footerWidgets = [
      getWidget(readingInfo.footer.left, footerTextStyle),
      getWidget(readingInfo.footer.center, footerTextStyle),
      getWidget(readingInfo.footer.right, footerTextStyle),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(
            top: readingInfo.header.verticalMargin,
            left: readingInfo.header.leftMargin,
            right: readingInfo.header.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: headerWidgets,
          ),
        ),
        const Spacer(),
        Padding(
          padding: EdgeInsets.only(
            bottom: readingInfo.footer.verticalMargin,
            left: readingInfo.footer.leftMargin,
            right: readingInfo.footer.rightMargin,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: footerWidgets,
          ),
        ),
      ],
    );
  }

  Widget buildWebviewWithIOSWorkaround(
      BuildContext context, String url, String initialCfi) {
    final webView = InAppWebView(
      webViewEnvironment: webViewEnvironment,
      initialUrlRequest: URLRequest(
        url: WebUri(
          generateUrl(
            url,
            initialCfi,
            backgroundColor: backgroundColor,
            textColor: textColor,
            isDarkMode: Theme.of(context).brightness == Brightness.dark,
          ),
        ),
      ),
      initialSettings: initialSettings,
      contextMenu: contextMenu,
      onLoadStop: (controller, uri) => onWebViewCreated(controller),
      onConsoleMessage: webviewConsoleMessage,
    );

    if (!AnxPlatform.isIOS) {
      return SizedBox.expand(child: webView);
    }

    return SizedBox.expand(
      child: Stack(
        children: [
          webView,
          Positioned.fill(
            child: PointerInterceptor(
              intercepting: !_isTopOfNavigationStack,
              debug: false,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String uri = Uri.encodeComponent(widget.book.fileFullPath);
    String url = 'http://127.0.0.1:${Server().port}/book/$uri';
    String initialCfi = widget.cfi ?? widget.book.lastReadPosition;

    return Listener(
      onPointerSignal: (event) {
        _handlePointerEvents(event);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            buildWebviewWithIOSWorkaround(context, url, initialCfi),
            readingInfoWidget(),
            if (showHistory) _buildHistoryCapsule(),
            if (Prefs().openBookAnimation)
              SizedBox.expand(
                  child: IgnorePointer(
                ignoring: true,
                child: FadeTransition(
                    opacity: _animation!, child: BookCover(book: widget.book)),
              )),
          ],
        ),
      ),
    );
  }
}
