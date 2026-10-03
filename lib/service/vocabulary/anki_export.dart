import 'dart:convert';
import 'dart:typed_data';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:csv/csv.dart';

Uint8List vocabularyAnkiCsv(List<VocabularyCard> cards) {
  final rows = cards
      .where((c) =>
          c.status == VocabularyStatus.learning &&
          c.translation.trim().isNotEmpty)
      .map((card) => [
            card.id,
            card.word,
            card.translation,
            card.contextText,
            card.bookTitle,
            card.chapter,
            '${card.sourceLanguage} → ${card.targetLanguage}',
            'anx_reader source::${card.sourceLanguage} target::${card.targetLanguage}',
          ])
      .toList();
  const headers =
      '#separator:Comma\n#html:false\n#columns:ID,Word,Translation,Context,Book,Chapter,Languages,Tags\n#tags column:8\n';
  return Uint8List.fromList(
      utf8.encode(headers + const ListToCsvConverter().convert(rows)));
}
