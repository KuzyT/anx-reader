enum VocabularyStatus {
  newWord('new'),
  known('known'),
  learning('learning');

  const VocabularyStatus(this.code);
  final String code;
}

String vocabularyWordKey(String word) => word
    .trim()
    .toLowerCase()
    .replaceAll(RegExp('[‘’]'), "'")
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(
        RegExp(r'^[^\p{L}\p{N}\p{M}]+|[^\p{L}\p{N}\p{M}]+$', unicode: true),
        '');

String vocabularyLanguage(String code) {
  final language = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language) || language == 'auto') {
    throw ArgumentError('Select a language before saving a word');
  }
  return language;
}

class VocabularyCard {
  const VocabularyCard(this.row);
  final Map<String, Object?> row;
  String get id => row['id'] as String;
  String get wordId => row['word_id'] as String;
  String get word => row['word'] as String;
  String get sourceLanguage => row['source_lang'] as String;
  String get targetLanguage => row['target_lang'] as String;
  String get translation => row['translation'] as String;
  String get contextText => row['context_text'] as String;
  int get bookId => row['book_id'] as int;
  String get bookTitle => row['book_title'] as String;
  String get chapter => row['chapter'] as String;
  String get cfi => row['cfi'] as String;
  VocabularyStatus get status =>
      VocabularyStatus.values.firstWhere((s) => s.code == row['status']);
}
