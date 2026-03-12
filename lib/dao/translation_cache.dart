import 'package:anx_reader/dao/database.dart';
import 'package:flutter/foundation.dart';

/// DAO for translation cache.
/// Cache is keyed by (book_id, level, original_text).
/// Independent of AI model — same cache works across model switches.
class TranslationCacheDao {
  static final TranslationCacheDao _instance = TranslationCacheDao._internal();
  factory TranslationCacheDao() => _instance;
  TranslationCacheDao._internal();

  /// Get cached translations for a batch of texts.
  /// Returns Map<originalText, translatedText> for texts found in cache.
  Future<Map<String, String>> getTranslations(
      int bookId, String level, List<String> originals) async {
    if (originals.isEmpty) return {};
    final db = await DBHelper().database;

    // SQLite IN clause with placeholders
    final placeholders = List.filled(originals.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT original_text, translated_text FROM tb_translation_cache '
      'WHERE book_id = ? AND level = ? AND original_text IN ($placeholders)',
      [bookId, level, ...originals],
    );

    final result = <String, String>{};
    for (final row in rows) {
      result[row['original_text'] as String] = row['translated_text'] as String;
    }
    return result;
  }

  /// Save new translations to cache (INSERT OR IGNORE to preserve existing).
  Future<void> insertTranslations(
      int bookId, String level, Map<String, String> translations) async {
    if (translations.isEmpty) return;
    final db = await DBHelper().database;

    final batch = db.batch();
    final now = DateTime.now().toIso8601String();
    for (final entry in translations.entries) {
      batch.rawInsert(
        'INSERT OR IGNORE INTO tb_translation_cache '
        '(book_id, level, original_text, translated_text, create_time) '
        'VALUES (?, ?, ?, ?, ?)',
        [bookId, level, entry.key, entry.value, now],
      );
    }
    await batch.commit(noResult: true);
    debugPrint(
        '💾 [CACHE SAVE] Saved ${translations.length} translations for bookId=$bookId level=$level');
  }

  /// Clear all cached translations for a specific book.
  Future<int> clearForBook(int bookId) async {
    final db = await DBHelper().database;
    final count = await db.delete(
      'tb_translation_cache',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    debugPrint('🗑️ [CACHE CLEAR] Cleared $count entries for bookId=$bookId');
    return count;
  }

  /// Clear ALL cached translations (global reset).
  Future<int> clearAll() async {
    final db = await DBHelper().database;
    final count = await db.delete('tb_translation_cache');
    debugPrint('🗑️ [CACHE CLEAR ALL] Cleared $count entries total');
    return count;
  }

   /// Clear specific translations based on book, level and optional texts.
  Future<int> clearSpecific(int bookId,
      {String? level, List<String>? originals}) async {
    final db = await DBHelper().database;
    String where = 'book_id = ?';
    List<dynamic> whereArgs = [bookId];

    if (level != null) {
      where += ' AND level = ?';
      whereArgs.add(level);
    }

    if (originals != null && originals.isNotEmpty) {
      // SQLite IN clause with placeholders
      // Note: If too many originals, might need batching, but usually it's one page/chapter.
      final placeholders = List.filled(originals.length, '?').join(', ');
      where += ' AND original_text IN ($placeholders)';
      whereArgs.addAll(originals);
    }

    final count = await db.delete(
      'tb_translation_cache',
      where: where,
      whereArgs: whereArgs,
    );
    debugPrint(
        '🗑️ [CACHE CLEAR SPECIFIC] Cleared $count entries (bookId=$bookId, level=$level, textsCount=${originals?.length ?? 'ALL'})');
    return count;
  }

  /// Get total cache size for a book (for UI display).
  Future<int> countForBook(int bookId) async {
    final db = await DBHelper().database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM tb_translation_cache WHERE book_id = ?',
      [bookId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }
}

final translationCacheDao = TranslationCacheDao();
