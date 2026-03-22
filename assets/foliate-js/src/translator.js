// Translation modes
export const TranslationMode = {
  OFF: 'off',
  TRANSLATION_ONLY: 'translation-only', 
  ORIGINAL_ONLY: 'original-only',
  BILINGUAL: 'bilingual',
  INTERLINEAR: 'interlinear'
}

// Make TranslationMode globally available for debugging
if (typeof window !== 'undefined') {
  window.TranslationMode = TranslationMode
}

// Translation function that calls Flutter's translation service (single text, fallback)
const translate = async (text) => {
  try {
    const result = await window.flutter_inappwebview.callHandler('translateText', text)
    return result || `Translation failed: ${text}`
  } catch (error) {
    console.error('Translation failed:', error)
    return `Translation error: ${text}`
  }
}

// Batch translation function — sends array of texts in one request
const translateBatch = async (texts, level = 'full', pageInfo = '') => {
  try {
    const jsonStr = JSON.stringify(texts)
    const resultJson = await window.flutter_inappwebview.callHandler('translateBatch', jsonStr, level, pageInfo)
    const results = JSON.parse(resultJson)
    if (Array.isArray(results) && results.length === texts.length) {
      return results
    }
    // Do not fan out into N single requests after a failed batch:
    // it can create retry storms on provider/API errors.
    console.warn('Batch translate returned invalid result, skipping individual fallback')
    return Array(texts.length).fill('__ANX_ERROR__')
  } catch (error) {
    console.error('Batch translation failed, skipping individual fallback:', error)
    return Array(texts.length).fill('__ANX_ERROR__')
  }
}

export class Translator {
  #translationMode = TranslationMode.OFF
  #translationColorEnabled = false
  #translationLevelColors = {}
  #translationLevel = 'full'
  #aiBatchSize = 30
  #aiWorkers = 1
  observedElements = new Set()
  #translatedElements = new WeakMap()
  #observer = null
  #pendingQueue = new Map() // element -> text
  #batchTimer = null
  #batchDelayMs = 200
  #generationId = 0
  #scrollTimer = null
  #isScrolling = false
  #retryAttempts = new WeakMap()
  #rateLimitRetryAttempts = new WeakMap()
  #blockedUntilRelocation = new WeakSet()
  #maxImmediateRetryAttempts = 5
  
  constructor() {
    this.#initializeObserver()
  }

  #initializeObserver() {
    this.#observer = new IntersectionObserver(
      (entries) => {
        // console.log(`IntersectionObserver triggered with ${entries.length} entries`)
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            // console.log('Element intersecting, translating:', entry.target.tagName, entry.target.textContent?.substring(0, 30))
            this.#translateElement(entry.target).catch(error => 
              console.warn('Translation failed in observer:', error)
            )
          }
        })
      },
      {
        rootMargin: '50%',
        threshold: 0
      }
    )
  }

  async setTranslationMode(mode) {
    if (!Object.values(TranslationMode).includes(mode)) {
      console.warn(`Invalid translation mode: ${mode}`)
      return
    }
    
    const oldMode = this.#translationMode
    this.#translationMode = mode
    
    if (oldMode !== mode) {
      // console.log(`Translation mode changed from ${oldMode} to ${mode}`)
      
      if (mode === TranslationMode.OFF) {
        // Turn off translation
        this.#updateTranslationDisplay()
      } else if (oldMode === TranslationMode.OFF) {
        // Turn on translation - force translate visible elements and wait for completion
        await this.#forceTranslateVisibleElements()
      } else {
        // Just update display mode
        this.#updateTranslationDisplay()
      }
    }

    // Re-render annotations after translation mode change (and after translation completion)
    if (window.reader && window.reader.annotationsByValue) {
      const existingAnnotations = Array.from(window.reader.annotationsByValue.values())
      if (existingAnnotations.length > 0) {
        // console.log('Re-rendering annotations after translation mode change:', existingAnnotations.length)
        window.renderAnnotations(existingAnnotations)
      }
    }
  }

  setTranslationColors(enabled, jsonColors) {
    let changed = false
    if (this.#translationColorEnabled !== enabled) {
      this.#translationColorEnabled = enabled
      changed = true
    }
    if (jsonColors) {
      try {
        const colors = JSON.parse(jsonColors)
        if (JSON.stringify(this.#translationLevelColors) !== JSON.stringify(colors)) {
          this.#translationLevelColors = colors
          changed = true
        }
      } catch (e) {
        console.error('Failed to parse translation colors', e)
      }
    }
    
    if (changed) {
      // Dynamically re-apply colors to existing elements
      this.observedElements.forEach(element => {
        const transWrappers = element.querySelectorAll('.translated-text')
        transWrappers.forEach(wrapper => {
          const rubys = wrapper.querySelectorAll('ruby.anx-wordwise')
          rubys.forEach(ruby => {
            const rt = ruby.querySelector('rt')
            if (rt) {
              const minLevel = rt.getAttribute('data-level')
              if (this.#translationColorEnabled && minLevel && this.#translationLevelColors[minLevel.toLowerCase()]) {
                rt.style.color = this.#translationLevelColors[minLevel.toLowerCase()]
                rt.style.fontWeight = 'bold'
              } else {
                rt.style.color = 'inherit'
                rt.style.fontWeight = 'normal'
              }
            }
          })
        })
      })
      this.#updateTranslationDisplay()
    }
  }

  getTranslationMode() {
    return this.#translationMode
  }

  setTranslationLevel(level) {
    const oldLevel = this.#translationLevel
    this.#translationLevel = level
    if (oldLevel !== level) {
      const isWordLevel = l => l && l !== 'full'
      
      if (isWordLevel(oldLevel) && isWordLevel(level)) {
        // Both are word levels. No need to clear queues or re-fetch.
        // Just re-render already translated elements to apply the new visibility filter.
        this.observedElements.forEach(element => {
          const data = this.#translatedElements.get(element)
          if (data && data.translatedText) {
            this.#applyTranslation(element, data.translatedText)
          }
        })
        // Update display according to translation mode
        this.#updateTranslationDisplay()
        return
      }

      // Soft reset: remove visual translations but keep observer alive
      if (this.#batchTimer) {
        clearTimeout(this.#batchTimer)
        this.#batchTimer = null
      }
      this.#pendingQueue.clear()
      
      // Remove visual translation elements and restore original text
      this.observedElements.forEach(element => {
        const translationElements = element.querySelectorAll('.translated-text')
        translationElements.forEach(trans => trans.remove())
        this.#restoreOriginalText(element)
      })
      
      // Reset translated tracking (but keep observedElements & observer intact)
      this.#translatedElements = new WeakMap()
      
      // Re-translate with new level
      this.#generationId++ // Invalidate any flying batches
      if (this.#translationMode !== TranslationMode.OFF) {
        this.#forceTranslateVisibleElements()
      }
    }
  }

  setAiBatchSize(size) {
    if (typeof size === 'number' && size > 0) {
      this.#aiBatchSize = size
    }
  }

  setAiWorkers(n) {
    if (typeof n === 'number' && n >= 1) {
      this.#aiWorkers = Math.floor(n)
    }
  }


  onRelocated() {
    if (this.#translationMode === TranslationMode.OFF) return
    
    // Invalidate any flying batches & clear current queue
    this.#generationId++
    this.#retryAttempts = new WeakMap()
    this.#rateLimitRetryAttempts = new WeakMap()
    this.#blockedUntilRelocation = new WeakSet()
    
    if (this.#batchTimer) {
      clearTimeout(this.#batchTimer)
      this.#batchTimer = null
    }
    this.#pendingQueue.clear()
    
    // Set scrolling flag and debounce
    this.#isScrolling = true
    if (this.#scrollTimer) clearTimeout(this.#scrollTimer)
    this.#scrollTimer = setTimeout(() => {
      this.#isScrolling = false
      // Retrigger check for observed visible elements
      this.#forceTranslateVisibleElements()
    }, 2000)
  }

  cancelAndClear() {
    this.#pendingQueue.clear()
    this.#generationId++ 
    if (this.#batchTimer) {
      clearTimeout(this.#batchTimer)
      this.#batchTimer = null
    }
  }

  getTranslationLevel() {
    return this.#translationLevel
  }

  #getElementGlobalRect(element) {
    const localRect = element.getBoundingClientRect()

    let globalRect = {
      top: localRect.top,
      bottom: localRect.bottom,
      left: localRect.left,
      right: localRect.right
    }

    // Account for iframe offset: element rect is local to iframe viewport.
    try {
      const frame = element.ownerDocument?.defaultView?.frameElement
      if (frame && typeof frame.getBoundingClientRect === 'function') {
        const frameRect = frame.getBoundingClientRect()
        globalRect = {
          top: localRect.top + frameRect.top,
          bottom: localRect.bottom + frameRect.top,
          left: localRect.left + frameRect.left,
          right: localRect.right + frameRect.left
        }
      }
    } catch (_) {}

    return globalRect
  }

  #getViewportSizeForElement(element) {
    let viewportWidth = window.innerWidth
    let viewportHeight = window.innerHeight
    try {
      const frame = element.ownerDocument?.defaultView?.frameElement
      if (frame) {
        viewportWidth = globalThis.top?.innerWidth ?? viewportWidth
        viewportHeight = globalThis.top?.innerHeight ?? viewportHeight
      }
    } catch (_) {}
    return { viewportWidth, viewportHeight }
  }

  #isCurrentlyVisible(element) {
    const globalRect = this.#getElementGlobalRect(element)
    const { viewportWidth, viewportHeight } = this.#getViewportSizeForElement(element)
    return (
      globalRect.top < viewportHeight &&
      globalRect.bottom > 0 &&
      globalRect.left < viewportWidth &&
      globalRect.right > 0
    )
  }

  #isWithinTranslateWindow(element) {
    const globalRect = this.#getElementGlobalRect(element)
    const { viewportWidth, viewportHeight } = this.#getViewportSizeForElement(element)

    const maxAheadX = viewportWidth
    const maxAheadY = viewportHeight
    const isRtl = (document?.documentElement?.dir || '').toLowerCase() === 'rtl'

    // Vertical range: current viewport + one viewport ahead (down)
    const withinY =
      globalRect.top < viewportHeight + maxAheadY && globalRect.bottom > 0

    // Horizontal range: current page + next page (direction-aware)
    let withinX = false
    if (isRtl) {
      withinX = globalRect.left < viewportWidth && globalRect.right > -maxAheadX
    } else {
      withinX =
        globalRect.left < viewportWidth + maxAheadX && globalRect.right > 0
    }

    return withinX && withinY
  }

  #isWordLevelExpected() {
    return this.#translationMode === TranslationMode.INTERLINEAR &&
      this.#translationLevel !== 'full'
  }

  #hasWordLevelMarkers(text) {
    if (!text || typeof text !== 'string') return false
    const trimmed = text.trim()
    if (!trimmed) return false

    // JSON word-pairs format
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
      try {
        const parsed = JSON.parse(trimmed)
        if (Array.isArray(parsed) && parsed.length > 0 && Array.isArray(parsed[0])) {
          return true
        }
      } catch (_) {}
    }

    // Marker format: [word|translation] or [word|translation|level]
    return trimmed.includes('[') && trimmed.includes('|') && trimmed.includes(']')
  }

  #markNoTranslation(element, originalText) {
    if (this.#translatedElements.has(element)) return
    this.#translatedElements.set(element, {
      originalText: originalText,
      translatedText: '',
      noTranslation: true
    })
  }

  observeDocument(doc) {
    // console.log('Observing document for translation, doc:', doc)
    if (!doc) {
      console.warn('No document provided to observeDocument')
      return
    }
        
    const textElements = this.#walkTextNodes(doc.body || doc.documentElement)
    // console.log(`Found ${textElements.length} text elements to observe`)
    
    textElements.forEach(element => {
      if (!this.observedElements.has(element)) {
        this.#observer.observe(element)
        this.observedElements.add(element)
        // console.log('Added element to observer:', element.tagName, element.textContent?.substring(0, 50))
      }
    })
    
    // console.log(`Total observed elements: ${this.observedElements.size}`)
  }

  clearTranslations() {
    // Cancel any pending batch
    if (this.#batchTimer) {
      clearTimeout(this.#batchTimer)
      this.#batchTimer = null
    }
    this.#pendingQueue.clear()
    
    // Remove all translation elements and restore original content
    this.observedElements.forEach(element => {
      const translationElements = element.querySelectorAll('.translated-text')
      translationElements.forEach(trans => trans.remove())
      
      // Restore original text if hidden
      this.#restoreOriginalText(element)
    })
    
    // Clear observer
    this.#observer.disconnect()
    this.observedElements.clear()
    this.#translatedElements = new WeakMap()
    
    // Reinitialize observer
    this.#initializeObserver()
  }

  retranslateAll() {
    this.#generationId++
    if (this.#batchTimer) {
      clearTimeout(this.#batchTimer)
      this.#batchTimer = null
    }
    this.#pendingQueue.clear()

    // Remove stale translation overlays so cleared cache is reflected immediately.
    this.observedElements.forEach(element => {
      const translationElements = element.querySelectorAll('.translated-text')
      translationElements.forEach(trans => trans.remove())
      this.#restoreOriginalText(element)
    })

    this.#translatedElements = new WeakMap()
    this.#retryAttempts = new WeakMap()
    this.#rateLimitRetryAttempts = new WeakMap()
    this.#blockedUntilRelocation = new WeakSet()

    if (this.#translationMode !== TranslationMode.OFF) {
      this.#forceTranslateVisibleElements().catch(error =>
        console.warn('Retranslate after cache clear failed:', error)
      )
    }
  }

  getVisibleOriginalTexts() {
    const texts = new Set()

    this.observedElements.forEach(element => {
      // "Current page" must use real top-level viewport coordinates.
      if (this.#isCurrentlyVisible(element)) {
        const text = this.#getElementOriginalText(element)
        if (text) texts.add(text)
      }
    })
    return Array.from(texts)
  }

  getChapterOriginalTexts() {
    const texts = new Set()
    this.observedElements.forEach(element => {
      const text = this.#getElementOriginalText(element)
      if (text) texts.add(text)
    })
    return Array.from(texts)
  }

  #getElementOriginalText(element) {
    const data = this.#translatedElements.get(element)
    if (data && data.originalText) {
      return data.originalText
    }
    return element.innerText?.trim()
  }

  #walkTextNodes(root, rejectTags = ['pre', 'code', 'math', 'style', 'script']) {
    const elements = []
    
    const walk = (node, depth = 0) => {
      if (depth > 15) return
      
      const children = Array.from(node.children || [])
      for (const child of children) {
        if (rejectTags.includes(child.tagName.toLowerCase())) {
          continue
        }
        
        // Skip translation elements
        if (child.classList.contains('translated-text')) {
          continue
        }
        
        const hasDirectText = Array.from(child.childNodes).some(node => {
          if (node.nodeType === Node.TEXT_NODE && node.textContent?.trim()) {
            return true
          }
          if (node.nodeType === Node.ELEMENT_NODE && node.tagName === 'SPAN') {
            return true
          }
          return false
        })
        
        if (child.children.length === 0 && child.textContent?.trim()) {
          elements.push(child)
        } else if (hasDirectText) {
          elements.push(child)
        } else if (child.children.length > 0) {
          walk(child, depth + 1)
        }
      }
    }
    
    walk(root)
    return elements
  }

  async #translateElement(element) {
    if (this.#translationMode === TranslationMode.OFF) return
    if (this.#translatedElements.has(element)) return
    if (this.#blockedUntilRelocation.has(element)) return
    
    if (!this.#isWithinTranslateWindow(element)) return

    const text = element.innerText?.trim()
    if (!text) return
    
    // Check local cache instantly first before adding to AI processing queue
    try {
      const cacheResultJson = await window.flutter_inappwebview.callHandler('checkTranslationCache', JSON.stringify([text]), this.#translationLevel)
      const cacheResult = JSON.parse(cacheResultJson || '{}')

      if (cacheResult && Object.prototype.hasOwnProperty.call(cacheResult, text)) {
        // Cache Hit: Render instantly without batch delays
        const cachedTranslation = (cacheResult[text] ?? '').toString()
        const trimmedCached = cachedTranslation.trim()

        // Empty cached value means "translation not needed" (intentional no-translation hit).
        if (!trimmedCached) {
          this.#markNoTranslation(element, text)
          return
        }

        const isInvalidWordLevelCache =
          this.#isWordLevelExpected() &&
          (trimmedCached === text || !this.#hasWordLevelMarkers(trimmedCached))

        if (isInvalidWordLevelCache) {
          // Treat invalid/stale cache as miss so it can be repaired by AI.
          // Continue below to enqueue for fresh translation.
        } else {
          this.#translatedElements.set(element, {
            originalText: text,
            translatedText: trimmedCached
          })
          this.#applyTranslation(element, trimmedCached)
          return
        }
      }
    } catch (e) {
      console.warn('Cache check failed:', e)
    }

    // Cache Miss: Add to batch queue for AI translation that waits for scroll stop
    this.#pendingQueue.set(element, text)
    this.#scheduleBatchFlush()
  }

  #scheduleRetry(element, text, { isRateLimit = false } = {}) {
    if (this.#translatedElements.has(element)) return
    if (this.#blockedUntilRelocation.has(element)) return

    const currentAttempts = this.#retryAttempts.get(element) || 0
    const generationAtSchedule = this.#generationId

    if (!isRateLimit && currentAttempts >= this.#maxImmediateRetryAttempts) {
      // Stop retrying this element until user relocates (page turn/scroll settle).
      this.#blockedUntilRelocation.add(element)
      this.#emitRetryInfo({
        attempt: currentAttempts,
        delayMs: 0,
        isRateLimit: false,
        text,
        isBlocked: true
      })
      return
    }

    let attemptForLog = 0
    let nextAttempts = currentAttempts
    if (isRateLimit) {
      const currentRateLimitAttempts = this.#rateLimitRetryAttempts.get(element) || 0
      attemptForLog = currentRateLimitAttempts + 1
      this.#rateLimitRetryAttempts.set(element, attemptForLog)
    } else {
      nextAttempts = currentAttempts + 1
      this.#retryAttempts.set(element, nextAttempts)
      attemptForLog = nextAttempts
    }

    const delayMs = isRateLimit
      ? 60000
      : Math.min(5000, 600 * nextAttempts)

    this.#emitRetryInfo({
      attempt: attemptForLog,
      delayMs,
      isRateLimit,
      text,
      isBlocked: false
    })

    setTimeout(() => {
      if (this.#generationId !== generationAtSchedule) return
      if (this.#translationMode === TranslationMode.OFF) return
      if (this.#translatedElements.has(element)) return
      if (this.#blockedUntilRelocation.has(element)) return
      this.#pendingQueue.set(element, text)
      this.#scheduleBatchFlush()
    }, delayMs)
  }

  #emitRetryInfo({ attempt, delayMs, isRateLimit, text, isBlocked = false }) {
    const maxAttempts = this.#maxImmediateRetryAttempts
    const summary = isBlocked
      ? `[ANX RETRY] stopped at ${attempt}/${maxAttempts} until relocate`
      : isRateLimit
        ? `[ANX RETRY] rate-limit retry #${attempt} in ${Math.round(delayMs / 1000)}s`
        : `[ANX RETRY] retry #${attempt}/${maxAttempts} in ${delayMs}ms`
    console.info(summary)

    try {
      const bridge = window.flutter_inappwebview
      if (!bridge || typeof bridge.callHandler !== 'function') return

      const promise = bridge.callHandler('onTranslationRetry', {
        attempt,
        maxAttempts,
        delayMs,
        isRateLimit,
        isBlocked,
        textPreview: typeof text === 'string' ? text.slice(0, 180) : ''
      })
      if (promise && typeof promise.catch === 'function') {
        promise.catch(() => {})
      }
    } catch (_) {}
  }

  #scheduleBatchFlush() {
    if (this.#isScrolling) return
    
    if (this.#batchTimer) {
      clearTimeout(this.#batchTimer)
    }
    this.#batchTimer = setTimeout(() => {
      this.#flushBatchQueue()
    }, this.#batchDelayMs)
  }

  async #flushBatchQueue() {
    this.#batchTimer = null
    if (this.#pendingQueue.size === 0) return
    
    // Snapshot and clear the queue
    const batch = new Map(this.#pendingQueue)
    this.#pendingQueue.clear()
    const currentGen = this.#generationId
    
    const elements = Array.from(batch.keys())
    const texts = Array.from(batch.values())

    try {
      const maxBatchSize = this.#aiBatchSize
      const n = Math.max(1, this.#aiWorkers)
      // Divide texts into N groups for parallel processing
      const groupSize = Math.ceil(texts.length / n)
      const chunkPromises = []
      for (let i = 0; i < texts.length; i += groupSize) {
        const chunkTexts = texts.slice(i, i + groupSize)
        const chunkElements = elements.slice(i, i + groupSize)
        chunkPromises.push(this.#processChunk(chunkTexts, chunkElements, currentGen, maxBatchSize))
      }
      await Promise.all(chunkPromises)
    } catch (error) {
      console.warn('Batch translation failed:', error)
    }
  }

  // Process a single chunk of elements (sequential batches within the chunk)
  async #processChunk(texts, elements, currentGen, maxBatchSize) {
    try {
      for (let start = 0; start < texts.length; start += maxBatchSize) {
        if (this.#generationId !== currentGen) return // aborted by scroll/level change
        const chunkLength = Math.min(maxBatchSize, texts.length - start)
        const chunkTexts = texts.slice(start, start + chunkLength)
        const chunkElements = elements.slice(start, start + chunkLength)

        let pageTypes = new Set();
        for (let i = 0; i < chunkElements.length; i++) {
          const rect = chunkElements[i].getBoundingClientRect();
          if (rect.bottom < 0 || rect.right < 0) {
            pageTypes.add("Prev");
          } else if (rect.top >= window.innerHeight || rect.left >= window.innerWidth) {
            pageTypes.add("Next");
          } else {
            pageTypes.add("Current");
          }
        }
        const pageInfo = Array.from(pageTypes).join(", ");
        
        try {
          const chunkTranslations = await translateBatch(chunkTexts, this.#translationLevel, pageInfo)
          
          for (let i = 0; i < chunkElements.length; i++) {
            const element = chunkElements[i]
            const originalText = chunkTexts[i]
            const translatedText = chunkTranslations[i]
            
            // Skip if race condition happened
            if (this.#translatedElements.has(element)) {
              continue
            }

            if (translatedText === '__ANX_RATE_LIMIT__') {
              this.#scheduleRetry(element, originalText, { isRateLimit: true })
              continue
            }

            if (translatedText === '__ANX_ERROR__' || translatedText === '__ANX_RETRY__') {
              this.#scheduleRetry(element, originalText)
              continue
            }

            if (translatedText === '__ANX_CANCELLED__') {
              // Do not mark as translated; allow future queue rebuild after relocation.
              continue
            }

            if (!translatedText || translatedText.trim() === '') {
              this.#markNoTranslation(element, originalText)
              continue
            }

            if (translatedText.trim() === originalText) {
              this.#markNoTranslation(element, originalText)
              continue
            }

            if (this.#isWordLevelExpected() && !this.#hasWordLevelMarkers(translatedText)) {
              this.#scheduleRetry(element, originalText)
              continue
            }
            
            // Mark as translated
            this.#translatedElements.set(element, {
              originalText: originalText,
              translatedText: translatedText
            })
            
            this.#applyTranslation(element, translatedText)
          }
        } catch (error) {
          console.error('Translation chunk failed:', error)
        }
      }
    } catch (error) {
      console.warn('processChunk failed:', error)
    }
  }

  #applyTranslation(element, translatedData) {
    // Remove existing translation if any
    const existingTranslation = element.querySelector('.translated-text')
    if (existingTranslation) {
      existingTranslation.remove()
    }
    
    // Interlinear mode: try ruby/marker rendering
    if (this.#translationMode === TranslationMode.INTERLINEAR) {
      // Try to parse as word pairs JSON
      let wordPairs = null
      try {
        const parsed = JSON.parse(translatedData)
        if (Array.isArray(parsed) && parsed.length > 0 && Array.isArray(parsed[0])) {
          wordPairs = parsed
        }
      } catch (_) {}
      
      if (wordPairs) {
        this.#applyRubyTranslation(element, wordPairs)
        return
      }
      
      // Check for marker format: text with [word|translation] or [word|translation|level] annotations
      if (translatedData.includes('[') && translatedData.includes('|')) {
        const markerPairs = this.#parseMarkerFormat(translatedData)
        if (markerPairs && markerPairs.length > 0) {
          // Apply level filtering for unified word_wise cache
          const filteredPairs = this.#filterByLevel(markerPairs, this.#translationLevel)
          this.#applyRubyTranslation(element, filteredPairs)
          return
        }
      }
      
      // Fallback for interlinear: full-sentence ruby block above original
      this.#applyRubyBlockTranslation(element, translatedData)
      return
    }
    
    // All other modes: plain block translation
    this.#applyBlockTranslation(element, translatedData)
  }

  // Parse "[word|translation]" or "[word|translation|min_level]" marker format into word pairs
  // Returns array of [original, translation, minLevel?] triples
  #parseMarkerFormat(text) {
    const pairs = []
    // Refined regex handles:
    // 1. [word|trans] or [word|trans|level] - valid
    // 2. [word|trans} - wrong bracket
    // 3. [word|trans - missing bracket (stops at space/end)
    // 4. [word|] - empty translation (handles errors from AI like [um|])
    const regex = /\[([^\[\]|]+)\|([^\[\]|]*)(?:\|\s*([a-z0-9]*)\s*)?[\]\}]?/gi
    let lastIndex = 0
    let match
    
    while ((match = regex.exec(text)) !== null) {
      // Add unmarked text before this marker as individual words
      if (match.index > lastIndex) {
        const before = text.substring(lastIndex, match.index)
        before.split(/(\s+)/).forEach(part => {
          if (part.trim()) {
            pairs.push([part, '', null])
          } else if (part) {
            pairs.push([part, '', null])  // preserve whitespace
          }
        })
      }
      // match[1]=original, match[2]=translation, match[3]=minLevel (may be undefined)
      pairs.push([match[1], match[2], match[3] || null])
      lastIndex = match.index + match[0].length
    }
    
    // Add remaining text after last marker
    if (lastIndex < text.length) {
      const remaining = text.substring(lastIndex)
      remaining.split(/(\s+)/).forEach(part => {
        if (part.trim()) {
          pairs.push([part, '', null])
        } else if (part) {
          pairs.push([part, '', null])  // preserve whitespace
        }
      })
    }
    
    return pairs.length > 0 ? pairs : null
  }

  // Filter word pairs by current reader level:
  // show translation only for words the reader at currentLevel likely doesn't know
  #filterByLevel(pairs, currentLevel) {
    if (!currentLevel || currentLevel === 'full' || currentLevel === 'level0') return pairs
    const levelOrder = ['0', 'a1', 'a2', 'b1', 'b2', 'c1', 'c2']
    const currentIdx = levelOrder.indexOf(currentLevel.toLowerCase())
    if (currentIdx < 0) return pairs // unknown level — show everything
    return pairs.map(([word, trans, minLevel]) => {
      if (!minLevel) return [word, trans, null] // no level info — always show
      const minIdx = levelOrder.indexOf(minLevel.toLowerCase())
      if (minIdx < 0) return [word, trans, minLevel] // unknown minLevel — show
      // Show translation if reader's level <= min level at which this word is "easy"
      return minIdx >= currentIdx ? [word, trans, minLevel] : [word, '', minLevel]
    })
  }

  #injectWordWiseStyles(doc) {
    if (doc.getElementById('anx-wordwise-style')) return
    const style = doc.createElement('style')
    style.id = 'anx-wordwise-style'
    style.textContent = `
      /* 
       * Draw the Word Wise brace using SVG:
       * M0,4 - left endpoint (down)
       * Q0,0 4,0 - curve up to straight line
       * L46,0 - straight line to middle
       * Q49,0 50,-4 - curve up to the middle peak (up)
       * Q51,0 54,0 - curve down to straight line
       * L96,0 - straight line to right
       * Q100,0 100,4 - curve down to right endpoint (down)
       */
      ruby.anx-wordwise {
        position: relative;
        /* create some space above the text for the brace */
        padding-top: 6px; 
      }
      ruby.anx-wordwise::before {
        content: '';
        position: absolute;
        left: 0;
        right: 0;
        /* push it slightly down so it sits right above the base word and below the translation */
        top: 3px;
        height: 5px;
        /* Use SVG for the brace */
        background-image: url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='100' height='5' viewBox='0 -4 100 8' preserveAspectRatio='none'%3E%3Cpath d='M0,4 Q0,0 4,0 L46,0 Q49,0 50,-4 Q51,0 54,0 L96,0 Q100,0 100,4' fill='none' stroke='%23a0a0a0' stroke-width='1' vector-effect='non-scaling-stroke'/%3E%3C/svg%3E");
        background-position: center top;
        background-repeat: no-repeat;
        background-size: 100% 100%;
        pointer-events: none;
      }

    `
    doc.head.appendChild(style)
  }

  #applyRubyTranslation(element, wordPairs) {
    this.#injectWordWiseStyles(element.ownerDocument)
    // Create a wrapper that replaces original content with ruby-annotated words
    const wrapper = document.createElement('span')
    wrapper.className = 'translated-text'
    wrapper.setAttribute('data-translation-mark', '1')
    wrapper.style.display = 'inline'
    
    for (let i = 0; i < wordPairs.length; i++) {
      const [original, translation, minLevel] = wordPairs[i]
      
      // Empty translations (like [um|] from parser errors) fall back to just the original word
      if (translation && translation.trim()) {
        // Word with translation — use ruby element (even if translation is empty, it helps layout spacing or highlighting)
        const ruby = document.createElement('ruby')
        ruby.className = 'anx-wordwise'
        ruby.textContent = original
        
        const rt = document.createElement('rt')
        rt.textContent = translation
        rt.style.fontSize = '0.75em'
        /* Add a bit of space so it doesn't touch the brace */
        rt.style.paddingBottom = '3px'
        
        if (minLevel) {
          rt.setAttribute('data-level', minLevel)
        }
        
        if (this.#translationColorEnabled && minLevel && this.#translationLevelColors[minLevel.toLowerCase()]) {
          rt.style.color = this.#translationLevelColors[minLevel.toLowerCase()]
          rt.style.fontWeight = 'bold'
        } else {
          rt.style.color = 'inherit'
          rt.style.fontWeight = 'normal'
        }
        
        rt.style.opacity = '0.85'
        rt.style.fontStyle = 'normal'

        ruby.appendChild(rt)
        wrapper.appendChild(ruby)
      } else {
        // Word without translation — just the word
        const span = document.createElement('span')
        span.textContent = original
        wrapper.appendChild(span)
      }
      
      // Add space between words (except after last)
      if (i < wordPairs.length - 1) {
        wrapper.appendChild(document.createTextNode(' '))
      }
    }
    
    // Apply display mode
    this.#updateElementDisplay(element, wrapper)
    
    // Insert before original content
    element.insertBefore(wrapper, element.firstChild)
  }

  // Plain block translation for bilingual/translation-only modes
  // Renders translated text as a separate block above/below original
  #applyBlockTranslation(element, translatedText) {
    const wrapper = document.createElement('div')
    wrapper.className = 'translated-text'
    wrapper.setAttribute('data-translation-mark', '1')
    wrapper.textContent = translatedText
    wrapper.style.fontSize = '0.85em'
    wrapper.style.color = 'var(--original-color, inherit)'
    wrapper.style.opacity = '0.85'
    wrapper.style.marginBottom = '0.25em'
    wrapper.style.fontStyle = 'italic'
    
    this.#updateElementDisplay(element, wrapper)
    element.insertBefore(wrapper, element.firstChild)
  }

  // Interlinear block translation: full sentence rendered as ruby above original
  #applyRubyBlockTranslation(element, translatedText) {
    const wrapper = document.createElement('span')
    wrapper.className = 'translated-text'
    wrapper.setAttribute('data-translation-mark', '1')
    wrapper.style.display = 'inline'
    
    const ruby = document.createElement('ruby')
    
    // Clone original content into ruby base
    Array.from(element.childNodes).forEach(node => {
      if (!node.classList || !node.classList.contains('translated-text')) {
        ruby.appendChild(node.cloneNode(true))
      }
    })
    
    // Translation annotation above
    const rt = document.createElement('rt')
    rt.textContent = translatedText
    rt.style.fontSize = '0.8em'
    rt.style.color = 'inherit'
    rt.style.opacity = '0.85'
    rt.style.fontWeight = 'normal'
    rt.style.fontStyle = 'italic'
    
    ruby.appendChild(rt)
    wrapper.appendChild(ruby)
    
    this.#updateElementDisplay(element, wrapper)
    element.insertBefore(wrapper, element.firstChild)
  }

  #updateElementDisplay(element, translationWrapper) {
    const data = this.#translatedElements.get(element)
    if (!data) return
    
    const isRuby = translationWrapper.querySelector('ruby') !== null
    
    switch (this.#translationMode) {
      case TranslationMode.TRANSLATION_ONLY:
        this.#hideOriginalText(element)
        translationWrapper.style.display = isRuby ? 'inline' : 'block'
        break
        
      case TranslationMode.ORIGINAL_ONLY:
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'none'
        break
        
      case TranslationMode.BILINGUAL:
        // Simple bilingual: show original + block translation above
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'block'
        break

      case TranslationMode.INTERLINEAR:
        // Ruby mode: wrapper contains original + annotations, hide raw original text
        this.#hideOriginalText(element)
        translationWrapper.style.display = 'inline'
        break
        
      case TranslationMode.OFF:
      default:
        this.#restoreOriginalText(element)
        translationWrapper.style.display = 'none'
        break
    }
  }

  #hideOriginalText(element) {
    // Use CSS to hide original content instead of removing DOM nodes
    if (!element.hasAttribute('data-original-visibility')) {
      element.setAttribute('data-original-visibility', 'hidden')
      
      // Hide all child nodes except translation elements using CSS
      Array.from(element.childNodes).forEach(node => {
        if (node.nodeType === Node.ELEMENT_NODE) {
          const el = node
          if (!el.classList || !el.classList.contains('translated-text')) {
            // Store and hide using CSS
            if (!el.hasAttribute('data-original-display')) {
              el.setAttribute('data-original-display', el.style.display || 'initial')
              el.style.display = 'none'
            }
          }
        } else if (node.nodeType === Node.TEXT_NODE) {
          // For text nodes, store content and make invisible
          if (!node.__originalContent) {
            node.__originalContent = node.textContent
            node.textContent = ''
          }
        }
      })
    }
    
    // Mark element as having hidden text
    element.classList.add('translation-source-hidden')
  }

  #restoreOriginalText(element) {
    // Restore visibility by reversing the hide operations
    if (element.hasAttribute('data-original-visibility')) {
      // Restore all child nodes
      Array.from(element.childNodes).forEach(node => {
        if (node.nodeType === Node.ELEMENT_NODE) {
          const el = node
          if (!el.classList || !el.classList.contains('translated-text')) {
            // Restore original display
            if (el.hasAttribute('data-original-display')) {
              const originalDisplay = el.getAttribute('data-original-display')
              el.style.display = originalDisplay === 'initial' ? '' : originalDisplay
              el.removeAttribute('data-original-display')
            }
          }
        } else if (node.nodeType === Node.TEXT_NODE) {
          // Restore text content
          if (node.__originalContent !== undefined) {
            node.textContent = node.__originalContent
            delete node.__originalContent
          }
        }
      })
      
      element.removeAttribute('data-original-visibility')
    }
    
    element.classList.remove('translation-source-hidden')
  }

  async #forceTranslateVisibleElements() {
    // Queue all visible untranslated elements for batch translation
    this.observedElements.forEach(element => {
      const isVisible = this.#isWithinTranslateWindow(element)
      
      if (isVisible && !this.#translatedElements.has(element)) {
        const text = element.innerText?.trim()
        if (text) {
          this.#pendingQueue.set(element, text)
        }
      } else if (isVisible && this.#translatedElements.has(element)) {
        // Element already translated, just update display
        const translationWrapper = element.querySelector('.translated-text')
        if (translationWrapper) {
          this.#updateElementDisplay(element, translationWrapper)
        }
      }
    })
    
    // Flush the batch immediately (no debounce for force translate)
    if (this.#pendingQueue.size > 0) {
      await this.#flushBatchQueue()
    }
  }

  #updateTranslationDisplay() {
    // console.log('Updating translation display for mode:', this.#translationMode, 'Elements:', this.observedElements.size)
    this.observedElements.forEach(element => {
      const translationWrapper = element.querySelector('.translated-text')
      if (translationWrapper) {
        // console.log('Updating display for element with translation:', element)
        this.#updateElementDisplay(element, translationWrapper)
      } else {
        // console.log('No translation wrapper found for element:', element)
      }
    })
  }

  destroy() {
    this.clearTranslations()
    this.#observer = null
  }
}
