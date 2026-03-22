enum AiPrompts {
  test,
  summaryTheChapter,
  summaryTheBook,
  summaryThePreviousContent,
  translate,
  translateBatch,
  translateBatchWordLevel,
  mindmap,
  classifyWordLevels,
}

extension AiPromptsJson on AiPrompts {
  String getPrompt() {
    switch (this) {
      case AiPrompts.test:
        return '''
Write a concise and friendly self-introduction. Use the language code: {{language_locale}}
        ''';

      case AiPrompts.summaryTheChapter:
        return '''
Summarize the chapter content. Your reply must follow these requirements:
Language: Use the same language as the original chapter content.
Length: 8-10 complete sentences.
Structure: Three paragraphs: Main plot, Core characters, Themes/messages.
Style: Avoid boilerplate phrases like "This chapter describes..."
Perspective: Maintain a literary analysis perspective, not just narration.
        ''';

      case AiPrompts.summaryTheBook:
        return '''
Generate a book summary
[Requirements]:
Language matches the book title's language
Central conflict (highlight with » symbol)
3 core characters + their motivations (name + critical choice)
Theme keywords (3-5)
Avoid spoiling the final outcome
        ''';

      case AiPrompts.summaryThePreviousContent:
        return '''
I'm revisiting a book I read long ago. Help me quickly recall the previous content to continue reading:
[Requirements]
3-5 sentences
Same language as original previous content
Avoid verbatim repetition; preserve core information

[Previous Content]
{{previous_content}}
        ''';

      case AiPrompts.translate:
        return '''
You are the Anx Reader "Translation & Reference" expert. Deliver an authoritative answer in the user's preferred language {{to_locale}}.

Input for this request:
- Source Text: {{text}}
- Source Language hint: {{from_locale}}
- Reader Context (may be empty): {{contextText}}

## Response Structure (CRITICAL)
Your response MUST follow this two-part structure:
DON'T output the skeleton or the instructions, only the final answer.

### Part 1: Quick Context-Aware Explanation (ALWAYS FIRST)
Start with 1-2 concise words that:
- Directly explain the meaning/translation in the reading context
- Address any ambiguity resolved by the context
- Use plain, conversational language
- Don't quote the source text unless necessary for clarity, and avoid excessive quoting

### Part 2: Detailed Analysis (AFTER the quick explanation)
Provide comprehensive information using the format below.

## Core Duties
1. Interpret the text precisely, using Reader Context to resolve pronouns, tone, domain knowledge, or cultural references. If no context is provided, state that you inferred meaning from the snippet alone.
2. Provide dictionary-level detail (phonetics, part of speech, nuanced senses) AND an encyclopedia-style insight (origin, cultural background, literary reference, or factual hook).
3. Offer practical guidance so the reader can use or understand the expression naturally.

## Constraints
- All responses must stay in {{to_locale}}.
- Be concise but complete; remove any template sections only when genuinely inapplicable and indicate why.
- Never output markdown lists, numbering symbols, or code fences—just localized headings and text.

## Decision Tree
- If source language matches {{to_locale}} → act as an advanced monolingual dictionary entry.
- Otherwise → act as a translator plus tutor.

## Detail (plain text, no bullet symbols, each heading MUST translated into {{to_locale}})

When acting as a dictionary (same language):
- Pronunciation: best-available phonetic transcription or note if unknown.
- Part of speech: list every relevant part of speech.
- Meanings: enumerate key senses with concise explanations.
- Examples: provide two natural example sentences with brief clarifications.
- Encyclopedia: share one contextual or cultural fact (history, literature, idiom origin, domain usage).

When acting as a translator (different languages):
- Source excerpt: quote or lightly trim the source snippet (note when shortened).
- Translation: produce a fluent translation honoring tone and register.
- Translation notes: justify critical word choices, including how context shaped them.
- Glossary: highlight 2-4 pivotal terms with short meaning notes in {{to_locale}}.
- Encyclopedia: add one background detail (culture, setting, concept) that aids understanding.
      ''';

      case AiPrompts.translateBatch:
        return '''
Translate the following JSON array of texts strictly from {{from_locale}} to {{to_locale}}.
Do not use any other language for the translation.
Return ONLY a valid JSON array of translated strings in the exact same order. No extra text, no explanations, no markdown.
Input: {{texts}}
        ''';

      case AiPrompts.translateBatchWordLevel:
        return '''
You are a language learning assistant building a translation cache.

Task: Return the ORIGINAL text but annotate EVERY meaningful word by wrapping it as [word|translation|min_level].
- "word" — the original word exactly as it appears in the text
- "translation" — the translation of that word in {{to_locale}}
- "min_level" — the CEFR level at which a learner would first need help with this word:
    0  = below A1 (so basic that even a complete beginner struggles — e.g. very short common words like "go", "big", "one")
    a1 = very common, everyday words a beginner learns first
    a2 = elementary words
    b1 = intermediate words
    b2 = upper-intermediate words
    c1 = advanced words
    c2 = very rare, academic or highly specialized words

Skip ONLY:
- Articles (a, an, the, um, uma, o, os, as…) and punctuation
- Roman numerals used as chapter numbers, section markers, or ordinals
  (e.g. "I", "II", "IV", "M", "XIV" — skip when used as numerals, not words)
- Common honorifics and abbreviations
  (e.g. "Mr.", "Mrs.", "Dr.", "Jr.", "Sr.", "Prof.", etc.)
- Proper nouns that are purely phonetic with no lexical meaning
  (e.g. "Harry", "Hermione", "London", "Dursley" — skip these)

BUT annotate proper nouns that are transparently derived from real words:
  (e.g. "Longbottom" → [Longbottom|длинное дно (long+bottom)|b1],
        "Goodman" → [Goodman|хороший человек (good+man)|a1])

Return a JSON array of annotated strings (one per input string).

Example (translating to {{to_locale}}):
Input: ["The astronomer observed a strange celestial phenomenon near Goodman street", "I", "Mr.", "XIV"]
Output: ["The [astronomer|астроном|a2] [observed|наблюдал|a1] a [strange|странный|a1] [celestial|небесный|b2] [phenomenon|явление|b1] [near|рядом с|a1] [Goodman|хороший человек (good+man)|a1] [street|улица|0]", "I", "Mr.", "XIV"]

IMPORTANT:
1. Annotate ALL meaningful words — this is a full translation cache, not filtered output.
2. CRITICAL: All translations inside brackets MUST be strictly in {{to_locale}}.
3. Do NOT skip words because they seem "easy" — assign them the correct min_level instead.
4. Skipped items (roman numerals, abbreviations, proper phonetic names) must be returned AS-IS, unchanged.
5. Return ONLY a valid JSON array, no extra text.

Input: {{texts}}
        ''';

      case AiPrompts.mindmap:
        return '''
You are the Mindmap Architect for Anx Reader. Analyze the user's current reading context and collaborate through the `mindmap_draw` tool to build a clear hierarchical visualization.

## Objectives
- Identify the central theme or focus topic
- Extract 4-7 major branches covering plot arcs, characters, concepts, or arguments
- Provide 2nd-level child nodes with concise labels (max 8 words)
- Prioritize meaningful relationships rather than exhaustive details

## Tool Usage Rules
- Always call `mindmap_draw` before replying with prose
- Populate the tool input with:
  - `title`: succinct map title
  - `nodes`: structured list of parent/child relationships
- Ensure node IDs are unique and stable within the map
- Keep labels language-consistent with the source material

## Response Formatting
After the tool call, summarize the structure in 3 bullet sentences highlighting:
1. Overall framing of the mind map
2. Key branches or clusters
3. Notable insights or tensions revealed
        ''';

      case AiPrompts.classifyWordLevels:
        return '''
You are assigning CEFR levels to vocabulary items.

Rules:
- Output ONLY valid JSON.
- Input is a JSON array of words: {{words}}
- Source language is {{from_locale}}
- Return a JSON object where each key is the original word and value is one of:
  "0", "a1", "a2", "b1", "b2", "c1", "c2", or null if uncertain.
- Do not translate. Do not add commentary.
        ''';
    }
  }
}
