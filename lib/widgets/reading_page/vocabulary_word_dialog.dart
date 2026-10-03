import 'package:anx_reader/dao/vocabulary.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:flutter/material.dart';

String vocabularyStatusLabel(L10n l, VocabularyStatus status) =>
    switch (status) {
      VocabularyStatus.known => l.vocabularyKnown,
      VocabularyStatus.learning => l.vocabularyLearning,
      VocabularyStatus.newWord => l.vocabularyNew,
    };

/// Returns the explicitly selected book language only after a successful save.
Future<LangListEnum?> showVocabularyWordDialog(
  BuildContext context, {
  required Book book,
  required String word,
  required String translation,
  required String contextText,
  required String chapter,
  required String cfi,
  required LangListEnum sourceLanguage,
  required LangListEnum targetLanguage,
  Future<void> Function()? onSpeak,
  Future<String> Function(LangListEnum source, LangListEnum target)? onExplain,
}) async {
  final controller = TextEditingController(text: translation);
  LangListEnum? source =
      sourceLanguage == LangListEnum.auto ? null : sourceLanguage;
  LangListEnum? target =
      targetLanguage == LangListEnum.auto ? null : targetLanguage;
  var busy = false;
  String? error;
  String? explanation;
  var speaking = false, explaining = false;
  try {
    final route = DialogRoute<LangListEnum>(
        context: context,
        builder: (dialogContext) =>
            StatefulBuilder(builder: (context, setState) {
              final l = L10n.of(context);
              Future<void> save(VocabularyStatus status) async {
                if (source == null || target == null) {
                  setState(() => error = l.vocabularyLanguageRequired);
                  return;
                }
                if (status == VocabularyStatus.learning &&
                    controller.text.trim().isEmpty) {
                  setState(() => error = l.vocabularyTranslationRequired);
                  return;
                }
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  await vocabularyDao.save(
                      sourceLanguage: source!.code,
                      targetLanguage: target!.code,
                      word: word,
                      translation: controller.text,
                      contextText: contextText,
                      bookId: book.id,
                      bookTitle: book.title,
                      chapter: chapter,
                      cfi: cfi,
                      status: status);
                  if (context.mounted) Navigator.pop(context, source);
                } catch (_) {
                  if (context.mounted) {
                    setState(() {
                      busy = false;
                      error = l.vocabularySaveError;
                    });
                  }
                }
              }

              Widget language(String label, LangListEnum? value,
                      ValueChanged<LangListEnum?> onChanged) =>
                  DropdownButtonFormField<LangListEnum>(
                      initialValue: value,
                      decoration: InputDecoration(labelText: label),
                      isExpanded: true,
                      items: LangListEnum.values
                          .where((lang) => lang != LangListEnum.auto)
                          .map((lang) => DropdownMenuItem(
                              value: lang,
                              child: Text(lang.getNative(context))))
                          .toList(),
                      onChanged: busy ? null : onChanged);
              return PopScope(
                  canPop: !busy,
                  child: AlertDialog(
                    title: Text(word),
                    content: SizedBox(
                        width: 480,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              language(l.vocabularySource, source,
                                  (value) => setState(() => source = value)),
                              language(l.vocabularyTarget, target,
                                  (value) => setState(() => target = value)),
                              if (source == null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(l.vocabularyLanguageRequired)),
                              TextField(
                                  controller: controller,
                                  enabled: !busy,
                                  maxLength: 2000,
                                  minLines: 1,
                                  maxLines: 4,
                                  decoration: InputDecoration(
                                      labelText: l.vocabularyTranslation)),
                              const SizedBox(height: 8),
                              Wrap(spacing: 8, children: [
                                if (onSpeak != null)
                                  TextButton.icon(
                                      icon:
                                          const Icon(Icons.volume_up_outlined),
                                      label: Text(l.vocabularySpeak),
                                      onPressed: speaking
                                          ? null
                                          : () async {
                                              setState(() => speaking = true);
                                              try {
                                                await onSpeak();
                                              } catch (_) {
                                                if (context.mounted) {
                                                  setState(() => error =
                                                      l.vocabularyActionError);
                                                }
                                              } finally {
                                                if (context.mounted) {
                                                  setState(
                                                      () => speaking = false);
                                                }
                                              }
                                            }),
                                if (onExplain != null)
                                  TextButton.icon(
                                      icon: const Icon(
                                          Icons.auto_awesome_outlined),
                                      label: Text(l.vocabularyExplain),
                                      onPressed: explaining
                                          ? null
                                          : () async {
                                              if (source == null ||
                                                  target == null) {
                                                setState(() => error = l
                                                    .vocabularyLanguageRequired);
                                                return;
                                              }
                                              setState(() {
                                                explaining = true;
                                                error = null;
                                              });
                                              try {
                                                final text = await onExplain(
                                                    source!, target!);
                                                if (context.mounted) {
                                                  setState(
                                                      () => explanation = text);
                                                }
                                              } catch (_) {
                                                if (context.mounted) {
                                                  setState(() => error =
                                                      l.vocabularyActionError);
                                                }
                                              } finally {
                                                if (context.mounted) {
                                                  setState(
                                                      () => explaining = false);
                                                }
                                              }
                                            }),
                              ]),
                              if (explaining) const LinearProgressIndicator(),
                              if (explanation != null)
                                SelectableText(explanation!),
                              SelectableText(contextText),
                              const SizedBox(height: 8),
                              Text('${book.title} · $chapter'),
                              const SizedBox(height: 12),
                              Text(l.vocabularyStatusHelp),
                              if (error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(error!,
                                        style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error))),
                              if (busy) const LinearProgressIndicator(),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(context),
                          child: Text(l.commonCancel)),
                      for (final status in VocabularyStatus.values)
                        TextButton(
                            onPressed: busy ? null : () => save(status),
                            child: Text(vocabularyStatusLabel(l, status))),
                    ],
                  ));
            }));
    final result = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    return result;
  } finally {
    controller.dispose();
  }
}
