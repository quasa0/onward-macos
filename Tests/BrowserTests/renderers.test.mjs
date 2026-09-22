import test from 'node:test';
import assert from 'node:assert/strict';
import { renderAX, renderDOM } from '../../BrowserExtension/ax-text.js';

test('AX preserves meaningful focused text and skips duplicates and protected fields', () => {
  const output = renderAX([
    { role: { value: 'StaticText' }, name: { value: 'Vision documentation' } },
    { role: { value: 'StaticText' }, name: { value: 'Vision documentation' } },
    { role: { value: 'InlineTextBox' }, name: { value: 'Hidden duplicate' } },
    { role: { value: 'textbox' }, value: { value: 'password' }, properties: [{ name: 'protected', value: { value: true } }] },
    { role: { value: 'textbox' }, value: { value: 'Search OCR' }, properties: [{ name: 'focused', value: { value: true } }] }
  ]);
  assert.equal(output, 'StaticText: Vision documentation\ntextbox: Search OCR [focused]');
});

test('DOM reads document text without treating scripts as activity', () => {
  const snapshot = { strings: ['DIV', 'SCRIPT', 'Build Onward', 'irrelevant code'], documents: [{ nodes: {
    nodeType: [1, 3, 1, 3], nodeName: [0, -1, 1, -1], nodeValue: [-1, 2, -1, 3], parentIndex: [-1, 0, -1, 2]
  } }] };
  assert.equal(renderDOM(snapshot), 'Build Onward');
});

test('large AX content stops at its budget with an explicit warning', () => {
  assert.equal(renderAX([{ role: { value: 'StaticText' }, name: { value: 'x'.repeat(1000) } }], 30), '[Accessibility text truncated]');
});
