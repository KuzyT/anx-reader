import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/models/vocabulary.dart';
import 'package:uuid/uuid.dart';

class VocabularyDao {
  Future<String> save(
      {required String sourceLanguage,
      required String targetLanguage,
      required String word,
      required String translation,
      required String contextText,
      required int bookId,
      required String bookTitle,
      required String chapter,
      required String cfi,
      required VocabularyStatus status}) async {
    final source = vocabularyLanguage(sourceLanguage),
        target = vocabularyLanguage(targetLanguage);
    final key = vocabularyWordKey(word);
    if (key.isEmpty ||
        (status == VocabularyStatus.learning && translation.trim().isEmpty)) {
      throw ArgumentError('Word and learning translation cannot be empty');
    }
    final db = await DBHelper().database;
    return db.transaction((txn) async {
      final now = DateTime.now().toIso8601String();
      final words = await txn.query('tb_vocabulary_words',
          where: 'source_lang = ? AND word_key = ?', whereArgs: [source, key]);
      final wordId =
          words.isEmpty ? const Uuid().v4() : words.first['id'] as String;
      if (words.isEmpty) {
        await txn.insert('tb_vocabulary_words', {
          'id': wordId,
          'source_lang': source,
          'word_key': key,
          'word': word.trim(),
          'status': status.code,
          'updated_at': now
        });
      } else {
        await txn.update(
            'tb_vocabulary_words', {'status': status.code, 'updated_at': now},
            where: 'id = ?', whereArgs: [wordId]);
      }
      final cards = await txn.query('tb_vocabulary_cards',
          where:
              'word_id = ? AND target_lang = ? AND translation = ? AND context_text = ? AND book_id = ?',
          whereArgs: [
            wordId,
            target,
            translation.trim(),
            contextText.trim(),
            bookId
          ]);
      if (cards.isNotEmpty) return cards.first['id'] as String;
      final id = const Uuid().v4();
      await txn.insert('tb_vocabulary_cards', {
        'id': id,
        'word_id': wordId,
        'target_lang': target,
        'translation': translation.trim(),
        'context_text': contextText.trim(),
        'book_id': bookId,
        'book_title': bookTitle,
        'chapter': chapter,
        'cfi': cfi,
        'created_at': now,
        'updated_at': now
      });
      return id;
    });
  }

  Future<Map<String, String>> statuses(String sourceLanguage) async {
    final db = await DBHelper().database;
    final rows = await db.query('tb_vocabulary_words',
        where: 'source_lang = ?',
        whereArgs: [vocabularyLanguage(sourceLanguage)]);
    return {
      for (final row in rows) row['word_key'] as String: row['status'] as String
    };
  }

  Future<List<VocabularyCard>> cards(
      {String query = '', VocabularyStatus? status, int? bookId}) async {
    final db = await DBHelper().database;
    final where = <String>[], args = <Object?>[];
    if (status != null) {
      where.add('w.status = ?');
      args.add(status.code);
    }
    if (bookId != null) {
      where.add('c.book_id = ?');
      args.add(bookId);
    }
    // ponytail: filter search locally after SQL status/book filtering; add an index if the personal list becomes large.
    final rows = await db.rawQuery(
        'SELECT c.*, w.word, w.source_lang, w.status FROM tb_vocabulary_cards c JOIN tb_vocabulary_words w ON w.id = c.word_id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY c.updated_at DESC, c.id',
        args);
    final needle = query.trim().toLowerCase();
    return rows
        .map(VocabularyCard.new)
        .where((card) =>
            needle.isEmpty ||
            '${card.word} ${card.translation} ${card.contextText} ${card.bookTitle}'
                .toLowerCase()
                .contains(needle))
        .toList();
  }

  Future<void> setStatus(String wordId, VocabularyStatus status) async {
    final db = await DBHelper().database;
    if (status == VocabularyStatus.learning) {
      final cards = await db.query('tb_vocabulary_cards',
          columns: ['translation'], where: 'word_id = ?', whereArgs: [wordId]);
      if (!cards
          .any((card) => (card['translation'] as String).trim().isNotEmpty)) {
        throw ArgumentError('A learning word needs a translation');
      }
    }
    await db.update('tb_vocabulary_words',
        {'status': status.code, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [wordId]);
  }

  Future<void> editTranslation(String cardId, String translation) async {
    if (translation.trim().isEmpty) {
      throw ArgumentError('Translation cannot be empty');
    }
    final db = await DBHelper().database;
    await db.update(
        'tb_vocabulary_cards',
        {
          'translation': translation.trim(),
          'updated_at': DateTime.now().toIso8601String()
        },
        where: 'id = ?',
        whereArgs: [cardId]);
  }
}

final vocabularyDao = VocabularyDao();
