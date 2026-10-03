import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/vocabulary.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/vocabulary/anki_export.dart';
import 'package:anx_reader/utils/save_file_to_download.dart';
import 'package:anx_reader/widgets/reading_page/vocabulary_word_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class VocabularyPage extends ConsumerStatefulWidget {
  const VocabularyPage({super.key, this.bookId});
  final int? bookId;
  @override
  ConsumerState<VocabularyPage> createState() => _VocabularyPageState();
}

class _VocabularyPageState extends ConsumerState<VocabularyPage> {
  String _query = '';
  VocabularyStatus? _status;
  bool _thisBook = false, _exporting = false;
  late Future<List<VocabularyCard>> _cards;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _cards = vocabularyDao.cards(
        query: _query,
        status: _status,
        bookId: _thisBook ? widget.bookId : null);
  }

  void _refresh() {
    if (mounted) setState(_load);
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _changeStatus(
      VocabularyCard card, VocabularyStatus status) async {
    if (status == VocabularyStatus.learning &&
        card.translation.trim().isEmpty &&
        !await _edit(card)) {
      return;
    }
    try {
      await vocabularyDao.setStatus(card.wordId, status);
      _refresh();
      await epubPlayerKey.currentState?.refreshVocabulary();
    } catch (_) {
      if (mounted) _message(L10n.of(context).vocabularySaveError);
    }
  }

  Future<bool> _edit(VocabularyCard card) async {
    final controller = TextEditingController(text: card.translation);
    var saved = false, busy = false;
    String? error;
    try {
      final route = DialogRoute<void>(
          context: context,
          builder: (context) => StatefulBuilder(builder: (context, setState) {
                final l = L10n.of(context);
                return PopScope(
                    canPop: !busy,
                    child: AlertDialog(
                        title: Text(card.word),
                        content: SizedBox(
                            width: 480,
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextField(
                                      controller: controller,
                                      enabled: !busy,
                                      maxLength: 2000,
                                      minLines: 1,
                                      maxLines: 4,
                                      decoration: InputDecoration(
                                          labelText: l.vocabularyTranslation,
                                          errorText: error)),
                                  if (busy) const LinearProgressIndicator(),
                                ])),
                        actions: [
                          TextButton(
                              onPressed:
                                  busy ? null : () => Navigator.pop(context),
                              child: Text(l.commonCancel)),
                          FilledButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      if (controller.text.trim().isEmpty) {
                                        setState(() => error =
                                            l.vocabularyTranslationRequired);
                                        return;
                                      }
                                      setState(() {
                                        busy = true;
                                        error = null;
                                      });
                                      try {
                                        await vocabularyDao.editTranslation(
                                            card.id, controller.text);
                                        saved = true;
                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      } catch (_) {
                                        if (context.mounted) {
                                          setState(() {
                                            busy = false;
                                            error = l.vocabularySaveError;
                                          });
                                        }
                                      }
                                    },
                              child: Text(l.commonSave)),
                        ]));
              }));
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      controller.dispose();
    }
    if (saved) _refresh();
    return saved;
  }

  Future<void> _openContext(VocabularyCard card) async {
    final l = L10n.of(context);
    if (card.cfi.isEmpty) {
      _message(l.vocabularyContextError);
      return;
    }
    try {
      if (card.bookId == epubPlayerKey.currentState?.widget.book.id) {
        final player = epubPlayerKey.currentState!;
        final readerRoute = ModalRoute.of(player.context);
        if (readerRoute == null) throw StateError('Reader route unavailable');
        Navigator.of(context).popUntil((route) => route == readerRoute);
        player.goToCfi(card.cfi);
      } else {
        final book = await bookDao.selectBookById(card.bookId);
        if (!mounted) return;
        await pushToReadingPage(ref, context, book,
            cfi: card.cfi, closeCurrentReader: true);
      }
    } catch (_) {
      _message(l.vocabularyContextError);
    }
  }

  Future<void> _export() async {
    final l = L10n.of(context);
    setState(() => _exporting = true);
    try {
      final cards = await _cards;
      if (!cards.any((card) =>
          card.status == VocabularyStatus.learning &&
          card.translation.trim().isNotEmpty)) {
        _message(l.vocabularyExportEmpty);
        return;
      }
      final path = await saveFileToDownload(
          bytes: vocabularyAnkiCsv(cards),
          mimeType: 'text/csv',
          fileName:
              'anx-vocabulary-${DateTime.now().millisecondsSinceEpoch}.csv');
      if (path != null) _message('${l.commonSaved}: $path');
    } catch (_) {
      _message(l.vocabularyExportError);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Scaffold(
        appBar: AppBar(title: Text(l.vocabularyTitle), actions: [
          IconButton(
              onPressed: _exporting ? null : _export,
              tooltip: l.vocabularyExport,
              icon: _exporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.file_download_outlined)),
        ]),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                  decoration: InputDecoration(
                      labelText: l.vocabularySearch,
                      prefixIcon: const Icon(Icons.search)),
                  onChanged: (value) => setState(() {
                        _query = value;
                        _load();
                      }))),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: Text(l.vocabularyAll),
                    selected: _status == null,
                    onSelected: (_) => setState(() {
                          _status = null;
                          _load();
                        })),
                for (final status in VocabularyStatus.values)
                  ChoiceChip(
                      label: Text(vocabularyStatusLabel(l, status)),
                      selected: _status == status,
                      onSelected: (_) => setState(() {
                            _status = status;
                            _load();
                          })),
                if (widget.bookId != null)
                  FilterChip(
                      label: Text(l.vocabularyThisBook),
                      selected: _thisBook,
                      onSelected: (value) => setState(() {
                            _thisBook = value;
                            _load();
                          })),
              ])),
          Expanded(
              child: FutureBuilder<List<VocabularyCard>>(
                  future: _cards,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                          child: TextButton(
                              onPressed: _refresh,
                              child: Text(l.vocabularyLoadError)));
                    }
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final cards = snapshot.data!;
                    if (cards.isEmpty) {
                      return Center(child: Text(l.vocabularyEmpty));
                    }
                    return ListView.builder(
                        itemCount: cards.length,
                        itemBuilder: (context, index) {
                          final card = cards[index];
                          return Card(
                              margin: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            '${card.word} — ${card.translation}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        Text(
                                            '${card.sourceLanguage} → ${card.targetLanguage} · ${vocabularyStatusLabel(l, card.status)}'),
                                        const SizedBox(height: 8),
                                        SelectableText(card.contextText),
                                        Text(
                                            '${card.bookTitle} · ${card.chapter}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall),
                                        Wrap(spacing: 8, children: [
                                          for (final status
                                              in VocabularyStatus.values)
                                            TextButton(
                                                onPressed: card.status == status
                                                    ? null
                                                    : () => _changeStatus(
                                                        card, status),
                                                child: Text(
                                                    vocabularyStatusLabel(
                                                        l, status))),
                                          IconButton(
                                              onPressed: () => _edit(card),
                                              tooltip: l.vocabularyTranslation,
                                              icon: const Icon(
                                                  Icons.edit_outlined)),
                                          IconButton(
                                              onPressed: () async {
                                                await Clipboard.setData(
                                                    ClipboardData(
                                                        text:
                                                            '${card.word} — ${card.translation}\n${card.contextText}\n${card.bookTitle} · ${card.chapter}'));
                                                _message(l.notesPageCopied);
                                              },
                                              tooltip: l.commonCopy,
                                              icon: const Icon(Icons.copy)),
                                          IconButton(
                                              onPressed: card.cfi.isEmpty
                                                  ? null
                                                  : () => _openContext(card),
                                              tooltip: l.vocabularyOpenContext,
                                              icon: const Icon(
                                                  Icons.menu_book_outlined)),
                                        ]),
                                      ])));
                        });
                  })),
        ]));
  }
}
