const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

test('interlinear mode is available alongside upstream reading modes', async () => {
  global.IntersectionObserver = class { observe() {} disconnect() {} };
  global.window = {};
  const source = fs.readFileSync(path.join(__dirname, '../assets/foliate-js/src/translator.js'), 'utf8');
  const { Translator, TranslationMode } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  assert.equal(TranslationMode.INTERLINEAR, 'interlinear');
  const translator = new Translator();
  await translator.setTranslationMode(TranslationMode.INTERLINEAR);
  assert.equal(translator.getTranslationMode(), 'interlinear');
  translator.destroy();
});
