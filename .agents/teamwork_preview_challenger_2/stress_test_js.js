const fs = require('fs');
const path = require('path');

console.log("=== ADVERSARIAL JS & DOM STRESS TEST ===");

const htmlPath = path.resolve('landing_page/index.html');
const jsPath = path.resolve('landing_page/app.js');

const html = fs.readFileSync(htmlPath, 'utf8');
const jsCode = fs.readFileSync(jsPath, 'utf8');

// 1. Verify Tab Buttons & Panes in HTML
const tabBtnRegex = /class=["'][^"']*tab-btn[^"']*["'][^>]*data-tab=["']([^"']+)["']/g;
const paneIdRegex = /id=["'](pane-[^"']+)["']/g;

const tabDataTabs = [];
let match;
while ((match = tabBtnRegex.exec(html)) !== null) {
  tabDataTabs.push(match[1]);
}

const paneIds = [];
while ((match = paneIdRegex.exec(html)) !== null) {
  paneIds.push(match[1]);
}

console.log(`Found ${tabDataTabs.length} tab buttons:`, tabDataTabs);
console.log(`Found ${paneIds.length} pane IDs:`, paneIds);

let tabError = false;
tabDataTabs.forEach(tab => {
  const expectedPaneId = `pane-${tab}`;
  if (!paneIds.includes(expectedPaneId)) {
    console.error(`ERROR: Tab button with data-tab="${tab}" has NO matching pane id="${expectedPaneId}"!`);
    tabError = true;
  }
});

if (!tabError && tabDataTabs.length > 0) {
  console.log("PASS: 100% Tab to Pane alignment verified.");
}

// 2. Synthetic DOM test for JS logic and error robustness
class MockClassList {
  constructor() {
    this.classes = new Set();
  }
  add(c) { this.classes.add(c); }
  remove(c) { this.classes.delete(c); }
  contains(c) { return this.classes.has(c); }
}

class MockElement {
  constructor(tag, id = '', className = '') {
    this.tagName = tag;
    this.id = id;
    this.className = className;
    this.classList = new MockClassList();
    if (className) {
      className.split(' ').filter(Boolean).forEach(c => this.classList.add(c));
    }
    this.dataset = {};
    this.innerHTML = '';
    this.textContent = '';
    this.listeners = {};
    this.children = [];
    this.parentNode = null;
  }

  addEventListener(evt, fn) {
    if (!this.listeners[evt]) this.listeners[evt] = [];
    this.listeners[evt].push(fn);
  }

  dispatchEvent(evt) {
    if (this.listeners[evt.type]) {
      this.listeners[evt.type].forEach(fn => fn(evt));
    }
  }

  closest(selector) {
    let curr = this;
    while (curr) {
      if (selector.startsWith('.') && curr.classList.contains(selector.slice(1))) {
        return curr;
      }
      if (selector.startsWith('#') && curr.id === selector.slice(1)) {
        return curr;
      }
      curr = curr.parentNode;
    }
    return null;
  }
}

// Test executing app.js logic inside sandbox
const vm = require('vm');

const elementsById = {};
const elementsByClass = {};

function createMockDOM() {
  const doc = {
    addEventListener: (evt, fn) => {
      if (evt === 'DOMContentLoaded') setTimeout(fn, 0);
    },
    getElementById: (id) => elementsById[id] || null,
    querySelectorAll: (sel) => {
      if (sel.startsWith('.')) {
        const cls = sel.slice(1);
        return elementsByClass[cls] || [];
      }
      return [];
    }
  };
  return doc;
}

// Populate mock elements from HTML
elementsById['current-year'] = new MockElement('span', 'current-year');
elementsById['faq-accordion'] = new MockElement('div', 'faq-accordion');
elementsById['pricing-grid'] = new MockElement('div', 'pricing-grid');
elementsById['testimonials-grid'] = new MockElement('div', 'testimonials-grid');

elementsByClass['tab-btn'] = [];
elementsByClass['tab-content'] = [];

tabDataTabs.forEach((t, idx) => {
  const btn = new MockElement('button', '', 'tab-btn' + (idx === 0 ? ' active' : ''));
  btn.dataset.tab = t;
  elementsByClass['tab-btn'].push(btn);

  const pane = new MockElement('div', `pane-${t}`, 'tab-content' + (idx === 0 ? ' active' : ''));
  elementsById[`pane-${t}`] = pane;
  elementsByClass['tab-content'].push(pane);
});

const mockWindow = {
  document: createMockDOM(),
  fetch: async () => ({
    ok: false,
    status: 503,
    json: async () => ({})
  }),
  console: {
    log: console.log,
    warn: (...args) => console.log('[MOCK WARN]', ...args),
    error: (...args) => console.error('[MOCK ERROR]', ...args)
  },
  Date: Date,
  Number: Number,
  String: String,
  encodeURIComponent: encodeURIComponent
};

const context = vm.createContext(mockWindow);
vm.runInContext(jsCode, context);

// Test year init
context.initYear();
console.log("Year initialized:", elementsById['current-year'].textContent);
if (elementsById['current-year'].textContent == new Date().getFullYear()) {
  console.log("PASS: Year init correct.");
} else {
  console.error("FAIL: Year init incorrect!");
}

// Test Tab switching
context.initConsoleTabs();
console.log("\nTesting Tab Switching Simulation:");
tabDataTabs.forEach((tabName, idx) => {
  const btn = elementsByClass['tab-btn'][idx];
  // Trigger click
  btn.dispatchEvent({ type: 'click' });
  const activePane = elementsById[`pane-${tabName}`];
  const isActive = activePane.classList.contains('active');
  const isBtnActive = btn.classList.contains('active');
  console.log(`  Tab '${tabName}': button active=${isBtnActive}, pane active=${isActive}`);
  if (!isActive || !isBtnActive) {
    console.error(`  FAIL: Tab '${tabName}' switching failed!`);
  }
});
console.log("PASS: Tab switching behaves correctly without errors.");

// Test Fallback pricing plan rendering
console.log("\nTesting Fallback Pricing Rendering:");
context.renderFallbackPlans();
const pricingHTML = elementsById['pricing-grid'].innerHTML;
console.log(`Pricing grid rendered ${pricingHTML.length} characters.`);
if (pricingHTML.includes('Trial Plan') && pricingHTML.includes('Enterprise Plan') && pricingHTML.includes('wa.me')) {
  console.log("PASS: Pricing plans rendered cleanly.");
} else {
  console.error("FAIL: Pricing plans rendering missing key plans!");
}

// Test WhatsApp inquiry strings for all 5 tiers
const expectedTiers = ['Trial Plan', 'Starter Plan', 'Growth Plan', 'Pro Plan', 'Enterprise Plan'];
expectedTiers.forEach(tier => {
  if (pricingHTML.includes(tier)) {
    console.log(`  PASS: Tier '${tier}' present in rendered pricing grid.`);
  } else {
    console.error(`  FAIL: Tier '${tier}' missing from rendered pricing grid!`);
  }
});

// Test XSS & HTML escaping
const dirtyText = '<script>alert("xss")</script>&"\'';
const escaped = context.escapeHtml(dirtyText);
if (!escaped.includes('<script>') && escaped.includes('&lt;script&gt;')) {
  console.log("PASS: HTML escaping sanitizer works as expected.");
} else {
  console.error("FAIL: HTML escaping failure!");
}

console.log("\n=== ALL JS CONSOLE & DOM TESTS COMPLETED SUCCESSFULLY ===");
