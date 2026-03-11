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
const translateBatch = async (texts, level = 'level0', pageInfo = '') => {
  try {
    const jsonStr = JSON.stringify(texts)
    const resultJson = await window.flutter_inappwebview.callHandler('translateBatch', jsonStr, level, pageInfo)
    const results = JSON.parse(resultJson)
    if (Array.isArray(results) && results.length === texts.length) {
      return results
    }
    // Fallback: if batch response is invalid, translate individually
    console.warn('Batch translate returned invalid result, falling back to individual')
    return await Promise.all(texts.map(t => translate(t)))
  } catch (error) {
    console.error('Batch translation failed, falling back to individual:', error)
    return await Promise.all(texts.map(t => translate(t)))
  }
}

export class Translator {
  #translationMode = TranslationMode.OFF
  #translationLevel = 'level0'
  #aiBatchSize = 30
  observedElements = new Set()
  #translatedElements = new WeakMap()
  #observer = null
  #pendingQueue = new Map() // element -> text
  #batchTimer = null
  #batchDelayMs = 200
  #generationId = 0
  #scrollTimer = null
  #isScrolling = false
  
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

  getTranslationMode() {
    return this.#translationMode
  }

  setTranslationLevel(level) {
    const oldLevel = this.#translationLevel
    this.#translationLevel = level
    if (oldLevel !== level) {
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

  onRelocated() {
    if (this.#translationMode === TranslationMode.OFF) return
    
    // Invalidate any flying batches & clear current queue
    this.#generationId++
    
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
    
    const text = element.innerText?.trim()
    if (!text) return
    
    // Add to batch queue instead of translating immediately
    this.#pendingQueue.set(element, text)
    this.#scheduleBatchFlush()
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
      // For both word-level and sentence-level we want to translate as much as possible 
      // in one go. We try aiBatchSize elements at a time.
      const isWordLevel = this.#translationMode === TranslationMode.INTERLINEAR && this.#translationLevel !== 'level0'
      const maxBatchSize = this.#aiBatchSize
      
      // Process chunks sequentially to avoid overwhelming the API
      // Apply translations IMMEDIATELY after each chunk finishes
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
            
            // Skip empty/failed translations or if race condition happened
            if (!translatedText || translatedText === originalText || this.#translatedElements.has(element)) {
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
      console.warn('Batch translation failed:', error)
      
      // Detailed error in translation marks
      for (const element of elements) {
        if (!this.#translatedElements.has(element)) {
          this.#translatedElements.set(element, {
            originalText: this.#pendingQueue.get(element),
            translatedText: '[Error: Translation failed]'
          })
          this.#applyTranslation(element, '[Error: Translation failed]')
        }
      }
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
      
      // Check for marker format: text with [word|translation] annotations
      if (translatedData.includes('[') && translatedData.includes('|')) {
        const markerPairs = this.#parseMarkerFormat(translatedData)
        if (markerPairs && markerPairs.length > 0) {
          this.#applyRubyTranslation(element, markerPairs)
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

  // Parse "[word|translation]" marker format into word pairs
  #parseMarkerFormat(text) {
    const pairs = []
    // Split text by marker pattern, keeping both marked and unmarked parts
    const regex = /\[([^\]|]+)\|([^\]]*)\]/g
    let lastIndex = 0
    let match
    
    while ((match = regex.exec(text)) !== null) {
      // Add unmarked text before this marker as individual words
      if (match.index > lastIndex) {
        const before = text.substring(lastIndex, match.index)
        before.split(/(\s+)/).forEach(part => {
          if (part.trim()) {
            pairs.push([part, ''])
          } else if (part) {
            pairs.push([part, ''])  // preserve whitespace
          }
        })
      }
      // Add the marked word with its translation
      pairs.push([match[1], match[2]])
      lastIndex = match.index + match[0].length
    }
    
    // Add remaining text after last marker
    if (lastIndex < text.length) {
      const remaining = text.substring(lastIndex)
      remaining.split(/(\s+)/).forEach(part => {
        if (part.trim()) {
          pairs.push([part, ''])
        } else if (part) {
          pairs.push([part, ''])
        }
      })
    }
    
    return pairs.length > 0 ? pairs : null
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
      const [original, translation] = wordPairs[i]
      
      if (translation && translation.trim()) {
        // Word with translation — use ruby element
        const ruby = document.createElement('ruby')
        ruby.className = 'anx-wordwise'
        ruby.textContent = original
        
        const rt = document.createElement('rt')
        rt.textContent = translation
        rt.style.fontSize = '0.75em'
        /* Add a bit of space so it doesn't touch the brace */
        rt.style.paddingBottom = '3px'
        rt.style.color = 'inherit'
        rt.style.opacity = '0.85'
        rt.style.fontWeight = 'normal'
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
      const rect = element.getBoundingClientRect()
      const isVisible = rect.top < window.innerHeight && rect.bottom > 0
      
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