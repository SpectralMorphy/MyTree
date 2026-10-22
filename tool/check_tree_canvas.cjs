// Usage: node tool/check_tree_canvas.cjs <playwright-module> <base-url> <artifacts-directory> [all|canvas|middle-pan|middle-pan-portrait|editing|zoom|stability|surnames|kinship|toolbar|compact-search|compact-search-mobile|compact-search-rotation|compact-search-focus-diagnostic|alignment|alignment-mobile|trunk-modes|parent-adjacency|partner-proximity|own-partner-priority|clipped-selection-centering|descendant-branches|ancestor-corridor|shared-parent-cohorts|parent-row-stability|selection-frame-stability|minimum-avatar-zoom|explicit-siblings|step-parent-kinship|collateral-child-ranks|personal-family-controls|ordering-guest-controls|editor-refinements|editor-refinements-desktop]
// Runs the production app, headless only. No internal app APIs are invoked.
// The optional focus diagnostic forwards/logs native DOM focus/blur without changing app behavior.
// The fixture uses WebRoomStore's actual v1 keys and RoomEdit/tree-operation formats.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const [playwrightModule, base, outputArgument, suite = 'all'] = process.argv.slice(2);
assert.ok(['all', 'canvas', 'middle-pan', 'middle-pan-portrait', 'editing', 'zoom', 'stability', 'surnames', 'kinship', 'toolbar', 'compact-search', 'compact-search-mobile', 'compact-search-rotation', 'compact-search-focus-diagnostic', 'alignment', 'alignment-mobile', 'trunk-modes', 'parent-adjacency', 'partner-proximity', 'own-partner-priority', 'clipped-selection-centering', 'descendant-branches', 'ancestor-corridor', 'shared-parent-cohorts', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship', 'collateral-child-ranks', 'personal-family-controls', 'ordering-guest-controls', 'editor-refinements', 'editor-refinements-desktop'].includes(suite), 'Unknown focused browser suite.');
if (!playwrightModule || !base || !outputArgument) {
  throw new Error('Pass the Playwright module, production application URL, and artifacts directory.');
}
const { chromium } = require(playwrightModule);
const output = path.resolve(outputArgument);
const origin = new URL(base).origin;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const body = (page) => page.locator('body').ariaSnapshot();
const node = (page, name) => page.getByRole('button', { name: `Выбрать ${name}`, exact: true });
const round = (value) => Math.round(value * 1000) / 1000;
const report = { application: base, suite, headless: true, scenarios: [], pageErrors: [], consoleErrors: [] };
const tracedLocalLayout = ['own-partner-priority', 'clipped-selection-centering', 'descendant-branches', 'ancestor-corridor', 'shared-parent-cohorts', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship', 'collateral-child-ranks', 'personal-family-controls', 'ordering-guest-controls'].includes(suite);
if (tracedLocalLayout) Object.assign(report, {
  flutterErrors: [], consoleMessages: [], network: { localAssetsOnly: true, http: [], webSockets: [] },
});

// RoomEdit.createdAt is epoch milliseconds, NOT StampedTreeOperation's ISO date.
// The outer edit's text contains the JSON TreeOperation; there is no extra stamp.
function fixture({ family = 'canvas', role = 'editor' } = {}) {
  const room = crypto.randomBytes(16).toString('hex');
  const actor = crypto.randomBytes(16).toString('hex');
  const prefix = 'mytree.room-store.v1.';
  const encode = (value) => Buffer.from(value, 'utf8').toString('base64url');
  const roomPrefix = `${prefix}room.${encode(room)}.`;
  const records = [];
  const people = [];
  const names = {};
  let sequence = 0;
  const createdAt = Date.UTC(2026, 9, 1);
  const add = (kind, text, extra = {}) => {
    const id = crypto.createHash('sha256').update(`${room}:${++sequence}`).digest('hex').slice(0, 32);
    records.push({ id, author: actor, clock: createdAt + sequence, createdAt, kind, text, ...extra });
  };
  const operation = (value) => add('tree', JSON.stringify(value));
  const value = (personId, field, entry) => operation({ type: 'setValue', personId, field, value: entry });
  const text = (personId, field, entry) => {
    let left = null;
    const inserts = [...entry].map((character, index) => {
      const id = `canvas:${personId}:${field}:${index}`;
      const atom = { id, text: character, left, right: null };
      left = id;
      return atom;
    });
    operation({ type: 'editText', personId, field, itemId: null, inserts, deletes: [] });
  };
  const person = (id, name, sex, generation) => {
    people.push({ id, name: name || 'Без имени', sex, generation });
    names[id] = name || 'Без имени';
    if (id === 'root') {
      // The virtual root already exists, so createPerson cannot name it.
      if (name) text(id, 'name', name);
      value(id, 'sex', sex);
    } else {
      operation({ type: 'createPerson', personId: id, name, sex });
    }
  };
  const parents = (id, father, mother) => {
    if (father) value(id, 'fatherId', father);
    if (mother) value(id, 'motherId', mother);
  };
  add('participantName', 'Canvas browser editor');
  add('participantRole', role, { targetActor: actor });
  add('roomName', 'Canvas regression');
  if (['personal-ancestry-order', 'ordering-phone'].includes(family)) {
    const guestActor = crypto.createHash('sha256').update(`${room}:guest`).digest('hex').slice(0, 32);
    add('participantName', 'Гость проверки', { author: guestActor });
    add('participantRole', 'guest', { targetActor: guestActor });
  }
  if (family === 'step-parent-kinship') {
    person('natalia', 'Наталья', 'female', 0);
    value('natalia', 'birthDate', '1960-01-01');
    // createSibling creates BOTH the person and explicit edge; there is no
    // linkSiblings operation. Neither sister has known parents to copy.
    people.push({ id: 'veronika', name: 'Вероника', sex: 'female', generation: 0 });
    names.veronika = 'Вероника';
    operation({ type: 'createSibling', personId: 'veronika', siblingId: 'natalia',
      name: 'Вероника', sex: 'female', birthDate: '1962-01-01' });
    // One compact distant sibling block lies chronologically BETWEEN Natalia's
    // block and both fathers. Roman is Nikita's father, but remains distant to
    // Olga/Nastyusha: related clustering must not promote an entire graph.
    person('elena', 'Елена', 'female', 0);
    value('elena', 'birthDate', '1965-01-01');
    for (const [id, name, birthDate] of [
      ['stepan', 'Степан', '1966-01-01'], ['roman', 'Роман', '1967-01-01'],
    ]) {
      people.push({ id, name, sex: 'male', generation: 0 });
      names[id] = name;
      operation({ type: 'createSibling', personId: id, siblingId: 'elena', name, sex: 'male', birthDate });
    }
    person('oleg', 'Олег', 'male', 0);
    value('oleg', 'birthDate', '1970-01-01');
    person('sergey', 'Сергей', 'male', 0);
    value('sergey', 'birthDate', '1972-01-01');
    person('root', 'Ольга', 'female', 1);
    person('nastyusha', 'Настюша', 'female', 1);
    person('nikita', 'Никита', 'male', 1);
    parents('root', 'oleg', 'natalia');
    parents('nastyusha', 'sergey', 'natalia');
    parents('nikita', 'roman', 'veronika');
  } else if (['shared-parent-cohorts', 'parent-row-stability'].includes(family)) {
    // Only the screenshot family: separate father blocks deliberately compete
    // with Natalia's common-parent cohort. No extra ancestors/context chains.
    person('lydia', 'Лидия', 'female', 1);
    person('gennady', 'Геннадий', 'male', 1);
    person('valentina', 'Валентина', 'female', 1);
    person('natalia', 'Наталья', 'female', 2);
    person('veronika', 'Вероника', 'female', 2);
    for (const id of ['natalia', 'veronika']) parents(id, 'gennady', 'lydia');
    value('natalia', 'birthDate', '1970-01-01');
    value('veronika', 'birthDate', '1980-01-01');
    person('roman', 'Роман', 'male', 2);
    parents('roman', null, 'valentina');
    person('oleg', 'Олег', 'male', 2);
    person('nekto', 'Некто', 'male', 2);
    person('root', 'Никита', 'male', 3);
    person('olga', 'Ольга', 'female', 3);
    person('anastasia', 'Анастасия', 'female', 3);
    parents('root', 'roman', 'veronika');
    parents('olga', 'oleg', 'natalia');
    parents('anastasia', 'nekto', 'natalia');
    if (family === 'parent-row-stability') {
      person('test', 'Тест', 'male', 0);
      parents('lydia', 'test', null);
      person('prikol', 'Прикол', 'male', 2);
      parents('prikol', 'gennady', 'lydia');
      person('oleg-mother', '?', 'female', 1);
      person('oleg-father', 'Без имени', 'male', 1);
      parents('oleg', 'oleg-father', 'oleg-mother');
      person('shrek', 'Шрек', 'male', 2);
      parents('shrek', 'oleg-father', null);
    }
  } else if (family === 'ancestor-corridor') {
    person('maternal-great-mother', 'Прабабушка матери', 'female', 0);
    person('maternal-great-father', 'Прадед матери', 'male', 0);
    person('paternal-great-father', 'Прадед отца', 'male', 0);
    person('oleg-great-father', 'Предок Олега', 'male', 0);
    person('paternal-context-great', 'Предок спутницы', 'unknown', 0);
    person('neutral', 'Нейтральный', 'unknown', 0);
    person('both-context-great', 'Общий контекст предок', 'unknown', 0);
    person('both-context-parent', 'Общий контекст родитель', 'unknown', 1);
    parents('both-context-parent', 'both-context-great', null);
    person('lydia', 'Лидия', 'female', 1);
    person('gennady', 'Геннадий', 'male', 1);
    person('valentina', 'Валентина', 'female', 1);
    person('oleg-mother', '?', 'female', 1);
    person('oleg-father', 'Без имени', 'male', 1);
    person('paternal-context-parent', 'Родитель спутницы', 'unknown', 1);
    parents('lydia', 'maternal-great-father', 'maternal-great-mother');
    parents('valentina', 'paternal-great-father', null);
    parents('oleg-mother', 'oleg-great-father', null);
    parents('paternal-context-parent', 'paternal-context-great', null);
    person('natalia', 'Наталья', 'female', 2);
    person('veronika', 'Вероника', 'female', 2);
    person('prikol', 'Прикол', 'male', 2);
    for (const id of ['natalia', 'veronika', 'prikol']) parents(id, 'gennady', 'lydia');
    // Natalia precedes Veronika in their canonical sibling block, so Veronika's
    // nephew context must follow the actual right/bottom blood-relative side.
    // Roman stays undated: the old canonical fallback chose this unrelated
    // coparent instead of Natalia's actual sister Veronika.
    value('natalia', 'birthDate', '1970-01-01');
    value('veronika', 'birthDate', '1980-01-01');
    person('roman', 'Роман', 'male', 2);
    parents('roman', null, 'valentina');
    person('oleg', 'Олег', 'male', 2);
    parents('oleg', 'oleg-father', 'oleg-mother');
    person('nekto', 'Некто', 'male', 2);
    person('shrek', 'Шрек', 'male', 2);
    parents('shrek', 'oleg-father', null);
    person('paternal-context', 'Спутница Романа', 'female', 2);
    parents('paternal-context', 'paternal-context-parent', null);
    person('root', 'Никита', 'male', 3);
    person('olga', 'Ольга', 'female', 3);
    person('anastasia', 'Анастасия', 'female', 3);
    person('paternal-context-child', 'Ребёнок Романа', 'unknown', 3);
    parents('root', 'roman', 'veronika');
    parents('olga', 'oleg', 'natalia');
    parents('anastasia', 'nekto', 'natalia');
    parents('paternal-context-child', 'roman', 'paternal-context');
    // Equal-length paths from both actual parents create neutral mask=3 context
    // without making this person any ancestor of the selected Nikita.
    person('both-context', 'Общий контекст', 'unknown', 2);
    parents('both-context', 'both-context-parent', null);
    person('both-maternal-child', 'Контекст матери', 'unknown', 3);
    person('both-paternal-child', 'Контекст отца', 'unknown', 3);
    parents('both-maternal-child', 'both-context', 'veronika');
    parents('both-paternal-child', 'roman', 'both-context');
  } else if (family === 'descendant-branches') {
    // Exact screenshot relationships, not a sex-sorted row or the broader trunk
    // fixture's extra upper ancestors. Nikita is the nearest common descendant
    // of the maternal Lydia/Gennady branch and paternal Valentina branch.
    person('valentina', 'Валентина', 'female', 1);
    person('lydia', 'Лидия', 'female', 1);
    person('gennady', 'Геннадий', 'male', 1);
    person('natalia', 'Наталья', 'female', 2);
    person('veronika', 'Вероника', 'female', 2);
    person('roman', 'Роман', 'male', 2);
    person('oleg', 'Олег', 'male', 2);
    person('nekto', 'Некто', 'male', 2);
    parents('natalia', 'gennady', 'lydia');
    parents('veronika', 'gennady', 'lydia');
    parents('roman', null, 'valentina');
    person('root', 'Ольга', 'female', 3);
    person('anastasia', 'Анастасия', 'female', 3);
    person('nikita', 'Никита', 'male', 3);
    parents('root', 'oleg', 'natalia');
    parents('anastasia', 'nekto', 'natalia');
    parents('nikita', 'roman', 'veronika');
  } else if (['half-stability', 'canonical-alignment', 'viewport-alignment', 'trunk-modes'].includes(family)) {
    // Fixed IDs/undated separate sibling blocks reproduce the selected-right bug.
    // `root` makes Olga the initial focus, not a post-load selection workaround.
    person('test', 'Тестовый отец', 'male', 0);
    person('lydia', 'Лидия', 'female', 1);
    person('gennady', 'Геннадий', 'male', 1);
    parents('lydia', 'test', null);
    person('natalia', 'Наталья', 'female', 2);
    person('veronika', 'Вероника', 'female', 2);
    person('oleg', 'Олег', 'male', 2);
    parents('natalia', 'gennady', 'lydia');
    parents('veronika', 'gennady', 'lydia');
    person('root', 'Ольга', 'female', 3);
    person('anastasia', 'Анастасия', 'female', 3);
    parents('root', 'oleg', 'natalia');
    parents('anastasia', null, 'natalia');
    if (family !== 'half-stability') {
      person('roman', 'Роман', 'male', 2);
      person('nikita', 'Никита', 'male', 3);
      parents('nikita', 'roman', 'veronika');
    }
    if (family === 'trunk-modes') {
      person('nekto', 'Некто', 'male', 2);
      parents('anastasia', 'nekto', null);
      // A second distinct upper ancestor makes averaging the broad trunk set
      // observably wrong at BOTH levels above Natalia. Missing mothers at the
      // top also exercise the preferred-parent fallback, not an early stop.
      person('patriarch', 'Патриарх', 'male', 0);
      parents('gennady', 'patriarch', null);
    }
    if (family === 'viewport-alignment') {
      person('olga-sibling', 'Сестра Ольги', 'female', 3);
      parents('olga-sibling', 'oleg', 'natalia');
      // Real extra siblings create enough independent-lane scroll extent to put
      // BOTH preferred parents wholly offscreen, without artificial app hooks.
      for (let index = 1; index <= 20; index++) {
        const id = `wide-relative-${String(index).padStart(2, '0')}`;
        person(id, `Родственник ${String(index).padStart(2, '0')}`, 'unknown', 2);
        parents(id, 'gennady', 'lydia');
      }
    }
  } else if (family === 'personal-family-controls') {
    person('father', 'Павел', 'male', 0);
    person('mother', 'Мария', 'female', 0);
    person('root', 'Алексей', 'male', 1);
    person('brother', 'Борис', 'male', 1);
    parents('root', 'father', 'mother');
    parents('brother', 'father', 'mother');
    person('half-brother', 'Неполный брат', 'male', 1);
    parents('half-brother', null, 'mother');
    person('own-child', 'Дочь Алексея', 'female', 2);
    person('other-child', 'Сын Бориса', 'male', 2);
    parents('own-child', 'root', null);
    parents('other-child', 'brother', null);
    operation({ type: 'setSurname', personId: 'father', scope: 'individual',
      familyKey: null, text: 'Иванов', decline: true });
    // Old shared history is immutable/readable, but a personal null must suppress
    // it for only the edited sibling and resume that person's father inheritance.
    operation({ type: 'setSurname', personId: 'root', scope: 'family',
      familyKey: 'parents:6:father:6:mother', text: 'Старов', decline: true });
  } else if (family === 'personal-ancestry-order') {
    person('grandmother', 'Бабушка', 'female', 0);
    person('grand-aunt', 'Сестра бабушки', 'female', 0);
    person('grandfather', 'Дедушка', 'male', 0);
    person('upper-father', 'Общий прадед', 'male', -1);
    person('upper-mother', 'Общая прабабушка', 'female', -1);
    for (const id of ['grandmother', 'grand-aunt']) parents(id, 'upper-father', 'upper-mother');
    value('grandmother', 'birthDate', '1940-01-01');
    value('grand-aunt', 'birthDate', '1942-01-01');
    person('mother', 'Мама', 'female', 1);
    person('aunt', 'Тётя', 'female', 1);
    for (const id of ['mother', 'aunt']) parents(id, 'grandfather', 'grandmother');
    value('mother', 'birthDate', '1970-01-01');
    value('aunt', 'birthDate', '1972-01-01');
    person('father', 'Папа', 'male', 1);
    person('partner-father', 'Отец партнёра', 'male', 1);
    person('partner-mother', 'Мать партнёра', 'female', 1);
    person('root', 'Фокус', 'male', 2);
    parents('root', 'father', 'mother');
    // Opposite IDs ensure unknown-DOB partner member order comes from names.
    person('z-partner', 'Партнёр', 'female', 2);
    person('a-partner-sister', 'Сестра партнёра', 'female', 2);
    for (const id of ['z-partner', 'a-partner-sister']) parents(id, 'partner-father', 'partner-mother');
    names.partner = 'Партнёр'; // Focus alias only, never a domain identity rewrite.
    person('child', 'Общий ребёнок', 'unknown', 3);
    parents('child', 'root', 'z-partner');
    for (const [id, name, birth] of [
      ['z-null-alpha', 'Сорт Альфа', null], ['a-null-zeta', 'Сорт Яна', null],
      ['a-null-yo', '  Сорт Ёлка  ', null], ['z-null-e', 'сорт елка', null],
      ['z-equal-alpha', 'Сорт Анна', '2000-01-01'], ['a-equal-zeta', 'Сорт Яся', '2000-01-01'],
      ['dated-older', 'Сорт Ранняя', '1990-01-01'],
    ]) {
      person(id, name, 'unknown', 3);
      parents(id, 'root', 'z-partner');
      if (birth) value(id, 'birthDate', birth);
    }
  } else if (family === 'ordering-phone') {
    person('root', 'Фокус', 'male', 0);
  } else if (family === 'surnames') {
    person('father', 'Павел', 'male', 0);
    person('mother', 'Мария', 'female', 0);
    person('brother', 'Борис', 'male', 1);
    person('root', 'Анна', 'female', 1);
    person('sister', 'Вера', 'female', 1);
    for (const id of ['brother', 'root', 'sister']) parents(id, 'father', 'mother');
    value('father', 'birthDate', '1950-01-02');
    value('mother', 'birthDate', '1952-04-08');
    value('brother', 'birthDate', '1979-11-10');
    value('root', 'birthDate', '1985-06-03');
    operation({ type: 'setSurname', personId: 'father', scope: 'family',
      familyKey: 'person:6:father', text: 'Иванов', decline: true });
    // Legacy history remains readable/immutable, but is neither a second surname
    // field nor a search alias/caption in the single birth-surname UI.
    operation({ type: 'setSurname', personId: 'root', scope: 'maiden',
      familyKey: null, text: 'Сидоров', decline: true });
  } else if (family === 'kinship-style') {
    person('grandparent', 'Общий предок', 'unknown', 0);
    person('father', 'Отец', 'male', 1);
    person('mother', 'Мать', 'female', 1);
    person('uncle', 'Родитель кузена', 'unknown', 1);
    parents('father', 'grandparent', null);
    parents('uncle', 'grandparent', null);
    person('root', 'Фокус', 'male', 2);
    person('brother', 'Полный брат', 'male', 2);
    person('half-sister', 'Неполная сестра', 'female', 2);
    person('cousin', 'Кузен', 'male', 2);
    parents('root', 'father', 'mother');
    parents('brother', 'father', 'mother');
    parents('half-sister', null, 'mother');
    parents('cousin', 'uncle', null);
    person('nephew', 'Племянник', 'male', 3);
    person('niece', 'Племянница', 'female', 3);
    parents('nephew', 'brother', null);
    parents('niece', null, 'half-sister');
  } else if (family === 'toolbar-style') {
    // Compact enough for one real 1440x900 screenshot at 50%, with separate
    // context blocks so their wash is not promoted by a normal sibling.
    person('grandparent', 'Общий предок', 'unknown', 0);
    person('grandmother', 'Бабушка', 'female', 0);
    person('father', 'Отец', 'male', 1);
    person('mother', 'Мать', 'female', 1);
    person('aunt', 'Тётя', 'female', 1);
    parents('father', 'grandparent', 'grandmother');
    parents('aunt', 'grandparent', null);
    person('root', 'Фокус', 'male', 2);
    person('brother', 'Полный брат', 'male', 2);
    person('half-sister', 'Неполная сестра', 'female', 2);
    person('cousin', 'Кузен', 'male', 2);
    for (const id of ['root', 'brother']) parents(id, 'father', 'mother');
    parents('half-sister', null, 'mother');
    parents('cousin', null, 'aunt');
    person('nephew', 'Племянник', 'male', 3);
    person('niece', 'Племянница', 'female', 3);
    parents('nephew', 'brother', null);
    parents('niece', null, 'half-sister');
    person('partner-father', 'Отец партнёра', 'male', 1);
    person('partner-mother', 'Мать партнёра', 'female', 1);
    person('partner', 'Партнёр', 'female', 2);
    person('distant-sibling', 'Дальняя сестра', 'female', 2);
    for (const id of ['partner', 'distant-sibling']) parents(id, 'partner-father', 'partner-mother');
    person('child', 'Общий ребёнок', 'unknown', 3);
    parents('child', 'root', 'partner');
  } else if (family === 'kinship-followup') {
    person('upper', 'Старший предок', 'male', 0);
    person('great', 'Прадед', 'male', 1);
    person('higher-aunt', 'Сестра прадеда', 'female', 1);
    parents('great', 'upper', null);
    parents('higher-aunt', 'upper', null);
    person('grandparent', 'Дед', 'male', 2);
    person('grandmother', 'Бабушка', 'female', 2);
    person('grand-aunt', 'Сестра деда', 'female', 2);
    person('ancestor-aunt', 'Бабушка предок', 'female', 2);
    for (const id of ['grandparent', 'grand-aunt', 'ancestor-aunt']) parents(id, 'great', null);
    // Pedigree collapse: this sibling of the paternal grandfather is also a
    // direct maternal ancestor. Normal ancestry MUST beat the aunt context.
    person('father', 'Отец', 'male', 3);
    person('mother', 'Мать', 'female', 3);
    person('uncle', 'Дядя', 'male', 3);
    person('aunt', 'Тётя', 'female', 3);
    // Full uncle shares the normal ancestor's block; half aunt has her own
    // block, so photo filtering and the olive singleton wash are independent.
    for (const id of ['father', 'uncle']) parents(id, 'grandparent', 'grandmother');
    parents('aunt', 'grandparent', null);
    parents('mother', null, 'ancestor-aunt');
    person('half-father', 'Отдельный отец', 'male', 3);
    person('half-mother', 'Отдельная мать', 'female', 3);
    person('partner-father', 'Отец партнёра', 'male', 3);
    person('partner-mother', 'Мать партнёра', 'female', 3);
    person('root', 'Фокус', 'male', 4);
    person('brother', 'Полный брат', 'male', 4);
    for (const id of ['root', 'brother']) parents(id, 'father', 'mother');
    person('maternal-half', 'Сестра по матери', 'female', 4);
    parents('maternal-half', 'half-father', 'mother');
    person('paternal-half', 'Брат по отцу', 'male', 4);
    parents('paternal-half', 'father', 'half-mother');
    person('cousin', 'Кузен', 'male', 4);
    parents('cousin', 'uncle', null);
    person('partner-a', 'Партнёр один', 'female', 4);
    person('partner-sibling', 'Сестра партнёра', 'female', 4);
    for (const id of ['partner-a', 'partner-sibling']) parents(id, 'partner-father', 'partner-mother');
    person('partner-b', 'Партнёр два', 'female', 4);
    person('partner-c', 'Партнёр три', 'female', 4);
    for (const [index, partner] of ['partner-a', 'partner-b', 'partner-c'].entries()) {
      const id = `union-child-${index + 1}`;
      person(id, `Общий ребёнок ${index + 1}`, 'unknown', 5);
      parents(id, 'root', partner);
    }
    person('nephew', 'Племянник', 'male', 5);
    person('niece', 'Племянница', 'female', 5);
    parents('nephew', 'brother', null);
    parents('niece', null, 'maternal-half');
  } else if (family === 'lydia') {
    person('gennady', 'Геннадий', 'male', 0);
    person('lydia', 'Лидия', 'female', 0);
    person('root', 'Наталья', 'female', 1);
    person('veronika', 'Вероника', 'female', 1);
    parents('root', 'gennady', 'lydia');
    parents('veronika', 'gennady', 'lydia');
  } else if (family === 'explicit-siblings') {
    person('root', 'Алексей', 'male', 1);
  } else if (family === 'minimum-avatar-zoom') {
    person('root', 'Фокус', 'male', 1);
    person('photo-mother', 'Фото', 'female', 0);
    parents('root', null, 'photo-mother');
  } else if (family === 'single' || family === 'unknown-avatar') {
    person('root', family === 'unknown-avatar' ? '' : 'Фокус', 'unknown', 0);
  } else {
    person('great', 'Прадед', 'male', 0);
    person('great-maternal', 'Прабабушка', 'female', 0);
    person('grand-father', 'Дед', 'male', 1);
    person('grand-mother', 'Бабушка', 'female', 1);
    person('maternal-grand-father', 'Дед М', 'male', 1);
    person('maternal-grand-mother', 'Бабушка М', 'female', 1);
    parents('grand-father', 'great', null);
    parents('grand-mother', 'great', null);
    parents('maternal-grand-father', 'great-maternal', null);
    parents('maternal-grand-mother', 'great-maternal', null);
    person('father', 'Отец', 'male', 2);
    person('mother', 'Мать', 'female', 2);
    parents('father', 'grand-father', 'grand-mother');
    // Separate parental blocks/branches are essential: selecting a parent must
    // not merely preserve siblings inside one rigid block while repacking others.
    parents('mother', 'maternal-grand-father', 'maternal-grand-mother');
    // IDs straddle root: five undated siblings on either side of the initial focus.
    for (let index = 1; index <= 10; index++) {
      const id = `${index <= 5 ? 'a' : 'z'}-sibling-${String(index).padStart(2, '0')}`;
      person(id, `Недат${String(index).padStart(2, '0')}`, index % 2 ? 'male' : 'female', 3);
      parents(id, 'father', 'mother');
    }
    person('root', 'Фокус', 'male', 3);
    parents('root', 'father', 'mother');
    // Both parent IDs are present so the twelve children form a real sibling block.
    for (let index = 1; index <= 12; index++) {
      const id = `child-${String(index).padStart(2, '0')}`;
      person(id, `Дитя${String(index).padStart(2, '0')}`, index % 2 ? 'male' : 'female', 4);
      parents(id, 'root', 'z-sibling-06');
    }
    for (let index = 1; index <= 2; index++) {
      const id = `grandchild-${index}`;
      person(id, `Внук${index}`, 'unknown', 5);
      parents(id, 'child-05', 'child-06');
    }
    assert.equal(people.filter((entry) => entry.generation === 3).length, 11);
    assert.equal(people.filter((entry) => entry.generation === 4).length, 12);
  }
  const entries = [
    [`${prefix}client-id`, JSON.stringify(actor)],
    [`${prefix}last-room`, JSON.stringify(room)],
    [`${roomPrefix}membership`, JSON.stringify(room)],
  ];
  // Every immutable operation has its own base64url(ID) localStorage key.
  const finish = () => {
    for (const record of records) {
      entries.push([`${roomPrefix}operation.${encode(record.id)}`, JSON.stringify(record)]);
    }
    return { room, actor, roomPrefix, entries, records, people, names, focusName: names.root };
  };
  return { finish, operation, value, people };
}

// Browser-side oracle for the production display contract, not an app hook.
// Use code-unit comparison (not localeCompare): unknown DOB first, then date,
// trimmed/lowercase given name with ё=е, and ID only as a total tie-breaker.
function compareDisplayPeople(a, b) {
  const compare = (first, second) => first < second ? -1 : first > second ? 1 : 0;
  if (a.birthDate == null && b.birthDate != null) return -1;
  if (a.birthDate != null && b.birthDate == null) return 1;
  const birth = a.birthDate != null && b.birthDate != null ? compare(a.birthDate, b.birthDate) : 0;
  if (birth) return birth;
  const normalize = (text) => text.trim().toLowerCase().replaceAll('ё', 'е');
  return compare(normalize(a.name), normalize(b.name)) || compare(a.id, b.id);
}
function fixturePeopleByDisplay(seeded, ids) {
  const births = new Map(seeded.records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
    .filter((operation) => operation.type === 'setValue' && operation.field === 'birthDate')
    .map((operation) => [operation.personId, operation.value]));
  return seeded.people.filter((person) => !ids || ids.includes(person.id))
    .map((person) => ({ ...person, birthDate: births.get(person.id) ?? null })).sort(compareDisplayPeople);
}

async function until(check, message, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await check()) return;
    await sleep(150);
  }
  throw new Error(message);
}

async function activate(page) {
  await page.waitForFunction(() => window.__canvasFirstFrame, null, { timeout: 90000 });
  const placeholder = page.locator('flt-semantics-placeholder');
  for (let attempt = 0; attempt < 5 && await placeholder.count(); attempt++) {
    await placeholder.evaluate((element) => Object.assign(element.style, {
      position: 'fixed', left: '0px', top: '0px', width: '2px', height: '2px',
      transform: 'none', zIndex: '2147483647',
    }));
    await placeholder.click({ force: true });
    await sleep(200);
  }
}

async function loadRoom(page, seeded, expectedName = seeded.focusName) {
  const expectedBundle = ['own-partner-priority', 'clipped-selection-centering', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship'].includes(suite)
    ? process.env.MYTREE_EXPECTED_BUNDLE_SHA256 : null;
  if (['own-partner-priority', 'clipped-selection-centering', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship'].includes(suite)) assert.match(expectedBundle || '', /^[0-9a-f]{64}$/,
    'The finite browser run requires its explicitly authorized bundle hash.');
  const actualBundle = expectedBundle ? page.waitForResponse((response) =>
    response.url() === new URL('main.dart.js', `${base.replace(/\/$/, '')}/`).href && response.status() === 200,
  { timeout: 30000 }) : null;
  await page.goto(base, { waitUntil: 'domcontentloaded', timeout: 120000 });
  if (actualBundle) {
    const response = await actualBundle, bytes = await response.body();
    const entry = { url: response.url(), bytes: bytes.length,
      sha256: crypto.createHash('sha256').update(bytes).digest('hex'), fromServiceWorker: response.fromServiceWorker() };
    (report.actualBrowserBundles ??= []).push(entry);
    await fs.writeFile(path.join(output, 'actual-browser-bundles.json'), JSON.stringify(report.actualBrowserBundles, null, 2));
    assert.equal(entry.sha256, expectedBundle, 'The actual browser main.dart.js response is not the authorized new bundle.');
    assert.equal(entry.fromServiceWorker, false, 'A service worker supplied the browser bundle.');
  }
  await activate(page);
  let localCopy = false;
  await until(async () => {
    if (expectedName ? await node(page, expectedName).count() :
      await page.getByText('В дереве пока никого нет', { exact: true }).count()) return true;
    const local = page.getByRole('button', { name: 'Открыть локальную копию', exact: true });
    if (await local.isVisible().catch(() => false)) {
      await local.click();
      localCopy = true;
    }
    return false;
  }, 'Saved member never reached the real canvas or the explicit local-copy action.', 90000);
  await settle(page);
  const semantics = await body(page);
  assert.doesNotMatch(semantics, /Не сохранено:|Не удалось загрузить историю|Не удалось прочитать локальные данные/);
  if (localCopy) assert.match(semantics, /Локальная копия · синхронизация не подтверждена/);
  const records = await history(page, seeded);
  for (const expected of seeded.records) {
    assert.deepEqual(records.find((record) => record.id === expected.id), expected, `Seed rejected/changed: ${expected.id}`);
  }
  report.scenarios.push({ name: 'production-room-load', viewport: page.viewportSize(), localCopy,
    synchronization: localCopy ? 'explicitly unconfirmed; UI-only regression' : 'production initial gate completed' });
}

async function settle(page) {
  // Covers the production 220ms selection animation, tooltip dismissal, and semantics updates.
  await page.mouse.move(1, 1);
  await sleep(700);
}

async function history(page, seeded) {
  return page.evaluate((prefix) => Object.keys(localStorage)
    .filter((key) => key.startsWith(`${prefix}operation.`))
    .map((key) => JSON.parse(localStorage.getItem(key)))
    .sort((a, b) => a.id.localeCompare(b.id)), seeded.roomPrefix);
}

// A visible Flutter tooltip can temporarily duplicate its button's label.
const zoomIn = (page) => page.getByRole('button', { name: /^Увеличить масштаб(?:\s|$)/ });
const zoomOut = (page) => page.getByRole('button', { name: /^Уменьшить масштаб(?:\s|$)/ });
const zoomReset = (page) => page.getByRole('button', { name: /(?:Сбросить масштаб|^\d+%(?:\s|$))/ });
async function zoomPercent(page) {
  const button = zoomReset(page);
  const label = await button.getAttribute('aria-label') || await button.innerText();
  const match = label.match(/(\d+)%/);
  assert.ok(match, `The actual toolbar does not show its current percentage: ${label}`);
  return Number(match[1]);
}
async function canvasTop(page) {
  // Expanded controls occupy one compact row in either orientation. A truly
  // collapsed toolbar leaves only its floating opener, not a permanent zoom row.
  const controls = [zoomIn(page), page.getByRole('textbox', { name: 'Поиск по дереву', exact: true }),
    page.getByRole('button', { name: /^(?:Свернуть|Развернуть) панель дерева$/ })];
  const boxes = await Promise.all(controls.map((control) => control.boundingBox().catch(() => null)));
  let top = Math.max(0, ...boxes.filter(Boolean).map((box) => box.y + box.height + 1));
  const hint = page.getByText('Найдите человека и подтвердите выбор галочкой', { exact: true });
  if (await hint.count()) {
    const bounds = await hint.boundingBox();
    if (bounds) top = Math.max(top, bounds.y + bounds.height + 8);
  }
  return top;
}

async function snapshot(page, seeded, title) {
  const viewport = page.viewportSize();
  const top = await canvasTop(page);
  const nodeExtent = 108 * await zoomPercent(page) / 100;
  const boxes = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => elements.map((element) => {
    const rect = element.getBoundingClientRect();
    return { label: element.getAttribute('aria-label') || element.textContent || '',
      x: rect.x, y: rect.y, width: rect.width, height: rect.height,
      selected: element.getAttribute('aria-selected'), pressed: element.getAttribute('aria-pressed') };
  }));
  const result = {};
  for (const box of boxes) {
    const name = box.label.replace(/^Выбрать /, '');
    const person = seeded.people.find((entry) => entry.name === name);
    if (!person || Math.abs(box.width - nodeExtent) > 1.5 || Math.abs(box.height - nodeExtent) > 1.5) continue;
    if (box.x < 17 || box.y < top || box.x + box.width > viewport.width - 17 ||
        box.y + box.height > viewport.height - 17) continue;
    result[name] = { generation: person.generation, ...Object.fromEntries(Object.entries(box)
      .map(([key, entry]) => [key, typeof entry === 'number' ? round(entry) : entry])) };
  }
  const entry = { title, viewport, canvasTop: top, nodes: result, semantics: await body(page),
    documentScroll: await page.evaluate(() => ({ x: scrollX, y: scrollY, width: document.documentElement.scrollWidth })) };
  assert.equal(entry.documentScroll.width, viewport.width, 'The page acquired unintended horizontal overflow.');
  return entry;
}

async function capture(page, seeded, title) {
  await settle(page);
  const state = await snapshot(page, seeded, title);
  await page.screenshot({ path: path.join(output, `${title}.png`), animations: 'disabled' });
  await fs.writeFile(path.join(output, `${title}.json`), JSON.stringify(state, null, 2));
  return state;
}

function center(box) {
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
}

function stable(before, after, names, message) {
  for (const name of names) {
    assert.ok(after.nodes[name], `${message}: ${name} disappeared from the visible viewport.`);
    for (const dimension of ['x', 'y', 'width', 'height']) {
      assert.ok(Math.abs(before.nodes[name][dimension] - after.nodes[name][dimension]) <= 1.5,
        `${message}: ${name}.${dimension} moved ${before.nodes[name][dimension]} -> ${after.nodes[name][dimension]}.`);
    }
  }
}

function order(state, generation, portrait) {
  const dimension = portrait ? 'y' : 'x';
  return Object.entries(state.nodes).filter(([, box]) => box.generation === generation)
    .sort(([, a], [, b]) => a[dimension] - b[dimension]).map(([name]) => name);
}

async function assertSelected(page, name) {
  const button = node(page, name);
  assert.equal(await button.count(), 1, `Selected node ${name} is missing or duplicated.`);
  const attributes = await button.evaluate((element) => ({
    selected: element.getAttribute('aria-selected'), pressed: element.getAttribute('aria-pressed'),
    current: element.getAttribute('aria-current'),
  }));
  // Prefer the accessibility bridge, never the removed toolbar caption. Some
  // Flutter/Chromium combinations drop selected state for role=button entirely;
  // in that case verify the actual labeled node's painted fill AND thin outline.
  const semantics = await button.ariaSnapshot();
  if (attributes.selected === 'true' || attributes.pressed === 'true' || attributes.current === 'true' ||
    /\[(?:selected|pressed|current)(?:=true)?\]/.test(semantics)) return;
  const box = await button.boundingBox();
  assert.ok(box && box.width > 12 && box.height > 12, `Selected node ${name} has no painted viewport target.`);
  const png = await page.screenshot({ clip: box, animations: 'disabled', scale: 'css' });
  const painted = await page.evaluate(async (png) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const w = image.width - 1, h = image.height - 1;
    const pairs = [[pixel(w / 2, h * .04), pixel(w / 2, 0)],
      [pixel(w * .04, h / 2), pixel(0, h / 2)],
      [pixel(w * .96, h / 2), pixel(w, h / 2)],
      [pixel(w / 2, h * .96), pixel(w / 2, h)]];
    return { pairs, brightMargins: pairs.filter(([fill]) => Math.min(...fill) >= 226).length,
      outlinedEdges: pairs.filter(([fill, edge]) => Math.max(...fill.map((channel, index) => Math.abs(channel - edge[index]))) >= 12).length };
  }, png.toString('base64'));
  assert.ok(painted.brightMargins >= 3 && painted.outlinedEdges >= 2,
    `Expected selected node ${name}; semantics=${semantics}; actual painted state=${JSON.stringify(painted)}`);
}

async function select(page, name) {
  const button = node(page, name);
  const box = await button.boundingBox();
  assert.ok(box, `No semantic hit box for ${name}.`);
  await page.mouse.click(...Object.values(center(box)));
  await settle(page);
  await assertSelected(page, name);
}

async function wheelOwnership(page, seeded, label, portrait, generation, delta = 92) {
  const before = await capture(page, seeded, `${label}-wheel-g${generation}-before`);
  const candidates = Object.entries(before.nodes).filter(([, box]) => box.generation === generation);
  assert.ok(candidates.length >= 2, `Need two fully visible nodes in generation ${generation}.`);
  const [name, target] = candidates.find(([candidate]) => candidate === 'Фокус') || candidates[Math.floor(candidates.length / 2)];
  const witnesses = Object.keys(before.nodes).filter((candidate) => before.nodes[candidate].generation !== generation);
  assert.ok(new Set(witnesses.map((candidate) => before.nodes[candidate].generation)).size >= 2,
    'Need independent parent/focus/child generation witnesses for real wheel ownership.');
  const point = center(target);
  await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(0, delta); // Genuine browser wheel, not dispatchEvent or a semantics scroll action.
  const after = await capture(page, seeded, `${label}-wheel-g${generation}-after`);
  assert.ok(after.nodes[name], `The small wheel delta unexpectedly hid ${name}.`);
  const movement = after.nodes[name].y - before.nodes[name].y;
  assert.ok(movement < -25 && movement > -140,
    `${label}: physical vertical wheel failed to move ${name} vertically (${movement}px).`);
  assert.ok(Math.abs(after.nodes[name].x - before.nodes[name].x) <= 1.5,
    `${label}: physical vertical wheel unexpectedly moved the canvas horizontally.`);
  if (portrait) {
    stable(before, after, witnesses, `${label}: portrait wheel moved a non-hovered generation`);
  } else {
    const visible = witnesses.filter((candidate) => after.nodes[candidate]);
    assert.ok(new Set(visible.map((candidate) => before.nodes[candidate].generation)).size >= 2,
      'Landscape vertical wheel needs two independent generation witnesses.');
    for (const candidate of visible) {
      assert.ok(Math.abs(after.nodes[candidate].y - before.nodes[candidate].y - movement) <= 1.5,
        `${label}: landscape wheel did not advance the whole generation axis (${candidate}).`);
      assert.ok(Math.abs(after.nodes[candidate].x - before.nodes[candidate].x) <= 1.5,
        `${label}: landscape wheel shifted ${candidate} sideways.`);
    }
  }
  assert.deepEqual(after.documentScroll, before.documentScroll, 'Browser default scrolling escaped the tree.');
  await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(0, -delta);
  await settle(page);
  const restored = await snapshot(page, seeded, `${label}-wheel-g${generation}-restored`);
  stable(before, restored, Object.keys(before.nodes), `${label}: reversing the wheel did not restore visible positions`);
  report.scenarios.push({ name: `${label}-wheel-generation-${generation}`, target: name, verticalMovement: movement,
    untouched: witnesses, before: before.nodes, after: after.nodes });
}

function rigidTravel(before, after, travel, targetGeneration, message, minOtherGenerations = 2) {
  // Include EVERY fully visible before/after node, not just one convenient row.
  // Nodes whose predicted bounds remain fully visible may not silently disappear.
  for (const [name, box] of Object.entries(before.nodes)) {
    const x = box.x + travel.x, y = box.y + travel.y;
    if (x >= 17 && y >= after.canvasTop && x + box.width <= after.viewport.width - 17 &&
        y + box.height <= after.viewport.height - 17) {
      assert.ok(after.nodes[name], `${message}: predicted fully visible witness ${name} disappeared.`);
    }
  }
  const witnesses = Object.keys(before.nodes).filter((name) => after.nodes[name]);
  const generations = [...new Set(witnesses.map((name) => before.nodes[name].generation))];
  assert.ok(generations.filter((generation) => generation !== targetGeneration).length >= minOtherGenerations,
    `${message}: need at least ${minOtherGenerations} other fully visible generation witnesses, got ${generations}.`);
  const movements = {};
  for (const name of witnesses) {
    movements[name] = {};
    for (const axis of ['x', 'y']) {
      const actual = round(after.nodes[name][axis] - before.nodes[name][axis]);
      movements[name][axis] = actual;
      assert.ok(Math.abs(actual - travel[axis]) <= 1.5,
        `${message}: ${name}.${axis} travelled ${actual}px instead of the whole-canvas ${travel[axis]}px.`);
    }
    for (const extent of ['width', 'height']) assert.ok(Math.abs(after.nodes[name][extent] - before.nodes[name][extent]) <= 1.5,
      `${message}: middle panning changed ${name}.${extent}.`);
  }
  assert.deepEqual(after.documentScroll, before.documentScroll, `${message}: browser default scrolling escaped the canvas.`);
  return { witnesses, generations, movements };
}

async function middleCanvasDrag(page, seeded, label, { point, travel = { x: -76, y: -62 }, minOtherGenerations = 2 } = {}) {
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page);
  const before = await capture(page, seeded, `${label}-middle-drag-before`);
  const selected = seeded.focusName, generation = before.nodes[selected]?.generation;
  assert.ok(before.nodes[selected], `${label}: the selected middle-pan witness is not fully visible.`);
  // Start on an unselected sibling where possible, so selection isolation cannot
  // pass merely because a spurious primary click hit the already-selected node.
  const explicitPoint = Boolean(point);
  const inputTarget = Object.keys(before.nodes).find((name) => name !== selected && before.nodes[name].generation === generation);
  point ||= center(before.nodes[inputTarget || selected]);
  const eventStart = await page.evaluate(() => window.__canvasMiddleEvents.length);
  await page.mouse.move(point.x, point.y);
  await page.mouse.down({ button: 'middle' });
  let held;
  try {
    await page.mouse.move(point.x + travel.x, point.y + travel.y, { steps: 12 });
    await sleep(180);
    held = await snapshot(page, seeded, `${label}-middle-held`);
    const events = await page.evaluate((start) => window.__canvasMiddleEvents.slice(start), eventStart);
    await page.screenshot({ path: path.join(output, `${label}-middle-held.png`), animations: 'disabled' });
    await fs.writeFile(path.join(output, `${label}-middle-held.json`), JSON.stringify({ ...held, point, travel, events }, null, 2));
    rigidTravel(before, held, travel, generation, `${label}: held middle`, minOtherGenerations);
  } finally { await page.mouse.up({ button: 'middle' }); }
  const after = await capture(page, seeded, `${label}-middle-drag-after`);
  const rigid = rigidTravel(before, after, travel, generation, `${label}: released middle`, minOtherGenerations);
  stable(held, after, Object.keys(held.nodes), `${label}: middle release added inertia or autoscroll`);
  await page.mouse.move(Math.max(20, point.x + travel.x + 45), Math.max(after.canvasTop + 20, point.y + travel.y + 40), { steps: 8 });
  await sleep(250);
  const buttonUp = await capture(page, seeded, `${label}-middle-button-up-inert`);
  stable(after, buttonUp, Object.keys(after.nodes), `${label}: button-up movement continued middle panning`);
  assert.deepEqual(buttonUp.documentScroll, before.documentScroll, `${label}: native autoscroll continued after release.`);
  await assertNoGestureSelection(page, selected);
  const events = await page.evaluate((start) => window.__canvasMiddleEvents.slice(start), eventStart);
  for (const type of ['pointerdown', 'pointermove', 'pointerup']) assert.ok(events.some((event) => event.type === type &&
    event.trusted && (type !== 'pointermove' || event.buttons === 4)), `${label}: no trusted middle ${type} event.`);
  assert.ok(events.every((event) => event.trusted), `${label}: synthesized middle events are not accepted.`);
  assert.deepEqual(await browserZoomState(page), browserBefore, `${label}: middle drag changed native browser scale/scroll.`);
  assert.deepEqual(await history(page, seeded), journal, `${label}: middle drag changed the immutable journal.`);
  report.scenarios.push({ name: `${label}-rigid-whole-canvas-middle-pan`, percent: await zoomPercent(page),
    point, inputTarget: explicitPoint ? 'explicit canvas padding' : inputTarget || selected, travel, ...rigid, events, before: before.nodes, after: after.nodes,
    selectionUnchanged: true, wholeJournalUnchanged: true, browserDefaultsIsolated: true,
    releaseHasNoInertia: true, buttonUpMovementInert: true });
  return { before, after, ...rigid };
}

async function independentPrimaryDrag(page, seeded, label, portrait) {
  const journal = await history(page, seeded);
  const before = await capture(page, seeded, `${label}-primary-row-before`);
  const selected = seeded.focusName, target = before.nodes[selected];
  assert.ok(target, `${label}: primary row drag has no fully visible target.`);
  const axis = portrait ? 'y' : 'x', otherAxis = portrait ? 'x' : 'y';
  const point = center(target);
  const witnesses = Object.keys(before.nodes).filter((name) => before.nodes[name].generation !== target.generation);
  assert.ok(new Set(witnesses.map((name) => before.nodes[name].generation)).size >= 2,
    `${label}: independent primary drag needs two non-hovered generation witnesses.`);
  await page.mouse.move(point.x, point.y);
  await page.mouse.down();
  let held;
  try {
    await page.mouse.move(point.x - (portrait ? 0 : 60), point.y - (portrait ? 60 : 0), { steps: 12 });
    await sleep(180);
    held = await snapshot(page, seeded, `${label}-primary-row-held`);
    assert.ok(held.nodes[selected], 'Primary row drag hid the selected movement witness.');
    const movement = held.nodes[selected][axis] - target[axis];
    assert.ok(movement <= -40 && movement >= -65, `${label}: primary row travel lost physical pointer movement (${movement}px).`);
    assert.ok(Math.abs(held.nodes[selected][otherAxis] - target[otherAxis]) <= 1.5,
      `${label}: primary row drag changed the outer axis.`);
    stable(before, held, witnesses, `${label}: primary row drag moved an independent level`);
  } finally { await page.mouse.up(); }
  const after = await capture(page, seeded, `${label}-primary-row-after`);
  stable(held, after, Object.keys(held.nodes), `${label}: stopped primary row drag gained release travel`);
  assert.deepEqual(after.documentScroll, before.documentScroll, 'Primary row drag escaped into native page scrolling.');
  await assertNoGestureSelection(page, selected);
  assert.deepEqual(await history(page, seeded), journal, 'Primary row navigation changed the immutable journal.');
  report.scenarios.push({ name: `${label}-primary-cross-axis-row-remains-independent`, percent: await zoomPercent(page), axis,
    movement: round(after.nodes[selected][axis] - target[axis]), witnesses, before: before.nodes, after: after.nodes,
    selectionUnchanged: true, wholeJournalUnchanged: true });
}

async function mouseNavigation(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  const before = await capture(page, seeded, `${label}-left-drag-before`);
  const point = center(before.nodes['Фокус']);
  await page.mouse.move(point.x, point.y);
  await page.mouse.down();
  await page.mouse.move(point.x - 76, point.y, { steps: 12 });
  await sleep(180); // Stop before release rather than accepting fling travel.
  await page.mouse.up();
  const after = await capture(page, seeded, `${label}-left-drag-after`);
  assert.ok(after.nodes['Фокус'], 'Small physical primary drag hid the selected person.');
  const dx = after.nodes['Фокус'].x - before.nodes['Фокус'].x;
  const dy = after.nodes['Фокус'].y - before.nodes['Фокус'].y;
  assert.ok(dx < -20 && dx > -120, `${label}: primary drag did not pan physically horizontally (${dx}px).`);
  assert.ok(Math.abs(dy) <= 1.5, `${label}: horizontal primary drag moved the canvas vertically.`);
  const cross = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  const witnesses = Object.keys(before.nodes).filter((name) => after.nodes[name] && before.nodes[name].generation !== 3);
  assert.ok(new Set(witnesses.map((name) => before.nodes[name].generation)).size >= 2,
    'Primary drag needs at least two independent non-hovered generations.');
  for (const name of witnesses) {
    assert.ok(Math.abs(after.nodes[name][cross] - before.nodes[name][cross]) <= 1.5,
      `${label}: primary drag moved the non-hovered cross-axis row ${name}.`);
    assert.ok(Math.abs(after.nodes[name][main] - before.nodes[name][main] - (main === 'x' ? dx : dy)) <= 1.5,
      `${label}: primary drag did not pan the outer canvas consistently (${name}).`);
  }
  assert.deepEqual(after.documentScroll, before.documentScroll, 'Native browser scrolling escaped the app during primary drag.');
  await assertNoGestureSelection(page);
  assert.deepEqual(await history(page, seeded), journal, 'Primary dragging changed the immutable journal.');
  report.scenarios.push({ name: `${label}-left-physical-drag`, dx, dy, independentWitnesses: witnesses,
    before: before.nodes, after: after.nodes, selectionUnchanged: true, wholeJournalUnchanged: true });
  await independentPrimaryDrag(page, seeded, `${label}-100-percent`, portrait);
  await loadRoom(page, seeded);
  await middleCanvasDrag(page, seeded, `${label}-100-percent`);
  await loadRoom(page, seeded);
}

async function middlePaddingAndBounds(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page);
  await alignAll(page).click();
  await settle(page);
  const pans = [];
  for (const [generation, delta] of [[1, 34], [2, -38], [3, 22]]) {
    pans.push(await crossWheel(page, seeded, portrait, generation, delta, `${label}-g${generation}-ordinary-pan`));
  }
  for (const percent of [100, 150]) {
    await setTreeZoom(page, percent);
    // A genuine outer-axis wheel reaches its leading legal boundary first.
    // Positive middle travel must still move every level away from that bound,
    // including the singleton which has no natural cross-axis scroll extent.
    const viewport = page.viewportSize(), top = await canvasTop(page);
    await page.mouse.move(viewport.width / 2, (top + viewport.height) / 2);
    await page.mouse.wheel(portrait ? -100000 : 0, portrait ? 0 : -100000);
    await settle(page);
    const before = await snapshot(page, seeded, `${label}-${percent}-leading-wheel-bound`);
    assert.ok(before.nodes['Тестовый отец'], `${label}: singleton at the leading bound is not fully visible.`);
    assert.equal(new Set(Object.values(before.nodes).map((box) => box.generation)).size, 4,
      `${label}: padding fixture must expose all four generation levels.`);
    await page.mouse.move(viewport.width / 2, (top + viewport.height) / 2);
    await page.mouse.wheel(portrait ? -600 : 0, portrait ? 0 : -600);
    await settle(page);
    const clamped = await snapshot(page, seeded, `${label}-${percent}-leading-wheel-bound-confirmed`);
    stable(before, clamped, Object.keys(before.nodes), `${label}: outer wheel did not stop at its leading bound`);
    assert.deepEqual(clamped.documentScroll, before.documentScroll, 'Boundary wheel escaped to native browser scrolling.');
    const boxes = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => elements.map((element) => {
      const box = element.getBoundingClientRect();
      return { x: box.x, y: box.y, width: box.width, height: box.height };
    }));
    const candidates = [
      { x: viewport.width - 55, y: top + 35 }, { x: 55, y: top + 35 },
      { x: viewport.width - 55, y: viewport.height - 180 }, { x: 55, y: viewport.height - 180 },
    ];
    const point = candidates.find((candidate) => boxes.every((box) => candidate.x < box.x - 10 ||
      candidate.y < box.y - 10 || candidate.x > box.x + box.width + 10 || candidate.y > box.y + box.height + 10));
    assert.ok(point, `${label}: no genuinely blank canvas-padding target was found.`);
    const evidence = await middleCanvasDrag(page, seeded, `${label}-${percent}-blank-padding-leading-bound`,
      { point, travel: { x: 28, y: 32 } });
    assert.ok(evidence.witnesses.includes('Тестовый отец'), 'Singleton/boundary generation was omitted from rigid middle-pan assertions.');
    assert.equal(evidence.generations.length, 4, 'Blank-padding middle pan did not retain all four generation witnesses.');
    report.scenarios.push({ name: `${label}-${percent}-blank-padding-singleton-and-leading-bound`, point,
      allFourGenerations: evidence.generations, singleton: 'Тестовый отец',
      leadingOuterWheelBoundaryReached: true, ordinaryIndependentPans: pans,
      scope: 'Leading outer wheel bound, singleton cross-axis extent, and blank canvas padding; not an exhaustive bound sweep.' });
  }
  await assertNoGestureSelection(page, seeded.focusName);
  assert.deepEqual(await history(page, seeded), journal, 'Blank-padding/boundary middle navigation changed the journal.');
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Blank-padding/boundary middle navigation changed native browser state.');
  console.log(`PASS: ${label} 100%/150% trusted middle drag from blank canvas padding at leading outer bound; all four levels including singleton move rigidly.`);
}

async function directChildConnections(page, seeded, label, portrait) {
  await select(page, 'Фокус');
  const boxes = {};
  for (const name of ['Фокус', 'Недат06', ...Array.from({ length: 12 }, (_, index) => `Дитя${String(index + 1).padStart(2, '0')}`)]) {
    boxes[name] = await node(page, name).boundingBox();
    assert.ok(boxes[name], `Missing actual child/co-parent geometry: ${name}.`);
  }
  const cross = portrait ? 'y' : 'x';
  const children = Object.entries(boxes).filter(([name]) => name.startsWith('Дитя')).map(([, box]) => box);
  // Flutter clips semantics at the viewport boundary. Use the central pair,
  // not partly clipped outer siblings, for the even-sized block's true center.
  const blockCenter = (center(boxes['Дитя06'])[cross] + center(boxes['Дитя07'])[cross]) / 2;
  const to = portrait ? { x: children[0].x - 6, y: blockCenter } : { x: blockCenter, y: children[0].y - 6 };
  const screenshot = await page.screenshot({ path: path.join(output, `${label}-brighter-transparent-direct-union-links.png`), animations: 'disabled' });
  const evidence = await page.evaluate(async ({ png, boxes, to, portrait }) => {
    const image = new Image();
    image.src = `data:image/png;base64,${png}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width;
    canvas.height = image.height;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const results = [];
    const background = pixel(2, image.height - 5);
    for (const [name, sex] of [['Фокус', [174, 116, 44]], ['Недат06', [51, 139, 100]]]) {
      const box = boxes[name];
      const from = portrait ? { x: box.x + box.width / 2 + 30, y: box.y + 36 } :
        { x: box.x + box.width / 2, y: box.y + 66 };
      const distance = Math.abs(portrait ? to.x - from.x : to.y - from.y);
      const bend = Math.max(24, distance * .48);
      const first = portrait ? { x: from.x + bend, y: from.y } : { x: from.x, y: from.y + bend };
      const second = portrait ? { x: to.x - bend, y: to.y } : { x: to.x, y: to.y - bend };
      const expected = sex.map((channel, index) => channel * .60 + background[index] * .40);
      let visibleSamples = 0;
      let coloredSamples = 0;
      const samples = [];
      for (const t of [.4, .45, .5, .55, .6, .65, .7, .75, .8, .85, .9]) {
        const u = 1 - t;
        const x = u ** 3 * from.x + 3 * u ** 2 * t * first.x + 3 * u * t ** 2 * second.x + t ** 3 * to.x;
        const y = u ** 3 * from.y + 3 * u ** 2 * t * first.y + 3 * u * t ** 2 * second.y + t ** 3 * to.y;
        if (x < 2 || y < 2 || x > image.width - 3 || y > image.height - 3) continue;
        visibleSamples++;
        let best = { error: Infinity };
        for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
          const observed = pixel(x + dx, y + dy);
          // Composite the brighter .60-alpha link over the actual canvas surface;
          // do not keep accepting the former dark, nearly opaque stroke.
          const error = Math.max(...observed.map((channel, index) => Math.abs(channel - expected[index])));
          if (error < best.error) best = { error, observed };
        }
        if (best.error <= 12) coloredSamples++;
        samples.push({ t, x, y, ...best });
      }
      results.push({ name, from, to, expected, visibleSamples, coloredSamples, samples });
    }
    return results;
  }, { png: screenshot.toString('base64'), boxes, to, portrait });
  report.scenarios.push({ name: `${label}-brighter-transparent-selected-child-block-union`, blockCenter, evidence });
  for (const link of evidence) {
    assert.ok(link.visibleSamples >= 3 && link.coloredSamples >= 3,
      `${label}: ${link.name} does not paint the brighter .60-alpha line to its direct child block center: ${JSON.stringify(link)}`);
  }
}

function sameCurrentLayout(before, after, portrait, message) {
  const cross = portrait ? 'y' : 'x';
  const common = new Set(Object.keys(before.nodes).filter((name) => after.nodes[name]));
  for (const generation of new Set([...common].map((name) => before.nodes[name].generation))) {
    const expected = order(before, generation, portrait).filter((name) => common.has(name));
    const actual = order(after, generation, portrait).filter((name) => common.has(name));
    assert.deepEqual(actual, expected, `${message}: generation ${generation} depends on navigation history.`);
    const anchor = expected[0];
    for (const name of expected) {
      const beforeDelta = before.nodes[name][cross] - before.nodes[anchor][cross];
      const afterDelta = after.nodes[name][cross] - after.nodes[anchor][cross];
      assert.ok(Math.abs(afterDelta - beforeDelta) <= 1.5,
        `${message}: ${name}'s within-generation layout drifted ${beforeDelta} → ${afterDelta}.`);
    }
  }
}

async function repeatedSelections(page, seeded, label, portrait) {
  const baseline = await capture(page, seeded, `${label}-selection-baseline`);
  const siblings = order(baseline, 3, portrait).filter((name) => name !== 'Фокус');
  assert.ok(siblings.length >= 2 && baseline.nodes['Отец'] && baseline.nodes['Мать'] && baseline.nodes['Фокус'],
    'The fixture must expose undated siblings and both parents together.');
  const cross = portrait ? 'y' : 'x';
  const nearFocus = siblings.slice().sort((a, b) =>
    Math.abs(baseline.nodes[a][cross] - baseline.nodes['Фокус'][cross]) -
    Math.abs(baseline.nodes[b][cross] - baseline.nodes['Фокус'][cross])).slice(0, 2);
  const sequence = [nearFocus[0], nearFocus[1], 'Фокус', 'Отец', 'Мать', 'Фокус'];
  const states = new Map([['Фокус', baseline]]), changes = [];
  // Different current people may require different canonical ancestor/co-parent
  // orders. Returning to the SAME current must never inherit those other orders.
  for (let cycle = 1; cycle <= 3; cycle++) {
    for (const name of sequence) {
      await select(page, name);
      const after = await snapshot(page, seeded, `${label}-select-${cycle}-${name}`);
      if (states.has(name)) sameCurrentLayout(states.get(name), after, portrait, `${label}/${cycle}/${name}`);
      else states.set(name, after);
      changes.push({ cycle, selected: name, nodes: after.nodes });
    }
  }
  await capture(page, seeded, `${label}-selection-after-18-clicks`);
  report.scenarios.push({ name: `${label}-undated-same-current-canonical-layout`, sequence, cycles: 3, changes,
    contract: 'Canonical ordering/relative geometry for each current person; per-generation viewport translation may differ.' });
}

async function avatarVisual(page, seeded, label) {
  await select(page, 'Фокус');
  const box = await node(page, 'Фокус').boundingBox();
  assert.ok(Math.abs(box.width - 108) <= 1 && Math.abs(box.height - 108) <= 1,
    `Actual semantic node must be 108px square, got ${box.width}x${box.height}.`);
  const png = await page.screenshot({ path: path.join(output, `${label}-avatar-108px-node.png`),
    clip: { x: box.x, y: box.y, width: box.width, height: box.height }, animations: 'disabled' });
  // Decode the real screenshot in a detached browser canvas, not the app canvas.
  // This observes pixels only; nothing is inserted into the app or intercepted.
  const pixels = await page.evaluate(async (base64) => {
    const image = new Image();
    image.src = `data:image/png;base64,${base64}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width;
    canvas.height = image.height;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const data = context.getImageData(0, 0, image.width, image.height).data;
    const pixel = (x, y) => [...data.slice((y * image.width + x) * 4, (y * image.width + x) * 4 + 3)];
    let greenPhotoPixels = 0;
    for (let y = 16; y < 55; y++) for (let x = 34; x < 74; x++) {
      const [r, g, b] = pixel(x, y);
      if (g > r + 15 && g > b + 5) greenPhotoPixels++;
    }
    return { width: image.width, height: image.height, greenPhotoPixels,
      // Avatar is 60px, centered in a 108px node, with top inset 6 and border 3.
      leftBorder: [pixel(24, 36), pixel(25, 36), pixel(26, 36)],
      rightBorder: pixel(82, 36), topBorder: pixel(54, 7), bottomBorder: pixel(54, 64),
      roundedSquareShoulder: pixel(25, 18), interior: pixel(29, 36),
      cardBorder: [pixel(0, 54), pixel(107, 54), pixel(54, 0), pixel(54, 107)],
      cardInterior: pixel(2, 54) };
  }, png.toString('base64'));
  const male = [135, 88, 38];
  const isRing = (sample) => sample.every((entry, index) => Math.abs(entry - male[index]) <= 14);
  assert.ok(pixels.leftBorder.every(isRing) && isRing(pixels.rightBorder) &&
    isRing(pixels.topBorder) && isRing(pixels.bottomBorder),
  `${label}: screenshot does not show the expected 60px avatar with a 3px gender ring: ${JSON.stringify(pixels)}`);
  assert.ok(isRing(pixels.roundedSquareShoulder), 'Avatar regressed from a rounded square to a circle.');
  assert.ok(!isRing(pixels.interior), 'Avatar ring is thicker than 3px or the photo failed to paint.');
  assert.ok(pixels.greenPhotoPixels > 150, 'Seeded real PNG avatar did not decode/paint (initials fallback is not sufficient).');
  // Fractional semantic origins can leave the last screenshot row half-covered
  // by the 1.5px bottom stroke; the other three sides have solid interior pixels.
  assert.ok(pixels.cardBorder.slice(0, 3).every(isRing) && !isRing(pixels.cardInterior) &&
    pixels.cardBorder[3].some((channel, index) => Math.abs(channel - pixels.cardInterior[index]) > 25),
  `${label}: selected Material card lost its thin sex-colored outline: ${JSON.stringify(pixels.cardBorder)}`);
  report.scenarios.push({ name: `${label}-actual-avatar-pixels`, semanticBox: box, pixels });
}

async function contextClick(page, x, y) {
  // BrowserContextMenu disable/enable is asynchronous; exercise a real hover
  // before clicking rather than racing MouseRegion's platform call.
  await page.mouse.move(x, y);
  await sleep(300);
  const count = await page.evaluate(() => window.__canvasContextMenus.length);
  await page.mouse.click(x, y, { button: 'right' });
  await until(() => page.evaluate((previous) => window.__canvasContextMenus.length > previous &&
    window.__canvasContextMenus.at(-1).prevented !== null, count),
  'The passive document observer did not receive a real contextmenu event.', 5000);
  const event = await page.evaluate(() => window.__canvasContextMenus.at(-1));
  assert.equal(event.trusted, true, 'The context menu must come from real browser input.');
  assert.equal(event.cancelable, true, 'The real contextmenu event must permit app suppression.');
  await page.keyboard.press('Escape'); // Dismiss any native menu without preventing its event ourselves.
  return event;
}

async function biographyBySecondaryClick(page, seeded, label) {
  const outside = await contextClick(page, page.viewportSize().width / 2, 10);
  assert.equal(outside.prevented, false, 'Browser context menus were disabled globally, not only over tree nodes.');
  assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0,
    'A non-node secondary click opened a biography.');
  const evidence = [];
  for (const name of ['Недат06', 'Отец']) {
    const box = await node(page, name).boundingBox();
    assert.ok(box, `Secondary-click target ${name} has no actual semantic bounds.`);
    const point = center(box);
    const event = await contextClick(page, point.x, point.y);
    assert.equal(event.prevented, true, `${label}: native context menu was not suppressed over ${name}.`);
    await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Изменить', exact: true }).click();
    const nameField = page.getByRole('textbox', { name: 'Имя', exact: true });
    await nameField.waitFor();
    // Flutter attaches the native editable value only when the field is focused.
    await nameField.click();
    await nameField.focus();
    await until(async () => await nameField.inputValue() === name,
      `Secondary click did not expose ${name}'s actual biography name.`, 5000);
    await page.screenshot({ path: path.join(output, `${label}-secondary-biography-${name}.png`), animations: 'disabled' });
    evidence.push({ name, nodeBox: box, event, actualBiographyName: await nameField.inputValue() });
    await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
    await settle(page);
  }
  const outsideAfter = await contextClick(page, page.viewportSize().width / 2, 10);
  assert.equal(outsideAfter.prevented, false, 'Node hover/biography left the browser context menu disabled after exit.');
  report.scenarios.push({ name: `${label}-secondary-click-biography-and-native-menu`, outside, outsideAfter, nodes: evidence });
}

async function wheelAtBoundary(page, seeded, label, portrait) {
  await select(page, 'Фокус');
  const box = await node(page, 'Фокус').boundingBox();
  const point = center(box);
  const initial = await snapshot(page, seeded, `${label}-boundary-initial`);
  const witnesses = Object.keys(initial.nodes).filter((name) => initial.nodes[name].generation !== 3);
  await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(0, 100000);
  const edge = await capture(page, seeded, `${label}-wheel-at-end`);
  const main = portrait ? 'x' : 'y';
  if (portrait) {
    stable(initial, edge, witnesses, 'Reaching the hovered generation edge moved another generation');
    const hovered = Object.keys(edge.nodes).filter((name) => edge.nodes[name].generation === 3);
    assert.ok(hovered.includes('Недат10'), 'Large portrait wheel did not reach the last undated sibling.');
  } else {
    assert.ok(edge.nodes['Внук1'], 'Large landscape wheel did not reach the final generation.');
    for (const name of Object.keys(initial.nodes).filter((candidate) => edge.nodes[candidate])) {
      assert.ok(Math.abs(initial.nodes[name].x - edge.nodes[name].x) <= 1.5,
        'Landscape wheel boundary changed a generation’s horizontal position.');
    }
  }
  const atEdge = [];
  for (let attempt = 1; attempt <= 3; attempt++) {
    await page.mouse.move(point.x, point.y);
    await page.mouse.wheel(0, 600);
    await settle(page);
    const after = await snapshot(page, seeded, `${label}-boundary-${attempt}`);
    stable(edge, after, Object.keys(edge.nodes), `${label}: wheel escaped a generation at its edge`);
    assert.deepEqual(order(after, 3, portrait), order(edge, 3, portrait));
    assert.deepEqual(after.documentScroll, edge.documentScroll);
    atEdge.push({ attempt, nodes: after.nodes });
  }
  await capture(page, seeded, `${label}-wheel-boundary-after-three-more`);
  report.scenarios.push({ name: `${label}-wheel-boundary-does-not-chain`, mainAxis: main, witnesses, edge: edge.nodes, atEdge });
}

async function chooseKind(page, kind) {
  await page.getByRole('alertdialog').getByRole('button', { name: /^Кого добавить/ }).click();
  await page.getByRole('menuitem', { name: kind, exact: true }).click();
}

async function chooseNewPersonSex(page, expected) {
  const sex = page.getByRole('alertdialog').getByRole('button', { name: /^Пол(?:\s|$)/ });
  await sex.click();
  for (const option of ['Пол не указан', 'Мужской', 'Женский']) await page.getByRole('menuitem', { name: option, exact: true }).waitFor();
  await page.getByRole('menuitem', { name: expected, exact: true }).click();
  assert.match(await sex.getAttribute('aria-label') || await sex.innerText(), new RegExp(expected));
}

async function assertFixedSex(page, expected, fieldPattern = /^Пол(?:\s|$)/) {
  const dialog = page.getByRole('alertdialog');
  const sex = dialog.getByRole('button', { name: fieldPattern });
  await sex.waitFor();
  const label = await sex.getAttribute('aria-label') || await sex.innerText();
  assert.match(label, new RegExp(expected));
  const box = await sex.boundingBox();
  // Flutter's disabled DropdownButton still exports role=button without
  // aria-disabled, so test the actual pointer behavior, not isDisabled().
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(200);
  assert.equal(await page.getByRole('menuitem').count(), 0, 'Role-fixed parent sex opened editable options.');
  assert.equal(await sex.getAttribute('aria-label') || await sex.innerText(), label,
    'Clicking the role-fixed parent sex changed its value.');
}

const activeInputValue = (page) => page.evaluate(() => {
  const input = document.activeElement;
  return input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement ? input.value : null;
});

async function focusInput(page, field, expected) {
  await field.click();
  await field.focus();
  await sleep(150); // Flutter attaches its native editing element after the semantic tap.
  await until(async () => {
    const value = await activeInputValue(page);
    // Flutter's semantic input can remain empty on mobile while its separate
    // native editing host contains the actual focused value.
    return value !== null && (expected === undefined || value === expected);
  }, `The actual focused native input did not expose ${JSON.stringify(expected ?? 'the field value')}.`, 10000);
}

async function type(page, field, text) {
  await focusInput(page, field);
  await page.keyboard.press('Control+A');
  await until(() => page.evaluate(() => {
    const input = document.activeElement;
    return input?.selectionStart === 0 && input?.selectionEnd === input?.value?.length;
  }), 'The actual native input did not select its complete previous value.', 5000);
  // Replace the selection directly: an extra Backspace would deliberately clear
  // a register/inheritance before entering the replacement surname.
  if (text) await page.keyboard.type(text, { delay: 30 });
  else await page.keyboard.press('Backspace');
  await until(async () => await activeInputValue(page) === text, 'The actual native input lost or reordered typed characters.', 10000);
}

async function useExistingRelative(page) {
  const dialog = page.getByRole('alertdialog');
  await dialog.getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).waitFor();
}

async function relativeTreeSelection(page, seeded, label) {
  await loadRoom(page, seeded);
  const original = await snapshot(page, seeded, `${label}-relative-original`);
  const unchanged = await history(page, seeded);
  const assertUnchanged = async () => assert.deepEqual(await history(page, seeded), unchanged,
    `${label}: browsing/cancelling a pending relative selection wrote to the journal.`);
  const dialog = page.getByRole('alertdialog');
  const pick = dialog.getByRole('button', { name: 'Выбрать', exact: true });
  const cancel = page.getByRole('button', { name: 'Отмена выбора', exact: true });
  const confirm = () => page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ });
  const addRelative = async () => {
    const action = page.getByRole('button', { name: 'Добавить родственника', exact: true });
    await revealBiography(page, action);
    await action.click();
    await useExistingRelative(page);
    await pick.waitFor();
    assert.equal(await pick.count(), 1, 'Existing-relative selection must have exactly one Choose action.');
    assert.equal(await dialog.getByRole('button', { name: /^Человек из дерева/ }).count(), 0,
      'The removed candidate dropdown is still exposed.');
  };
  const openPicker = async () => {
    await pick.click();
    await cancel.waitFor();
    await page.getByRole('textbox', { name: 'Поиск по дереву', exact: true }).waitFor();
    await settle(page);
    assert.equal(await dialog.count(), 0, 'The picker must cover the relative dialog.');
    assert.equal(await page.getByRole('button', { name: 'Биография', exact: true }).count(), 0,
      'The picker must replace biography with its floating confirmation action.');
    await confirm().waitFor();
  };
  const chooseCandidate = async () => {
    await select(page, 'Недат05');
    assert.equal(await cancel.count(), 1, 'A valid node tap returned before explicit confirmation.');
    assert.equal(await dialog.count(), 0);
    assert.equal(await confirm().isEnabled(), true);
    await assertUnchanged();
    await confirm().click();
    await dialog.waitFor();
    assert.match(await dialog.ariaSnapshot(), /Недат05/);
    assert.match(await dialog.ariaSnapshot(), /Отца/);
    await assertUnchanged();
  };
  await openBiography(page, null, true);
  await addRelative();
  await openPicker();
  await select(page, 'Фокус');
  assert.equal(await confirm().isDisabled(), true, 'Invalid self focus enabled confirmation.');
  assert.equal(await page.getByText('Этот человек не подходит для выбранной связи.', { exact: true }).count(), 0,
    'Invalid node browsing must not show a Snackbar.');
  await chooseCandidate();
  const previous = await dialog.ariaSnapshot();
  await openPicker();
  await select(page, 'Фокус');
  await cancel.click();
  await dialog.waitFor();
  assert.equal(await dialog.ariaSnapshot(), previous, 'Picker cancellation changed its previously confirmed pending summary.');
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(page);
  stable(original, await snapshot(page, seeded, `${label}-relative-cancelled`), Object.keys(original.nodes),
    'Cancelling changed the main tree');
  await assertUnchanged();

  await openBiography(page, null, true);
  await addRelative();
  assert.doesNotMatch(await dialog.ariaSnapshot(), /Недат05/, 'A cancelled dialog retained its pending relative.');
  await openPicker();
  await chooseCandidate();
  await page.screenshot({ path: path.join(output, `${label}-relative-valid-pending.png`), animations: 'disabled' });
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  await until(async () => (await history(page, seeded)).length > unchanged.length, 'Confirmed relative was not saved.');
  const appended = await appendedOperations(page, seeded, unchanged);
  assert.deepEqual(appended, [{ type: 'setValue', personId: 'root', field: 'fatherId', value: 'a-sibling-05' }]);
  assert.doesNotMatch(await body(page), /Не сохранено:|Не удалось добавить родственника/);
  await closeBiography(page);
  await loadRoom(page, seeded);
  await openBiography(page);
  await until(async () => /Отец[\s\S]*Недат05/.test(await body(page)), 'Reload lost the confirmed father link.');
  await page.screenshot({ path: path.join(output, `${label}-relative-confirmed-reload.png`), animations: 'disabled' });
  report.scenarios.push({ name: `${label}-relative-tree-selection`, viewport: page.viewportSize(),
    singleChooseAction: true, tapsBrowseUntilConfirmed: true, invalidFocusDisabledWithoutSnackbar: true,
    pendingJournalUnchanged: true, cancelledBiographyAndTreeUnchanged: true, persisted: appended[0] });
  console.log(`PASS: ${label} single-button relative picker; browsing/invalid focus, explicit confirmation, cancellation, pending journal isolation, durable father link.`);
}

async function revealBiography(page, locator, direction = 1) {
  for (let attempt = 0; attempt < 18; attempt++) {
    const box = await locator.count() ? await locator.boundingBox() : null;
    if (box && box.y >= 75 && box.y + box.height <= page.viewportSize().height - 15) return box;
    await page.mouse.move(page.viewportSize().width - 30, page.viewportSize().height / 2);
    await page.mouse.wheel(0, direction * 330);
    await sleep(180);
  }
  throw new Error('Biography control did not become visible through real pointer scrolling.');
}

async function openBiography(page, name, editing = false) {
  if (name) await select(page, name);
  await page.getByRole('button', { name: 'Биография', exact: true }).click();
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor();
  if (editing) await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  await settle(page);
}

async function closeBiography(page) {
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
  await settle(page);
}

async function appendedOperations(page, seeded, before) {
  const records = await history(page, seeded);
  for (const old of before) {
    assert.deepEqual(records.find((record) => record.id === old.id), old, 'Editing changed or removed an immutable history record.');
  }
  return records.filter((record) => !before.some((old) => old.id === record.id))
    .map((record) => {
      assert.equal(record.kind, 'tree');
      return JSON.parse(record.text);
    });
}

async function unlinkChip(page, relativeName) {
  const chip = page.getByRole('checkbox', { name: relativeName, exact: true });
  await revealBiography(page, chip);
  // InputChip's X has its own real semantic hit target. Exercise it rather
  // than the main checkbox/label, which navigates to the relative biography.
  const close = chip.getByRole('button', { name: 'удалить связь', exact: true });
  const closeBox = await close.boundingBox();
  await close.hover();
  await page.getByText('удалить связь', { exact: true }).first().waitFor();
  assert.match(await body(page), /text: удалить связь/, 'Actual X hover lost its tooltip.');
  await page.screenshot({ path: path.join(output, `unlink-tooltip-${relativeName}-${page.viewportSize().width}.png`), animations: 'disabled' });
  // Flutter may merge the visible tooltip into this button's accessible name.
  // Keep using the original real hit box rather than racing semantic relabeling.
  await page.mouse.click(center(closeBox).x, center(closeBox).y);
  await settle(page);
}

async function relationshipEditing(page, seeded, label) {
  await loadRoom(page, seeded);
  await openBiography(page, 'Наталья');
  assert.equal(await page.getByRole('button', { name: 'Удалить человека', exact: true }).count(), 0);
  assert.doesNotMatch(await body(page), /удалить связь|Изменения сохраняются|Обмен с участниками/);
  await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  const addBox = await revealBiography(page, page.getByRole('button', { name: 'Добавить родственника', exact: true }));
  const fatherBox = await page.getByRole('checkbox', { name: 'Геннадий', exact: true }).boundingBox();
  assert.ok(fatherBox && addBox.y + addBox.height <= fatherBox.y,
    'Edit mode must retain the relative list below the Add relative action.');
  const initial = await history(page, seeded);
  const sibling = page.getByRole('checkbox', { name: 'Вероника', exact: true });
  await revealBiography(page, sibling);
  assert.equal(await sibling.getByRole('button', { name: /удалить связь/ }).count(), 0,
    'Sibling chips must not offer inferred-parent unlink commands.');
  assert.deepEqual(await history(page, seeded), initial, 'Inspecting sibling controls wrote history.');
  await unlinkChip(page, 'Геннадий');
  await until(async () => (await history(page, seeded)).length === initial.length + 1,
    'Parent X did not persist its single relationship removal.');
  assert.deepEqual(await appendedOperations(page, seeded, initial),
    [{ type: 'setValue', personId: 'root', field: 'fatherId', value: null }]);
  assert.equal(await page.getByRole('checkbox', { name: 'Лидия', exact: true }).count(), 1,
    'Unlinking the father removed the unrelated mother edge.');
  await closeBiography(page);
  await openBiography(page, 'Лидия', true);
  const beforeChild = await history(page, seeded);
  await unlinkChip(page, 'Наталья');
  await until(async () => (await history(page, seeded)).length === beforeChild.length + 1,
    'Child X did not persist its single parent edge removal.');
  assert.deepEqual(await appendedOperations(page, seeded, beforeChild),
    [{ type: 'setValue', personId: 'root', field: 'motherId', value: null }]);
  await closeBiography(page);
  await loadRoom(page, seeded);
  for (const name of ['Наталья', 'Вероника', 'Геннадий', 'Лидия']) {
    assert.equal(await node(page, name).count(), 1, `Unlinking deleted ${name} instead of just the edge.`);
  }
  await openBiography(page, 'Наталья', true);
  assert.equal(await page.getByRole('checkbox', { name: 'Геннадий', exact: true }).count(), 0);
  assert.equal(await page.getByRole('checkbox', { name: 'Лидия', exact: true }).count(), 0);
  await page.screenshot({ path: path.join(output, `${label}-unlinked-edges-after-reload.png`), animations: 'disabled' });
  report.scenarios.push({ name: `${label}-edit-relatives-and-unlink`, siblingUnlinkAbsent: true,
    parentAndChildUnlinkOnlyTheirEdge: true, allPeopleSurviveReload: true });
  await closeBiography(page);
}

async function lydiaGenerationRegression(page, seeded, label) {
  await loadRoom(page, seeded);
  await capture(page, seeded, `${label}-original-gennady-lydia-before`);
  await openBiography(page, 'Лидия', true);
  await page.getByRole('button', { name: 'Добавить родственника', exact: true }).click();
  await page.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
  await assertFixedSex(page, 'Мужской');
  await type(page, page.getByRole('textbox', { name: 'Имя нового человека', exact: true }), 'Тест');
  await page.getByRole('alertdialog').getByRole('button', { name: 'Добавить', exact: true }).click();
  await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
  const operations = (await history(page, seeded)).filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text));
  const father = operations.find((entry) => entry.type === 'createPerson' && entry.name === 'Тест');
  assert.ok(father && father.sex === 'male', 'The screenshot regression must use a real UI-created father.');
  assert.ok(operations.some((entry) => entry.type === 'setValue' && entry.personId === 'lydia' && entry.field === 'fatherId' && entry.value === father.personId));
  seeded.people.push({ id: father.personId, name: 'Тест', sex: 'male', generation: 0 });
  for (const person of seeded.people.filter((entry) => entry.id !== father.personId)) person.generation++;
  await closeBiography(page);
  const assertRanks = async (title) => {
    const state = await capture(page, seeded, title);
    const portrait = page.viewportSize().width < page.viewportSize().height;
    const axis = portrait ? 'x' : 'y';
    const boxes = {};
    for (const name of ['Тест', 'Геннадий', 'Лидия', 'Наталья', 'Вероника']) {
      boxes[name] = await node(page, name).boundingBox();
      assert.ok(boxes[name], `Original family regression lost ${name}.`);
    }
    assert.ok(Math.abs(boxes['Геннадий'][axis] - boxes['Лидия'][axis]) <= 1.5,
      `${title}: adding Lydia’s father split Gennady/Lydia across generations.`);
    assert.ok(boxes['Тест'][axis] < boxes['Лидия'][axis] - 100);
    assert.ok(boxes['Наталья'][axis] > boxes['Лидия'][axis] + 100);
    assert.ok(Math.abs(boxes['Наталья'][axis] - boxes['Вероника'][axis]) <= 1.5);
    return { nodes: state.nodes, boxes };
  };
  const beforeReload = await assertRanks(`${label}-original-test-father-added`);
  await loadRoom(page, seeded);
  const afterReload = await assertRanks(`${label}-original-test-father-reloaded`);
  report.scenarios.push({ name: `${label}-original-gennady-lydia-regression`, father, beforeReload, afterReload });
}

async function childParentRoles(page, seeded, label) {
  await loadRoom(page, seeded);
  for (const [name, expected, field] of [['Геннадий', 'Отец ребёнка', 'fatherId'], ['Лидия', 'Мать ребёнка', 'motherId']]) {
    await openBiography(page, name, true);
    await revealBiography(page, page.getByRole('button', { name: 'Добавить родственника', exact: true }));
    await page.getByRole('button', { name: 'Добавить родственника', exact: true }).click();
    await chooseKind(page, 'Ребёнка');
    await assertFixedSex(page, expected, /^Роль выбранного человека/);
    await page.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
    const sexPicker = page.getByRole('alertdialog').getByRole('button', { name: /^Пол(?:\s|$)/ });
    await sexPicker.click();
    for (const option of ['Пол не указан', 'Мужской', 'Женский']) await page.getByRole('menuitem', { name: option, exact: true }).waitFor();
    await page.getByRole('menuitem', { name: 'Пол не указан', exact: true }).click();
    const childName = `Ребёнок ${name}`;
    await type(page, page.getByRole('textbox', { name: 'Имя нового человека', exact: true }), childName);
    const before = await history(page, seeded);
    await page.getByRole('alertdialog').getByRole('button', { name: 'Добавить', exact: true }).click();
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
    const operations = await appendedOperations(page, seeded, before);
    const created = operations.find((entry) => entry.type === 'createPerson' && entry.name === childName);
    assert.ok(created && created.sex === 'unknown');
    const parentId = name === 'Геннадий' ? 'gennady' : 'lydia';
    assert.ok(operations.some((entry) => entry.type === 'setValue' && entry.personId === created.personId && entry.field === field && entry.value === parentId),
      'Known-sex child creation linked the selected person into the wrong parent role.');
    report.scenarios.push({ name: `${label}-child-parent-role-${field}-fixed`, operations });
    await closeBiography(page);
  }
  // The new child has unknown sex: its parental role must remain selectable.
  await openBiography(page, 'Ребёнок Геннадий', true);
  await page.getByRole('button', { name: 'Добавить родственника', exact: true }).click();
  await chooseKind(page, 'Ребёнка');
  const role = page.getByRole('alertdialog').getByRole('button', { name: /^Роль выбранного человека/ });
  await role.click();
  await page.getByRole('menuitem', { name: 'Отец ребёнка', exact: true }).waitFor();
  await page.getByRole('menuitem', { name: 'Мать ребёнка', exact: true }).click();
  assert.match(await role.getAttribute('aria-label') || await role.innerText(), /Мать ребёнка/);
  await page.getByRole('alertdialog').getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(page);
  report.scenarios.push({ name: `${label}-unknown-sex-child-parent-role-selectable` });
}

async function deleteLastPerson(page, seeded, label) {
  await loadRoom(page, seeded);
  await openBiography(page, 'Фокус');
  assert.equal(await page.getByRole('button', { name: 'Удалить человека', exact: true }).count(), 0);
  await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  const remove = page.getByRole('button', { name: 'Удалить человека', exact: true });
  await revealBiography(page, remove);
  assert.doesNotMatch(await body(page), /Изменения сохраняются|Обмен с участниками/);
  const before = await history(page, seeded);
  await remove.click();
  const dialog = page.getByRole('alertdialog');
  await dialog.getByText('Удалить человека?', { exact: true }).waitFor();
  assert.match(await body(page), /Другие люди останутся в дереве.*Это действие нельзя отменить/);
  await page.screenshot({ path: path.join(output, `${label}-delete-person-confirmation.png`), animations: 'disabled' });
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  assert.deepEqual(await history(page, seeded), before, 'Cancelling last/root deletion changed the journal.');
  await remove.click();
  await dialog.getByRole('button', { name: 'Удалить', exact: true }).click();
  await page.getByText('В дереве пока никого нет', { exact: true }).waitFor();
  await until(async () => (await history(page, seeded)).length === before.length + 1, 'Last/root tombstone was not saved.');
  assert.deepEqual(await appendedOperations(page, seeded, before), [{ type: 'deletePerson', personId: 'root' }]);
  assert.equal(await page.getByRole('button', { name: /^Выбрать / }).count(), 0);
  await loadRoom(page, seeded, null);
  await page.getByRole('button', { name: 'Добавить человека', exact: true }).waitFor();
  await page.screenshot({ path: path.join(output, `${label}-empty-editor-after-reload.png`), animations: 'disabled' });
  const finalRecords = await history(page, seeded);
  const create = page.getByRole('button', { name: 'Добавить человека', exact: true });
  await create.click();
  // Empty-tree creation immediately adds a durable person and opens biography.
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).waitFor();
  await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  await page.getByRole('textbox', { name: 'Имя', exact: true }).waitFor();
  await until(async () => (await history(page, seeded)).length > finalRecords.length, 'Empty editor action did not create a person.');
  const additions = await appendedOperations(page, seeded, finalRecords);
  assert.ok(additions.some((entry) => entry.type === 'createPerson' && entry.personId !== 'root'),
    'Empty-tree creation resurrected the permanent root tombstone.');
  assert.equal(await node(page, 'Фокус').count(), 0, 'Fresh creation resurrected the deleted virtual root.');
  report.scenarios.push({ name: `${label}-delete-root-and-last-person`, cancelledUnchanged: true,
    tombstone: { type: 'deletePerson', personId: 'root' }, emptyReload: true, canCreateFreshPerson: true });
}

// Finite release-browser cases for editor refinements. Reuse the established
// Olga/Nikita journal; every new relative below is created by actual UI input.
const flutterFailure = /EXCEPTION CAUGHT|Another exception was thrown|RenderFlex.*overflow|RenderBox was not laid out|Unexpected null value|Null check operator used on a null value|Incorrect use of ParentDataWidget|Assertion failed/i;
async function refinementCheckpoint(page, label, screenshot = false) {
  await sleep(220);
  const semantics = await body(page);
  const entry = { label, viewport: page.viewportSize(), semantics,
    pageErrors: [...report.pageErrors], consoleErrors: [...report.consoleErrors],
    flutterErrors: [...(report.flutterErrors || [])] };
  report.checkpoints ??= [];
  report.checkpoints.push(entry);
  await fs.writeFile(path.join(output, `${label}.json`), JSON.stringify(entry, null, 2));
  if (screenshot) await page.screenshot({ path: path.join(output, `${label}.png`), animations: 'disabled' });
  assert.deepEqual(entry.pageErrors, [], `${label}: an intermediate page raised an error.`);
  assert.deepEqual(entry.consoleErrors, [], `${label}: an intermediate page logged an error.`);
  assert.deepEqual(entry.flutterErrors, [], `${label}: Flutter reported a rendering error, including non-error console messages.`);
  assert.doesNotMatch(semantics, flutterFailure, `${label}: the actual UI contains a Flutter error.`);
  assert.doesNotMatch(semantics, /Не сохранено:|Не удалось добавить родственника/);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), page.viewportSize().width,
    `${label}: the document has horizontal overflow.`);
}
function editorRefinementFixture() {
  const seed = fixture({ family: 'trunk-modes' });
  seed.operation({ type: 'setSurname', personId: 'root', scope: 'individual', familyKey: null,
    text: 'Иванов', decline: true });
  seed.operation({ type: 'editText', personId: 'root', field: 'biography', itemId: null,
    inserts: [...'Биография Ольги: семейная история.'].map((text, index) => ({
      id: `refinement-bio-${index}`, text, left: index ? `refinement-bio-${index - 1}` : null, right: null })), deletes: [] });
  seed.operation({ type: 'addFact', personId: 'root', itemId: 'refinement-fact',
    text: 'Первый памятный факт', color: '#E6DCCB', afterId: null, beforeId: null });
  return seed.finish();
}
async function refinementBiography(page, seeded, label) {
  const before = await history(page, seeded);
  await type(page, treeSearch(page), 'Ольга Иванова');
  const result = searchOption(page, 'Ольга Иванова');
  await result.waitFor();
  assert.doesNotMatch(await result.ariaSnapshot(), /Иванова Ольга/);
  await result.click();
  await settle(page);
  await openBiography(page);
  const read = await body(page);
  // Mobile Flutter exports readonly SelectableText as an empty disabled
  // textbox. The real search label proves fullName; retain biography pixels.
  if (page.viewportSize().width >= 700) assert.match(read, /Ольга Иванова/);
  assert.doesNotMatch(read, /Иванова Ольга/);
  const factIndex = read.indexOf('Факты и воспоминания');
  const bioIndex = read.indexOf('О человеке');
  assert.ok(factIndex >= 0 && bioIndex > factIndex, 'Facts must precede the biography in actual read-mode semantics.');
  const factsHeading = page.getByText('Факты и воспоминания', { exact: true });
  await revealBiography(page, factsHeading);
  await refinementCheckpoint(page, `${label}-facts-before-biography-read`, true);
  await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  const edit = await body(page);
  assert.ok(edit.indexOf('Факты и воспоминания') >= 0 && edit.indexOf('О человеке') > edit.indexOf('Факты и воспоминания'),
    'Facts must precede the biography in actual edit-mode semantics.');
  const factField = page.getByRole('textbox', { name: 'Факт', exact: true });
  await revealBiography(page, factField);
  await focusInput(page, factField, 'Первый памятный факт');
  await refinementCheckpoint(page, `${label}-facts-before-biography-edit`, true);
  await closeBiography(page);
  assert.deepEqual(await history(page, seeded), before, 'Reading/searching/focusing facts or biography wrote hidden operations.');
  report.scenarios.push({ name: `${label}-given-name-first-and-facts-before-biography`, readOrder: ['facts', 'biography'],
    editOrder: ['facts', 'biography'], fullName: 'Ольга Иванова', completeJournalUnchanged: true,
    colorEvidence: `${label}-facts-before-biography-read.png (visual inspection; not a numeric color-contrast guarantee)` });
}
async function refinementAddRelative(page, seeded, label, { person, kind, name, sex, option, field, parentId, traceSubmit = false }) {
  await openBiography(page, person, true);
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add);
  if (traceSubmit) await relativeActionOrder(page, label);
  await add.click();
  const dialog = page.getByRole('alertdialog');
  await chooseKind(page, kind);
  await refinementCheckpoint(page, `${label}-kind-selected`);
  await dialog.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
  await refinementCheckpoint(page, `${label}-new-person-intermediate`, true);
  await type(page, dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
  if (option) {
    await dialog.getByRole('button', { name: /^Пол(?:\s|$)/ }).click();
    await refinementCheckpoint(page, `${label}-sex-menu-open`);
    await page.getByRole('menuitem', { name: option, exact: true }).click();
  }
  await dialog.getByRole('button', { name: 'Дата рождения (необязательно)', exact: true }).waitFor();
  const before = await history(page, seeded);
  await refinementCheckpoint(page, `${label}-sex-chosen-birth-omitted`, true);
  if (traceSubmit) await parentSubmitWithoutFalseFlash(page, dialog, label);
  else {
    await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
  }
  await until(async () => (await history(page, seeded)).length >= before.length + 2, 'Relative creation did not become durable.');
  const operations = await appendedOperations(page, seeded, before);
  const created = operations.filter((operation) => operation.type === 'createPerson');
  assert.equal(created.length, 1, 'Submitting the relative form must create exactly one person.');
  assert.equal(created[0].name, name);
  assert.equal(created[0].sex, sex);
  const expectedLink = kind === 'Ребёнка'
    ? { type: 'setValue', personId: created[0].personId, field, value: parentId }
    : { type: 'setValue', personId: parentId, field, value: created[0].personId };
  assert.equal(operations.length, 2, 'No DOB or unrelated writes are expected when the optional birth date is omitted.');
  assert.deepEqual(operations.filter((operation) => operation.type === 'setValue'), [expectedLink],
    'The durable parent/child link has the wrong direction or role; JSON key order is not semantic.');
  await refinementCheckpoint(page, `${label}-created-durable`, true);
  await closeBiography(page);
  report.scenarios.push({ name: label, actualUiCreated: created[0], exactOperations: operations, birthDateOmitted: true });
  return created[0];
}
async function refinementParentRanks(page, label, parents) {
  const boxes = {};
  for (const name of ['Олег', 'Геннадий', 'Лидия', 'Наталья', ...parents]) {
    boxes[name] = await node(page, name).boundingBox();
    assert.ok(boxes[name], `${label}: no actual card geometry for ${name}.`);
  }
  const pitch = boxes['Наталья'].y - boxes['Лидия'].y;
  assert.ok(pitch > 60, 'The established adjacent-generation witnesses have no positive pitch.');
  assert.ok(Math.abs(boxes['Олег'].y - boxes['Наталья'].y) <= 1.5, 'Oleg must retain Natalia’s co-parent generation.');
  for (const name of parents) {
    assert.ok(Math.abs(boxes[name].y - boxes['Лидия'].y) <= 1.5,
      `${label}: newly created ${name} was placed in a remote upper rank rather than the immediately preceding generation.`);
    assert.ok(Math.abs(boxes['Олег'].y - boxes[name].y - pitch) <= 1.5);
  }
  await refinementCheckpoint(page, label, true);
  report.scenarios.push({ name: label, physicalAxis: 'y', boxes, adjacentGenerationPitch: pitch });
}
async function editorRefinements(page, seeded, label, mobile) {
  await loadRoom(page, seeded);
  await refinementCheckpoint(page, `${label}-initial`);
  await refinementBiography(page, seeded, label);
  if (mobile) {
    await refinementAddRelative(page, seeded, `${label}-child-no-birth`, { person: 'Ольга', kind: 'Ребёнка',
      name: 'Дочь без даты', sex: 'female', option: 'Женский', field: 'motherId', parentId: 'root' });
  } else {
    await setTreeZoom(page, 50);
    const parents = [];
    for (const [kind, name, sex, field] of [['Отца', 'Отец Олега', 'male', 'fatherId'], ['Мать', 'Мать Олега', 'female', 'motherId']]) {
      // Toolbar search is normal user navigation, including when Oleg is clipped.
      await toolbarSearchBrowse(page, seeded, `${label}-find-oleg-${sex}`, 'Олег');
      await refinementAddRelative(page, seeded, `${label}-${sex}-parent`, { person: 'Олег', kind, name, sex, field, parentId: 'oleg' });
      parents.push(name);
      await refinementParentRanks(page, `${label}-${sex}-parent-immediate-generation`, parents);
    }
  }
  const saved = await history(page, seeded);
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), saved, 'Reload changed or lost the complete relative/fact/surname journal.');
  await refinementBiography(page, seeded, `${label}-reloaded`);
  if (mobile) {
    await toolbarSearchBrowse(page, seeded, `${label}-find-reloaded-child`, 'Дочь без даты');
    await openBiography(page);
    assert.match(await body(page), /Даты жизни не указаны/);
    await closeBiography(page);
  } else {
    await setTreeZoom(page, 50);
    await refinementParentRanks(page, `${label}-parents-immediate-generation-reloaded`, ['Отец Олега', 'Мать Олега']);
  }
  await refinementCheckpoint(page, `${label}-reload-complete`, true);
  assert.deepEqual(await history(page, seeded), saved, 'Reload inspection appended hidden writes.');
  const digest = crypto.createHash('sha256').update(JSON.stringify(saved)).digest('hex');
  await fs.writeFile(path.join(output, `${label}-complete-journal.json`), JSON.stringify(saved, null, 2));
  report.scenarios.push({ name: `${label}-complete-journal-reload`, immutableJournalEqual: true, sha256: digest,
    completeJournalLength: saved.length, publicNetworkVerified: false });
}

// Focused regression for screenshot 21: a shallow one-parent terminal child
// must not pull an otherwise compacted co-parent pair back to a remote rank.
async function collateralRankCheckpoint(page, seeded, label, portrait, parents = [], children = []) {
  await settle(page);
  const journal = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal.json`), JSON.stringify(journal, null, 2));
  const state = await branchCapture(page, seeded, label);
  const entry = { name: label, state, parents, children, physicalGenerationAxis: portrait ? 'x' : 'y' };
  report.scenarios.push(entry); // Keep raw pre/post geometry if a rank assertion fails.
  await refinementCheckpoint(page, `${label}-errors`);
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${label}: ${person.name} has no complete visible card.`);
  const axis = entry.physicalGenerationAxis;
  const coordinate = (name) => state.nodes[name][axis];
  const pitch = coordinate('Наталья') - coordinate('Лидия');
  const sameRank = (name, anchor) => assert.ok(Math.abs(coordinate(name) - coordinate(anchor)) <= 1.5,
    `${label}: ${name} is not in ${anchor}'s generation on physical ${axis}.`);
  assert.ok(pitch > 60, `${label}: established adjacent-generation anchors have no positive pitch.`);
  sameRank('Геннадий', 'Лидия');
  sameRank('Вероника', 'Наталья');
  sameRank('Олег', 'Наталья');
  sameRank('Патриарх', 'Тестовый отец');
  for (const [younger, older] of [['Лидия', 'Тестовый отец'], ['Наталья', 'Лидия'], ['Ольга', 'Наталья']]) {
    assert.ok(Math.abs(coordinate(younger) - coordinate(older) - pitch) <= 1.5,
      `${label}: deep established ${older}/${younger} branch lost one-generation pitch.`);
  }
  for (const name of parents) {
    sameRank(name, 'Лидия');
    assert.ok(Math.abs(coordinate('Олег') - coordinate(name) - pitch) <= 1.5,
      `${label}: ${name} flew to a remote upper rank after collateral-child creation.`);
  }
  for (const name of children) sameRank(name, 'Олег');
  entry.adjacentGenerationPitch = round(pitch);
  entry.rankOffsets = Object.fromEntries(seeded.people.map(({ name }) => [name, round((coordinate(name) - coordinate('Лидия')) / pitch)]));
  assert.deepEqual(await history(page, seeded), journal, `${label}: read-only geometry/error inspection wrote an operation.`);
  entry.passed = true;
  return entry;
}

async function collateralExistingMother(page, seeded, label, child, mother) {
  await toolbarSearchBrowse(page, seeded, `${label}-find-child`, child.name);
  await openBiography(page, child.name, true);
  const action = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, action);
  await action.click();
  const dialog = page.getByRole('alertdialog');
  await chooseKind(page, 'Мать');
  await dialog.getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
  assert.equal(await dialog.getByRole('checkbox', { name: 'Новый человек', exact: true }).isChecked(), false,
    'Attaching the existing mother must not create a second person.');
  const before = await history(page, seeded);
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
  await page.getByRole('button', { name: 'Отмена выбора', exact: true }).waitFor();
  await toolbarSearchBrowse(page, seeded, `${label}-existing-mother`, mother.name, true);
  assert.deepEqual(await history(page, seeded), before, 'Browsing the existing mother wrote a premature link.');
  await page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).click();
  await dialog.waitFor();
  assert.match(await dialog.ariaSnapshot(), new RegExp(mother.name));
  await refinementCheckpoint(page, `${label}-pending-confirmed-mother`, true);
  assert.deepEqual(await history(page, seeded), before, 'Picker confirmation wrote before the relative dialog Add.');
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  await until(async () => (await history(page, seeded)).length >= before.length + 1, 'The existing-mother link never became durable.');
  const expected = { type: 'setValue', personId: child.personId, field: 'motherId', value: mother.personId };
  assert.deepEqual(await appendedOperations(page, seeded, before), [expected], 'Existing-mother attachment must append exactly its one correct link.');
  await refinementCheckpoint(page, `${label}-mother-link-durable`, true);
  await closeBiography(page);
  report.scenarios.push({ name: label, actualUiExistingMother: expected, browsingAndPendingUnchanged: true });
  return expected;
}

async function collateralChildRanks(page, seeded, label, portrait) {
  await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const before = await history(page, seeded);
  assert.deepEqual(before, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)), 'The complete collateral baseline differs from its stored fixture.');
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(before, null, 2));
  await setTreeZoom(page, 100);
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, `${label}-initial-oleg`, 'Олег');
  await alignAll(page).click();
  const geometry = [await collateralRankCheckpoint(page, seeded, `${label}-baseline-deep-branch`, portrait)];
  const parents = [], children = [], created = [];
  const create = async (tag, settings, generation) => {
    await toolbarSearchBrowse(page, seeded, `${label}-${tag}-source`, settings.person);
    const person = await refinementAddRelative(page, seeded, `${label}-${tag}`, settings);
    seeded.people.push({ id: person.personId, name: person.name, sex: person.sex, generation });
    seeded.names[person.personId] = person.name;
    created.push(person);
    return person;
  };
  const father = await create('oleg-father', { person: 'Олег', kind: 'Отца', name: 'Отец Олега', sex: 'male', field: 'fatherId', parentId: 'oleg' }, 1);
  parents.push(father.name);
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-father-immediate-upper-rank`, portrait, [...parents]));
  const mother = await create('oleg-mother', { person: 'Олег', kind: 'Мать', name: 'Мать Олега', sex: 'female', field: 'motherId', parentId: 'oleg' }, 1);
  parents.push(mother.name);
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-both-parents-before-shrek`, portrait, [...parents]));
  // Source really is the new father, not Oleg; child role is father-fixed,
  // while the child's sex is explicitly male and DOB deliberately remains blank.
  const shrek = await create('father-child-shrek', { person: father.name, kind: 'Ребёнка', name: 'Шрек', sex: 'male', option: 'Мужской',
    field: 'fatherId', parentId: father.personId }, 2);
  children.push(shrek.name);
  const oneParentJournal = await history(page, seeded);
  const childFields = oneParentJournal.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
    .filter((operation) => operation.type === 'setValue' && operation.personId === shrek.personId);
  assert.deepEqual(childFields, [{ type: 'setValue', personId: shrek.personId, field: 'fatherId', value: father.personId }],
    'The decisive first Shrek checkpoint must have exactly one father and no implicit mother or DOB.');
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-shrek-one-father-parents-still-adjacent-rank`, portrait, [...parents], [...children]));
  const motherLink = await collateralExistingMother(page, seeded, `${label}-shrek-existing-mother`, shrek, mother);
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-shrek-both-parents-rank-stable`, portrait, [...parents], [...children]));
  const otherChild = await create('mother-one-parent-child', { person: mother.name, kind: 'Ребёнка', name: 'Ребёнок матери', sex: 'unknown',
    field: 'motherId', parentId: mother.personId }, 2);
  children.push(otherChild.name);
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-second-one-parent-child-rank-stable`, portrait, [...parents], [...children]));
  const after = await history(page, seeded);
  const expectedOperations = [...created, ...[
    ['oleg', 'fatherId', father.personId], ['oleg', 'motherId', mother.personId],
    [shrek.personId, 'fatherId', father.personId], [otherChild.personId, 'motherId', mother.personId],
  ].map(([personId, field, value]) => ({ type: 'setValue', personId, field, value })), motherLink];
  const canonical = (operations) => operations.map((operation) => JSON.stringify(Object.fromEntries(Object.entries(operation).sort(([a], [b]) => a.localeCompare(b))))).sort();
  assert.deepEqual(canonical(await appendedOperations(page, seeded, before)), canonical(expectedOperations),
    'The complete journal has writes other than four creations, their four links, and the explicit Shrek mother link.');
  assert.equal(after.length, before.length + 9);
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(after, null, 2));
  const trusted = await page.evaluate(() => ({ mouseUps: window.__canvasPrimaryEvents.filter((event) => event.type === 'mouseup').length,
    allPrimaryTrusted: window.__canvasPrimaryEvents.every((event) => event.trusted) }));
  assert.ok(trusted.mouseUps >= 30 && trusted.allPrimaryTrusted, 'Collateral creations did not use trusted real browser input.');
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(reloaded, null, 2));
  assert.deepEqual(reloaded, after, 'Reload changed or lost a complete collateral-child journal record.');
  await setTreeZoom(page, 100);
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, `${label}-reloaded-shrek`, 'Шрек');
  await alignAll(page).click();
  geometry.push(await collateralRankCheckpoint(page, seeded, `${label}-reloaded-all-ranks`, portrait, [...parents], [...children]));
  assert.deepEqual(await history(page, seeded), after, 'Reload navigation/geometry checks appended hidden writes.');
  const hash = (records) => crypto.createHash('sha256').update(JSON.stringify(records)).digest('hex');
  report.scenarios.push({ name: `${label}-collateral-child-ranks-summary`, geometry: geometry.map((entry) => entry.name), trusted,
    uiCreated: created, exactNewOperations: expectedOperations, initialShrekFatherOnly: true, secondChildMotherOnly: true,
    completeJournal: { beforeRecords: before.length, afterRecords: after.length, expectedAppends: 9,
      beforeSha256: hash(before), afterSha256: hash(after), reloadSha256: hash(reloaded) },
    allPreviousRecordsImmutable: true, reloadUnchanged: true, networkIsolated: true,
    limitation: 'Finite both-line 100% local actual-UI rank regression; not cross-mode ordering, arbitrary graphs, physical phones, painted-route or network synchronization coverage.' });
  console.log(`PASS: ${label} actual Oleg parents, father-only Shrek, existing mother and second mother-only child retain immediate ranks; exact journal append/reload equality.`);
}

async function parentCreation(page, seeded) {
  await page.setViewportSize({ width: 1440, height: 900 });
  await loadRoom(page, seeded);
  await page.getByRole('button', { name: 'Биография', exact: true }).click();
  await page.getByRole('button', { name: 'Изменить', exact: true }).click();
  for (const [kind, expected, sex, field, name] of [
    ['Отца', 'Мужской', 'male', 'fatherId', 'Отец canvas'],
    ['Мать', 'Женский', 'female', 'motherId', 'Мать canvas'],
  ]) {
    await page.getByRole('button', { name: 'Добавить родственника', exact: true }).click();
    await page.getByRole('alertdialog').waitFor();
    await page.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
    if (kind === 'Отца') {
      await assertFixedSex(page, 'Мужской');
      // Child creation is the deliberate exception: every sex must be editable.
      await chooseKind(page, 'Ребёнка');
      const picker = page.getByRole('alertdialog').getByRole('button', { name: /^Пол(?:\s|$)/ });
      await picker.click();
      for (const option of ['Пол не указан', 'Мужской', 'Женский']) {
        await page.getByRole('menuitem', { name: option, exact: true }).waitFor();
      }
      assert.equal(await page.getByRole('menuitem').count(), 3);
      await page.getByRole('menuitem', { name: 'Женский', exact: true }).click();
      await chooseKind(page, 'Отца');
    } else {
      await chooseKind(page, kind);
    }
    await assertFixedSex(page, expected);
    await type(page, page.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
    await page.screenshot({ path: path.join(output, `parent-role-${sex}-locked.png`), animations: 'disabled' });
    await page.getByRole('button', { name: 'Добавить', exact: true }).click();
    await page.getByRole('alertdialog').waitFor({ state: 'hidden' });
    await until(async () => (await history(page, seeded)).some((record) => record.kind === 'tree' &&
      JSON.parse(record.text).type === 'createPerson' && JSON.parse(record.text).name === name),
    `UI-created ${kind} was not durably appended.`);
    const records = await history(page, seeded);
    const operations = records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text));
    const created = operations.filter((entry) => entry.type === 'createPerson' && entry.name === name);
    assert.equal(created.length, 1, 'Parent submission created duplicate people.');
    assert.equal(created[0].sex, sex, 'The durable parent sex contradicts the chosen role.');
    assert.ok(operations.some((entry) => entry.type === 'setValue' && entry.personId === 'root' &&
      entry.field === field && entry.value === created[0].personId), 'The UI linked the new person in the wrong parent role.');
    report.scenarios.push({ name: `parent-creation-${sex}-role-fixed`, created: created[0], linkedField: field });
  }
  assert.doesNotMatch(await body(page), /Не сохранено:|Не удалось добавить родственника/);
  await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).click();
  await loadRoom(page, seeded);
  await page.getByRole('button', { name: 'Биография', exact: true }).click();
  await until(async () => {
    const semantics = await body(page);
    return semantics.includes('Отец canvas') && semantics.includes('Мать canvas');
  }, 'Persisted parent links were not projected by the production app after reload.');
  await page.screenshot({ path: path.join(output, 'parent-roles-after-reload.png'), animations: 'disabled' });
  report.scenarios.push({ name: 'ui-created-parent-links-survive-production-reload' });
}

// One personal birth-surname input plus decline; historical family records are
// read-only fallback. Flutter keys are not DOM selectors: use public semantics.
const surnameField = (page) => page.getByRole('textbox', { name: /^Фамилия(?:\s|$)/ });
const surnameDecline = (page) => page.getByRole('checkbox', { name: 'склонять', exact: true });
const surnameIndividual = (page) => page.getByRole('checkbox', { name: 'отдельная', exact: true });
const treeSearch = (page) => page.getByRole('textbox', { name: 'Поиск по дереву', exact: true });
const searchOption = (page, fullName) => page.getByRole('button', { name: new RegExp(`^${fullName},`) });

async function biographyField(page, expected) {
  const field = surnameField(page);
  await revealBiography(page, field);
  await focusInput(page, field, expected);
  return field;
}

async function surnameControls(page, { text, decline }, previousInput) {
  const field = await biographyField(page, text);
  assert.equal(await field.count(), 1, 'There must be exactly one personal surname input.');
  assert.equal(await surnameDecline(page).count(), 1, 'There must be one decline checkbox.');
  assert.equal(await surnameDecline(page).isChecked(), decline);
  assert.equal(await surnameIndividual(page).count(), 0, 'Removed separate/shared scope toggle is still exposed.');
  assert.equal(await page.getByRole('switch', { name: /фамилия|отдельная/i }).count(), 0);
  assert.doesNotMatch(await body(page), /до замужества|Фамилия человека|Фамилия блока|Указана для блока|отдельная/);
  if (previousInput) assert.ok(await field.evaluate((element, previous) => element === previous, previousInput),
    'A personal surname refresh replaced the one existing input.');
  const boxes = { field: await field.boundingBox(), decline: await surnameDecline(page).boundingBox() };
  assert.ok(Object.values(boxes).every(Boolean), 'Surname controls have no actual browser geometry.');
  const width = page.viewportSize().width;
  assert.ok(Object.values(boxes).every((box) => box.x >= 0 && box.x + box.width <= width + 1),
    `Surname controls overflow the viewport: ${JSON.stringify(boxes)}`);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), width,
    'The surname editor caused horizontal page overflow.');
  return { input: previousInput || await field.elementHandle(), boxes };
}

async function personalSurnameWrite(page, seeded, label, personId, text, decline, { toggle = false, clearButton = false } = {}) {
  const before = await history(page, seeded);
  if (toggle) {
    await revealBiography(page, surnameDecline(page));
    await surnameDecline(page).click();
  } else if (clearButton) {
    const clear = page.getByRole('button', { name: 'Убрать фамилию', exact: true });
    await revealBiography(page, clear);
    await clear.click();
  } else await type(page, surnameField(page), text ?? '');
  await until(async () => (await history(page, seeded)).length > before.length, 'Personal surname did not persist.');
  await settle(page);
  const operations = await appendedOperations(page, seeded, before);
  const expected = { type: 'setSurname', personId, scope: 'individual', familyKey: null, text, decline: text ? decline : false };
  assert.ok(operations.length && operations.every((op) => op.type === 'setSurname' && op.personId === personId &&
    op.scope === 'individual' && op.familyKey === null && op.decline === expected.decline),
  `${label}: surname write escaped the personal register: ${JSON.stringify(operations)}`);
  if (toggle || text === null) assert.deepEqual(operations, [expected], `${label}: toggle/clear must append exactly one operation.`);
  else assert.ok(operations.some((op) => op.text === text), `${label}: final typed personal value was not saved.`);
  await surnameControls(page, { text: text ?? '', decline: text ? decline : true });
  await refinementCheckpoint(page, label, true);
  return operations;
}

async function assertReadSurname(page, name, fullName) {
  const before = await body(page);
  assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0,
    `Close the previous biography before inspecting ${name}: ${before}`);
  await select(page, name);
  await assertSelected(page, name);
  await openBiography(page);
  // Flutter exports readonly SelectableText as an empty disabled textbox on
  // mobile. Selection is verified on the node; retain actual biography pixels
  // rather than depending on the removed selected-name toolbar caption.
  if (page.viewportSize().width >= 700) await page.getByText(fullName, { exact: true }).waitFor();
  else await page.screenshot({ path: path.join(output, `surname-readonly-${page.viewportSize().width}-${name}.png`), animations: 'disabled' });
  assert.doesNotMatch(await body(page), /до замужества|Сидоров/,
    'Readonly biography exposed a removed legacy maiden surname/caption.');
  assert.equal(await surnameField(page).count(), 0, 'Readonly biography exposed an editable surname.');
  await closeBiography(page);
}

async function surnameFooter(page, text, memberNames, label) {
  const footer = page.getByText(text, { exact: true });
  await footer.waitFor();
  assert.equal(await footer.count(), 1, 'A shared surname must be one block footer, not repeated on every node.');
  const bounds = await footer.boundingBox();
  const members = await Promise.all(memberNames.map((name) => node(page, name).boundingBox()));
  assert.ok(members.every(Boolean));
  const lastBottom = Math.max(...members.map((box) => box.y + box.height));
  // The wash ends at bodyEnd+6. The surname starts at bodyEnd+8 or later
  // (its text is centered in a 20px footer), never inside a taller block wash.
  assert.ok(bounds.y >= lastBottom + 7 && bounds.y - lastBottom < 16,
    `Surname is not immediately below its unchanged block background: ${JSON.stringify({ bounds, members })}`);
  assert.equal(await footer.getAttribute('role'), null, 'The surname footer must remain ordinary text, not a control.');
  const png = await page.screenshot({ path: path.join(output, `${label}-footer.png`), animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async ({ png, box }) => {
    const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const left = Math.max(0, Math.floor(box.x)), top = Math.max(0, Math.floor(box.y));
    const width = Math.min(Math.ceil(box.width), image.width - left), height = Math.min(Math.ceil(box.height), image.height - top);
    const data = context.getImageData(left, top, width, height).data;
    let darkest = 255, visibleInk = 0;
    for (let index = 0; index < data.length; index += 4) {
      const luminance = (data[index] + data[index + 1] + data[index + 2]) / 3;
      darkest = Math.min(darkest, luminance);
      if (luminance < 200) visibleInk++;
    }
    return { darkest, visibleInk };
  }, { png: png.toString('base64'), box: bounds });
  assert.ok(pixels.darkest > 70 && pixels.darkest < 195 && pixels.visibleInk > 8,
    `Footer must be visibly painted at low opacity, not full-strength node text: ${JSON.stringify(pixels)}`);
  return { text, bounds, members, pixels };
}

async function singletonSurnameBlocks(page, seeded, label) {
  await settle(page);
  const before = await history(page, seeded);
  const boxes = {};
  for (const name of ['Павел', 'Мария']) {
    boxes[name] = await node(page, name).boundingBox();
    assert.ok(boxes[name] && Math.abs(boxes[name].width - 108) <= 1 && Math.abs(boxes[name].height - 108) <= 1,
      `The singleton comparison needs an unclipped 108px node: ${name} ${JSON.stringify(boxes[name])}`);
  }
  const footer = await page.getByText('Иванов', { exact: true }).boundingBox();
  assert.ok(footer && footer.y >= boxes['Павел'].y + boxes['Павел'].height + 7,
    'The singleton surname footer overlaps its block wash.');
  const png = await page.screenshot({ path: path.join(output, `${label}-equal-singleton-washes-footer-outside.png`),
    animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async ({ png, boxes }) => {
    const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    return Object.entries(boxes).map(([name, box]) => ({ name,
      // Sample the outer side of each parent block, away from the genuine
      // inward union connector and the centered surname text.
      columns: (name === 'Павел' ? [84, 88] : [20, 24]).map((offset) => {
        const x = box.x + offset;
        const surface = pixel(x, box.y - 10);
        const wash = pixel(x, box.y - 3);
        const top = Array.from({ length: 10 }, (_, index) => ({ offset: index - 10,
          pixel: pixel(x, box.y + index - 10) }));
        const bottom = Array.from({ length: 30 }, (_, index) => ({ offset: index + 1,
          pixel: pixel(x, box.y + box.height + index + 1) }));
        return { x, surface, wash, top, bottom };
      }) }));
  }, { png: png.toString('base64'), boxes });
  const edges = [];
  for (const singleton of pixels) {
    const measured = singleton.columns.map((column) => {
      const distance = (a, b) => Math.max(...a.map((channel, index) => Math.abs(channel - b[index])));
      assert.ok(distance(column.surface, column.wash) >= 4,
        `No visible singleton block wash at ${singleton.name}: ${JSON.stringify(column)}`);
      const painted = (sample) => distance(sample.pixel, column.wash) <= 2;
      const top = column.top.filter(painted).map((sample) => sample.offset);
      const bottom = column.bottom.filter(painted).map((sample) => sample.offset);
      assert.ok(top.length > 0 && Math.min(...top) >= -7 && Math.min(...top) <= -5 &&
        bottom.includes(3) && Math.max(...bottom) >= 4 && Math.max(...bottom) <= 6,
      `A surname changed singleton background height instead of sitting outside it: ${singleton.name} ${JSON.stringify(column)}`);
      assert.ok(column.bottom.filter((sample) => sample.offset >= 9).every((sample) =>
        distance(sample.pixel, column.surface) <= 2),
      `Block wash extends behind/below the footer: ${singleton.name} ${JSON.stringify(column)}`);
      return { top: Math.min(...top), bottom: Math.max(...bottom) };
    });
    edges.push({ name: singleton.name, measured });
  }
  for (let index = 0; index < 2; index++) {
    assert.ok(Math.abs(edges[0].measured[index].top - edges[1].measured[index].top) <= 1 &&
      Math.abs(edges[0].measured[index].bottom - edges[1].measured[index].bottom) <= 1,
    'Comparable singleton blocks with/without a surname have different painted background extents.');
  }
  assert.deepEqual(await history(page, seeded), before, 'Inspecting singleton block geometry appended an edit.');
  report.scenarios.push({ name: `${label}-surname-does-not-enlarge-singleton-block`, boxes, footer,
    expectedWashHeight: 120, footerOutsideWash: true, edges, pixels, historyUnchanged: true });
}

async function surnameSearch(page, seeded, label) {
  const before = await history(page, seeded);
  await type(page, treeSearch(page), 'Иванов');
  const options = page.getByRole('button', { name: /^(?:Павел|Борис|Анна|Вера) Иванов(?:а)?,/ });
  await until(async () => await options.count() === 4, 'Surname search did not include inherited female/male names.');
  const labels = await Promise.all(Array.from({ length: 4 }, async (_, index) => {
    const snapshot = await options.nth(index).ariaSnapshot();
    return JSON.parse(snapshot.match(/^- button (".*")/m)[1]);
  }));
  assert.deepEqual(labels, ['Вера Иванова, ?–?', 'Павел Иванов, 1950–н.в.',
    'Борис Иванов, 1979–н.в.', 'Анна Иванова, 1985–н.в.'], 'Search must put unknown birth first, then ascending date/name/ID.');
  assert.doesNotMatch(await body(page), /до замужества|Сидоров/, 'Search still exposed a legacy maiden caption.');
  await page.screenshot({ path: path.join(output, `${label}-surname-search-unknown-first.png`), animations: 'disabled' });
  await searchOption(page, 'Борис Иванов').click();
  await settle(page);
  await assertSelected(page, 'Борис');
  assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0,
    'Main-tree search opened biography rather than browsing.');
  await type(page, treeSearch(page), 'Сидорова 1985');
  await page.getByText('Ничего не найдено', { exact: true }).waitFor();
  assert.equal(await searchOption(page, 'Анна Иванова').count(), 0, 'A legacy maiden surname still matched search.');
  await page.screenshot({ path: path.join(output, `${label}-legacy-maiden-not-searchable.png`), animations: 'disabled' });
  await type(page, treeSearch(page), 'Анна Иванова 1985');
  const canonical = searchOption(page, 'Анна Иванова');
  await canonical.waitFor();
  assert.equal(JSON.parse((await canonical.ariaSnapshot()).match(/^- button (".*")/m)[1]),
    'Анна Иванова, 1985–н.в.', 'Search must expose only the canonical full name and years.');
  await canonical.click();
  await settle(page);
  assert.deepEqual(await history(page, seeded), before, 'Search/browsing appended an edit.');
  await select(page, 'Анна');
  report.scenarios.push({ name: `${label}-canonical-surname-search-unknown-first-date-name-id`, labels,
    canonicalNameAndYearMatch: true, legacyMaidenIgnored: true, historyUnchanged: true });
}

async function surnamePicker(page, seeded, label) {
  // Add deliberately does not replace a parent. Remove the old edge through its
  // own production action before exercising a pending, explicitly confirmed Add.
  await openBiography(page, 'Анна', true);
  const occupied = await history(page, seeded);
  await unlinkChip(page, 'Павел Иванов');
  await until(async () => (await history(page, seeded)).length > occupied.length, 'The old father link was not removed before testing Add.');
  assert.deepEqual(await appendedOperations(page, seeded, occupied),
    [{ type: 'setValue', personId: 'root', field: 'fatherId', value: null }]);
  await closeBiography(page);
  const before = await history(page, seeded);
  const dialog = page.getByRole('alertdialog');
  const cancel = page.getByRole('button', { name: 'Отмена выбора', exact: true });
  const confirm = () => page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ });
  await openBiography(page, 'Анна', true);
  const addRelative = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, addRelative);
  await addRelative.click();
  const openPicker = async () => {
    await dialog.getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
    const choose = dialog.getByRole('button', { name: 'Выбрать', exact: true });
    await choose.waitFor();
    assert.equal(await choose.count(), 1);
    assert.equal(await dialog.getByRole('button', { name: /^Человек из дерева/ }).count(), 0);
    await choose.click();
    await cancel.waitFor();
    await treeSearch(page).waitFor();
    await settle(page);
    assert.equal(await page.getByRole('button', { name: 'Биография', exact: true }).count(), 0);
  };
  const browseValid = async () => {
    await type(page, treeSearch(page), 'Борис Орлов');
    const suggestion = searchOption(page, 'Борис Орлов');
    await suggestion.waitFor();
    await suggestion.click();
    await settle(page);
    assert.equal(await cancel.count(), 1, 'Picker search returned instead of just browsing.');
    assert.equal(await dialog.count(), 0);
    assert.equal(await confirm().isEnabled(), true, 'Valid browsed person did not enable the floating check.');
    assert.deepEqual(await history(page, seeded), before);
  };
  await openPicker();
  await select(page, 'Анна');
  assert.equal(await confirm().isDisabled(), true, 'Self focus must disable the floating check.');
  await select(page, 'Вера');
  assert.equal(await confirm().isDisabled(), true, 'A wrong-sex focus must remain browsable but unconfirmable.');
  assert.equal(await page.getByText('Этот человек не подходит для выбранной связи.', { exact: true }).count(), 0,
    'Invalid node browsing displayed an unwanted Snackbar.');
  await page.screenshot({ path: path.join(output, `${label}-picker-invalid-disabled-check.png`), animations: 'disabled' });
  await browseValid();
  await page.screenshot({ path: path.join(output, `${label}-picker-browsed-not-confirmed.png`), animations: 'disabled' });
  await cancel.click();
  await dialog.waitFor();
  assert.doesNotMatch(await dialog.ariaSnapshot(), /Борис Орлов/, 'Cancelled browsing filled the pending summary.');
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  assert.deepEqual(await history(page, seeded), before, 'Cancelled picker/dialog wrote history.');
  await closeBiography(page);

  await openBiography(page, 'Анна', true);
  await revealBiography(page, addRelative);
  await addRelative.click();
  await openPicker();
  await browseValid();
  await confirm().click();
  await dialog.waitFor();
  assert.match(await dialog.ariaSnapshot(), /Борис Орлов[\s\S]*1979/,
    'The floating check did not return the chosen id to the pending summary.');
  assert.deepEqual(await history(page, seeded), before, 'Picker confirmation itself wrote an edge.');
  const pending = await dialog.ariaSnapshot();
  await openPicker();
  await select(page, 'Вера');
  await cancel.click();
  await dialog.waitFor();
  assert.equal(await dialog.ariaSnapshot(), pending, 'Cancelling a later browse replaced the pending person.');
  await page.screenshot({ path: path.join(output, `${label}-picker-confirmed-pending-summary.png`), animations: 'disabled' });
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  await until(async () => (await history(page, seeded)).length > before.length, 'Dialog Add did not persist the selected edge.');
  const operations = await appendedOperations(page, seeded, before);
  assert.deepEqual(operations, [{ type: 'setValue', personId: 'root', field: 'fatherId', value: 'brother' }]);
  await closeBiography(page);
  report.scenarios.push({ name: `${label}-surname-picker-search-browses-explicit-check-and-dialog-add`,
    invalidFocusDisabledWithoutSnackbar: true, cancelledHistoryUnchanged: true,
    checkOnlyFillsSummary: true, onlyDialogAddWrites: operations });
}

async function personalNames(page, seeded, label, expected) {
  const before = await history(page, seeded);
  const labels = [];
  for (const [name, fullName] of expected) {
    await type(page, treeSearch(page), fullName);
    const result = searchOption(page, fullName);
    await result.waitFor();
    labels.push(await result.getAttribute('aria-label') || await result.innerText());
    await result.click();
    await settle(page);
    await assertSelected(page, name); // Cards retain their given-name-only label.
  }
  await refinementCheckpoint(page, label, true);
  assert.deepEqual(await history(page, seeded), before, 'Personal full-name searches wrote hidden records.');
  report.scenarios.push({ name: label, expectedFullNames: expected, actualSearchLabels: labels, journalUnchanged: true });
}

async function personalSelectedPixels(page, seeded, label) {
  const before = await history(page, seeded);
  const root = seeded.names.root, brother = seeded.names.brother;
  await select(page, brother);
  const plainBox = await node(page, root).boundingBox();
  assert.ok(plainBox && plainBox.width >= 107, 'Selected-fill oracle requires an exposed 100% card.');
  await page.mouse.move(1, 1);
  await sleep(350);
  const plain = await page.screenshot({ clip: plainBox, animations: 'disabled', scale: 'css' });
  await select(page, root);
  const box = await node(page, root).boundingBox();
  await page.mouse.move(1, 1);
  await sleep(350);
  const selected = await page.screenshot({ path: path.join(output, `${label}-selected-half-alpha-name-opaque.png`),
    clip: box, animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async ({ a, b }) => {
    const decode = async (data) => {
      const image = new Image(); image.src = `data:image/png;base64,${data}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      return (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    };
    const old = await decode(a), now = await decode(b);
    // The default light scheme's lowest surface is white. Observe it on the
    // actual name backing too; do not mistake opaque whole-card white for .5.
    let opaque = [0, 0, 0];
    for (let y = 76; y <= 96; y++) for (let x = 34; x <= 74; x++) {
      const sample = now(x, y);
      if (sample.reduce((sum, value) => sum + value, 0) > opaque.reduce((sum, value) => sum + value, 0)) opaque = sample;
    }
    const samples = [[4, 49], [4, 55], [103, 49], [103, 55], [54, 4]].map(([x, y]) => {
      const background = old(x, y), actual = now(x, y);
      const expected = background.map((channel, i) => (channel + opaque[i]) / 2);
      return { x, y, background, actual, expected,
        error: Math.max(...actual.map((channel, i) => Math.abs(channel - expected[i]))),
        contrast: Math.max(...background.map((channel, i) => Math.abs(channel - opaque[i]))) };
    });
    return { opaque, samples };
  }, { a: plain.toString('base64'), b: selected.toString('base64') });
  report.scenarios.push({ name: `${label}-selected-fill-pixels`, box, pixels, alpha: .5 });
  assert.ok(pixels.opaque.every((channel) => channel >= 252), 'Selected name lost its opaque lowest-surface backing.');
  assert.ok(pixels.samples.filter((sample) => sample.contrast >= 12 && sample.error <= 4).length >= 3,
    `Selected body must be .5 lowest-surface over the actual block, not opaque/clear: ${JSON.stringify(pixels)}`);
  await assertSelected(page, root);
  assert.deepEqual(await history(page, seeded), before, 'Selected-fill checks wrote history.');
}

async function personalFamilyControls(page, seeded, label) {
  // A phone intentionally shows only part of the generations. Search actually
  // selects/reveals the person before opening biography; do not click an
  // offscreen Flutter semantic rectangle left behind by child-focused browsing.
  const open = async (name) => {
    await type(page, treeSearch(page), name);
    const option = page.getByRole('button', { name: new RegExp(`^${name}(?: |,)`) });
    await option.waitFor();
    assert.equal(await option.count(), 1, `Personal fixture search is ambiguous for ${name}.`);
    await option.click();
    await settle(page);
    await assertSelected(page, name);
    await openBiography(page, undefined, true);
  };
  await loadRoom(page, seeded);
  const initial = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(initial, null, 2));
  await personalSelectedPixels(page, seeded, label);
  const names = (own, other, ownFemale = `${own}а`) => [
    ['Алексей', `Алексей ${own}`], ['Борис', `Борис ${other}`],
    ['Дочь Алексея', `Дочь Алексея ${ownFemale}`], ['Сын Бориса', `Сын Бориса ${other}`],
  ];
  await personalNames(page, seeded, `${label}-legacy-baseline`, names('Старов', 'Старов'));
  await open('Алексей');
  await surnameControls(page, { text: 'Старов', decline: true });
  assert.deepEqual(await history(page, seeded), initial, 'Opening legacy personal controls migrated history.');
  await personalSurnameWrite(page, seeded, `${label}-own-personal`, 'root', 'Орлов', true);
  await closeBiography(page);
  await personalNames(page, seeded, `${label}-own-descendant-only`, names('Орлов', 'Старов'));
  await open('Алексей');
  await surnameControls(page, { text: 'Орлов', decline: true });
  await personalSurnameWrite(page, seeded, `${label}-decline-false`, 'root', 'Орлов', false, { toggle: true });
  await closeBiography(page);
  await personalNames(page, seeded, `${label}-literal-female-no-suffix`, names('Орлов', 'Старов', 'Орлов'));
  await open('Алексей');
  await surnameControls(page, { text: 'Орлов', decline: false });
  await personalSurnameWrite(page, seeded, `${label}-decline-true`, 'root', 'Орлов', true, { toggle: true });
  await personalSurnameWrite(page, seeded, `${label}-clear-suppresses-old-shared`, 'root', null, false, { clearButton: true });
  assert.match(await body(page), /Наследуется от отца: Павел Иванов/);
  await closeBiography(page);
  await personalNames(page, seeded, `${label}-clear-inherits-father`, names('Иванов', 'Старов'));
  await open('Павел');
  await surnameControls(page, { text: 'Иванов', decline: true });
  await personalSurnameWrite(page, seeded, `${label}-father-personal`, 'father', 'Петров', true);
  await closeBiography(page);
  await personalNames(page, seeded, `${label}-father-propagates-not-explicit-sibling`, names('Петров', 'Старов'));
  await open('Борис');
  await surnameControls(page, { text: 'Старов', decline: true });
  await personalSurnameWrite(page, seeded, `${label}-other-clear`, 'brother', null, false);
  assert.match(await body(page), /Наследуется от отца: Павел Петров/);
  await closeBiography(page);
  await personalNames(page, seeded, `${label}-both-inherit-after-own-clears`, names('Петров', 'Петров'));

  // Siblings remain navigable chips, without X on full OR half siblings.
  // Direct parent/child X controls remain genuine working commands.
  await open('Алексей');
  const beforeLinks = await history(page, seeded);
  for (const name of ['Борис Петров', 'Неполный брат']) {
    const chip = page.getByRole('checkbox', { name, exact: true });
    await revealBiography(page, chip);
    assert.equal(await chip.count(), 1);
    assert.equal(await chip.getByRole('button', { name: /удалить связь/ }).count(), 0, `Sibling X still present: ${name}`);
  }
  for (const name of ['Павел Петров', 'Дочь Алексея Петрова']) {
    const chip = page.getByRole('checkbox', { name, exact: true });
    await revealBiography(page, chip);
    assert.equal(await chip.getByRole('button', { name: 'удалить связь', exact: true }).count(), 1,
      `Parent/child unlink was removed with siblings: ${name}`);
  }
  await refinementCheckpoint(page, `${label}-siblings-no-x-child-x-retained`, true);
  assert.deepEqual(await history(page, seeded), beforeLinks, 'Control inspection wrote history.');
  await unlinkChip(page, 'Павел Петров');
  await until(async () => (await history(page, seeded)).length === beforeLinks.length + 1, 'Parent unlink did not persist.');
  assert.deepEqual(await appendedOperations(page, seeded, beforeLinks),
    [{ type: 'setValue', personId: 'root', field: 'fatherId', value: null }]);
  const childBefore = await history(page, seeded);
  await unlinkChip(page, 'Дочь Алексея'); // Root's cleared surname now has no father to inherit from.
  await until(async () => (await history(page, seeded)).length === childBefore.length + 1, 'Child unlink did not persist.');
  assert.deepEqual(await appendedOperations(page, seeded, childBefore),
    [{ type: 'setValue', personId: 'own-child', field: 'fatherId', value: null }]);
  await closeBiography(page);
  const final = await history(page, seeded);
  const edits = await appendedOperations(page, seeded, initial);
  const surnameEdits = edits.filter((op) => op.type === 'setSurname');
  assert.ok(surnameEdits.length && surnameEdits.every((op) => op.scope === 'individual' && op.familyKey === null &&
    ['root', 'father', 'brother'].includes(op.personId)), 'Local flow wrote shared/maiden/descendant surname records.');
  assert.equal(edits.length, surnameEdits.length + 2, 'Unexpected side writes besides the two direct unlinks.');
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(final, null, 2));
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded);
  assert.deepEqual(reloaded, final, 'Complete personal/control journal changed after reload.');
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(reloaded, null, 2));
  await personalNames(page, seeded, `${label}-reload-clears-and-inheritance`, [
    ['Алексей', 'Алексей'], ['Дочь Алексея', 'Дочь Алексея'], ['Борис', 'Борис Петров'], ['Сын Бориса', 'Сын Бориса Петров'],
  ]);
  await open('Алексей');
  await surnameControls(page, { text: '', decline: true });
  assert.equal(await page.getByRole('checkbox', { name: 'Павел Петров', exact: true }).count(), 0);
  await refinementCheckpoint(page, `${label}-controls-reloaded`, true);
  await closeBiography(page);
  assert.deepEqual(await history(page, seeded), final, 'Reload/view interactions wrote hidden records.');
  const hash = (records) => crypto.createHash('sha256').update(JSON.stringify(records)).digest('hex');
  report.scenarios.push({ name: `${label}-personal-family-controls-summary`, before: initial.length, after: final.length,
    surnameEdits, directUnlinks: 2, immutableBaseline: true, journalHashes: { before: hash(initial), after: hash(final), reloaded: hash(reloaded) },
    personalOnly: true, oldFamilyFallbackSuppressedByNull: true, ownDescendantsOnly: true,
    fullAndHalfSiblingUnlinkAbsent: true, parentAndChildUnlinkPersisted: true, completeReload: true });
  console.log(`PASS: ${label} personal surnames/descendant isolation/null father inheritance, .5 selection fill/opaque name, sibling X absent/direct X retained, full reload.`);
}

async function guestBadgePixels(page, seeded, label) {
  const journal = await history(page, seeded);
  await page.getByRole('button', { name: /^Участники:/ }).click();
  try {
    // Flutter can concatenate the visible name with the outer tile label.
    // Match the complete public role/status suffix, not a fabricated DOM key.
    const guest = page.getByRole('button', { name: /Гость проверки, офлайн, гость$/ });
    await guest.waitFor();
    const box = await guest.boundingBox();
    assert.ok(box && box.width >= 80 && box.height >= 65, 'Real participant guest tile has no usable rectangle.');
    const png = await page.screenshot({ path: path.join(output, `${label}-guest-brown-eye-tile.png`),
      clip: box, animations: 'disabled', scale: 'css' });
    await page.screenshot({ path: path.join(output, `${label}-participants-brown-guest.png`), animations: 'disabled', scale: 'css' });
    const pixels = await page.evaluate(async (data) => {
      const image = new Image(); image.src = `data:image/png;base64,${data}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d', { willReadFrequently: true }); context.drawImage(image, 0, 0);
      const pixel = (x, y) => [...context.getImageData(x, y, 1, 1).data].slice(0, 3);
      const brown = [], whites = [];
      for (let y = 0; y < Math.min(64, image.height); y++) for (let x = 0; x < image.width; x++) {
        const rgb = pixel(x, y);
        if (rgb.every((channel, i) => Math.abs(channel - [135, 88, 38][i]) <= 5)) brown.push({ x, y });
        if (rgb.every((channel) => channel >= 248)) whites.push({ x, y });
      }
      const bounds = brown.length ? { x: Math.min(...brown.map((p) => p.x)), y: Math.min(...brown.map((p) => p.y)),
        right: Math.max(...brown.map((p) => p.x)), bottom: Math.max(...brown.map((p) => p.y)) } : null;
      return { brownPixels: brown.length, bounds, whiteEyePixels: bounds ? whites.filter((p) =>
        p.x >= bounds.x && p.x <= bounds.right && p.y >= bounds.y && p.y <= bounds.bottom).length : 0 };
    }, png.toString('base64'));
    report.scenarios.push({ name: `${label}-brown-guest-eye`, tile: box, pixels, expectedRgb: [135, 88, 38] });
    assert.ok(pixels.brownPixels >= 160 && pixels.whiteEyePixels >= 12 && pixels.bounds &&
      pixels.bounds.right - pixels.bounds.x >= 17 && pixels.bounds.right - pixels.bounds.x <= 21 &&
      pixels.bounds.bottom - pixels.bounds.y >= 17 && pixels.bounds.bottom - pixels.bounds.y <= 21,
    `Guest badge must be the 20px brown disk with white eye, not green/avatar-only paint: ${JSON.stringify(pixels)}`);
    await refinementCheckpoint(page, `${label}-guest-badge-errors`);
  } finally { await page.getByRole('button', { name: 'Закрыть', exact: true }).click(); }
  assert.deepEqual(await history(page, seeded), journal, 'Viewing the real guest badge wrote room history.');
}

async function strictDisplaySearch(page, seeded, label) {
  const before = await history(page, seeded);
  const expected = fixturePeopleByDisplay(seeded).filter((person) => person.name.trim().toLowerCase().startsWith('сорт'));
  assert.deepEqual(expected.map((person) => person.id), ['z-null-alpha', 'a-null-yo', 'z-null-e', 'a-null-zeta',
    'dated-older', 'z-equal-alpha', 'a-equal-zeta'], 'Fixture must distinguish null-first, date, normalized name and final ID ties.');
  await type(page, treeSearch(page), 'Сорт');
  const results = page.getByRole('button', { name: /^\s*[Сс]орт .*?,/ });
  await until(async () => await results.count() === expected.length, 'Strict-order search did not expose the complete finite witness set.');
  const labels = await results.evaluateAll((elements) => elements.map((element) => element.getAttribute('aria-label') || element.textContent));
  const actualNames = labels.map((text) => text.slice(0, text.indexOf(',')));
  assert.deepEqual(actualNames.map((text) => text.trim()), expected.map((person) => person.name.trim()),
    `${label}: search order differs from unknown-first/date/trim-lower-ё=name/ID.`);
  await refinementCheckpoint(page, `${label}-unknown-date-name-id-search`, true);
  await results.first().click();
  await settle(page);
  assert.deepEqual(await history(page, seeded), before, 'Strict ordering/search rewrote stored history.');
  report.scenarios.push({ name: `${label}-strict-display-search`, expected, labels, journalUnchanged: true });
}

async function relativeActionOrder(page, label) {
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add);
  const semantics = await body(page), heading = semantics.indexOf('Родные'), action = semantics.indexOf('Добавить родственника');
  assert.ok(heading >= 0 && action > heading, `${label}: Add Relative must follow the Relatives heading.`);
  const headingBox = await page.getByText('Родные', { exact: true }).boundingBox(), addBox = await add.boundingBox();
  assert.ok(headingBox && addBox && headingBox.y + headingBox.height <= addBox.y + 1,
    `${label}: Add Relative must be physically below Родные.`);
  const between = semantics.slice(heading + 'Родные'.length, action);
  assert.doesNotMatch(between, /(?:text|checkbox): (?:Отец|Мать|Братья|Дети)/,
    `${label}: a relationship group was inserted between Родные and Add Relative.`);
  await refinementCheckpoint(page, `${label}-relatives-heading-add-order`, true);
}

async function parentSubmitWithoutFalseFlash(page, dialog, label) {
  await page.evaluate(() => {
    const trace = { samples: [], active: true, overflow: false, started: performance.now() };
    window.__relativeSubmitTrace = trace;
    const sample = (source) => {
      if (!trace.active) return;
      if (trace.samples.length >= 2400) { trace.overflow = true; return; }
      const dialogs = [...document.querySelectorAll('[role="alertdialog"]')];
      const text = dialogs.map((dialog) => [...dialog.querySelectorAll('[aria-label]')].map((element) =>
        element.getAttribute('aria-label')).join('\n') + '\n' + dialog.textContent).join('\n');
      trace.samples.push({ source, t: performance.now() - trace.started, dialogPresent: dialogs.length > 0, text });
    };
    trace.observer = new MutationObserver(() => sample('mutation'));
    trace.observer.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
    const frame = () => { if (trace.active) { sample('animation-frame'); trace.frame = requestAnimationFrame(frame); } };
    sample('before-submit'); trace.frame = requestAnimationFrame(frame);
  });
  let trace;
  const screenshots = (async () => {
    for (let index = 0; index < 6; index++) {
      await sleep(16);
      await page.screenshot({ path: path.join(output, `${label}-submit-transition-${index}.png`), animations: 'disabled' });
    }
  })();
  try {
    await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
    await dialog.waitFor({ state: 'hidden' });
    await screenshots;
  } finally {
    await screenshots.catch(() => {});
    trace = await page.evaluate(() => {
      const trace = window.__relativeSubmitTrace;
      trace.active = false; trace.observer.disconnect(); cancelAnimationFrame(trace.frame);
      return { samples: trace.samples, overflow: trace.overflow, durationMs: performance.now() - trace.started };
    });
    await fs.writeFile(path.join(output, `${label}-submit-transition.json`), JSON.stringify(trace, null, 2));
    report.scenarios.push({ name: `${label}-submit-without-false-parent-flash`, trace,
      limit: 'Passive per-animation-frame/mutation semantics plus six bounded screenshots, not guaranteed 16ms screenshot cadence.' });
  }
  assert.equal(trace.overflow, false, 'Finite transition trace overflowed its evidence bound.');
  assert.ok(trace.samples.some((sample) => sample.dialogPresent) && trace.samples.some((sample) => !sample.dialogPresent),
    'Need both open and closed actual Add Relative dialog frames.');
  for (const sample of trace.samples) assert.doesNotMatch(sample.text,
    /Отец уже указан|Мать уже указана|Сначала удалите существующую связь|Не удалось добавить родственника/,
    `${label}: successful own submission exposed a false occupied-parent error.`);
  await refinementCheckpoint(page, `${label}-submission-transition-errors`);
}

async function orderingPhoneControls(page, seeded, label) {
  await loadRoom(page, seeded);
  const before = await history(page, seeded);
  await guestBadgePixels(page, seeded, label);
  const father = await refinementAddRelative(page, seeded, `${label}-actual-parent`, { person: 'Фокус', kind: 'Отца',
    name: 'Новый отец', sex: 'male', field: 'fatherId', parentId: 'root', traceSubmit: true });
  const after = await history(page, seeded);
  assert.equal(after.length, before.length + 2, 'Phone Add Parent must append only creation and its one father edge.');
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(before, null, 2));
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(after, null, 2));
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), after, 'Phone Add Parent reload changed complete immutable history.');
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(await history(page, seeded), null, 2));
  await openBiography(page, undefined, true);
  await relativeActionOrder(page, `${label}-reloaded`);
  const chip = page.getByRole('checkbox', { name: 'Новый отец', exact: true });
  await revealBiography(page, chip);
  assert.equal(await chip.getByRole('button', { name: 'удалить связь', exact: true }).count(), 1);
  await refinementCheckpoint(page, `${label}-new-father-reloaded`, true);
  await closeBiography(page);
  assert.deepEqual(await history(page, seeded), after, 'Reopening phone relative controls wrote hidden operations.');
  report.scenarios.push({ name: `${label}-ordering-phone-summary`, created: father, exactAppends: 2,
    falseOccupiedParentFlashAbsent: true, relativesHeadingBeforeAdd: true, guestBrownPixels: true, completeReload: true });
}

async function personalAncestryOrder(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  await setTreeZoom(page, 100);
  await guestBadgePixels(page, seeded, label);
  await strictDisplaySearch(page, seeded, label);
  const ownSiblingOrder = fixturePeopleByDisplay(seeded).filter((person) => person.generation === 3).map((person) => person.name);
  const evidence = [];
  const blocks = [['grandmother', 'grand-aunt'], ['mother', 'aunt'], ['z-partner', 'a-partner-sister']]
    .map((ids) => fixturePeopleByDisplay(seeded, ids).map((person) => person.name));
  for (const focus of ['root', 'partner', 'child']) {
    await toolbarSearchBrowse(page, seeded, `${label}-${focus}`, seeded.names[focus]);
    for (const [index, mode] of ['Обе линии', 'По матери', 'По отцу', 'Обе линии'].entries()) {
      await chooseTrunk(page, mode);
      await alignAll(page).click();
      await settle(page);
      const state = await branchCapture(page, seeded, `${label}-${focus}-${index}`);
      const entry = { name: state.title, focus, mode, state, blocks: [], seams: [] };
      evidence.push(entry); // Retain raw geometry even on a strict oracle failure.
      report.scenarios.push(entry);
      for (const person of seeded.people) assert.ok(state.nodes[person.name], `${state.title}: ${person.name} clipped.`);
      const axis = portrait ? 'y' : 'x';
      assert.deepEqual(order(state, 3, portrait), ownSiblingOrder,
        `${state.title}: selected generation must stay unknown-first/date/name/ID in every mode.`);
      for (const [blockIndex, canonical] of blocks.entries()) {
        const actual = canonical.slice().sort((a, b) => state.nodes[a][axis] - state.nodes[b][axis]);
        const exception = mode === 'Обе линии' && (focus === 'child' || focus === 'root' && blockIndex < 2);
        const expected = exception ? canonical.slice().reverse() : canonical;
        assert.deepEqual(actual, expected, `${state.title}: sibling order escaped the actual-ancestry BOTH-only exception.`);
        entry.blocks.push({ canonical, actual, exception });
      }
      const seams = [['Бабушка', 'Дедушка'], ['Мама', 'Папа'], ['Партнёр', 'Фокус']];
      for (const [mother, father] of [...seams, ['Общая прабабушка', 'Общий прадед'], ['Мать партнёра', 'Отец партнёра']]) {
        assert.ok(state.nodes[mother][axis] < state.nodes[father][axis], `${state.title}: structural mother/father side reversed.`);
      }
      if (mode === 'Обе линии' && focus !== 'partner') {
        for (const [mother, father] of seams.slice(0, focus === 'child' ? 3 : 2)) {
          const generation = state.nodes[mother].generation;
          const row = order(state, generation, portrait);
          assert.equal(row.indexOf(father), row.indexOf(mother) + 1, `${state.title}: actual ancestral parent cards are not adjacent.`);
          entry.seams.push({ mother, father, row });
        }
      }
      await refinementCheckpoint(page, state.title);
    }
  }
  assert.deepEqual(await history(page, seeded), journal, 'Ancestry/partner/single-mode navigation wrote history.');
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, 'Ancestry fixture immutable journal changed on reload.');
  await strictDisplaySearch(page, seeded, `${label}-reloaded`);
  await toolbarSearchBrowse(page, seeded, `${label}-reload-root`, 'Фокус');
  await chooseTrunk(page, 'По матери');
  await alignAll(page).click();
  await settle(page);
  const restored = await branchCapture(page, seeded, `${label}-reload-single-canonical`);
  for (const canonical of blocks) assert.deepEqual(canonical.slice().sort((a, b) => restored.nodes[a][portrait ? 'y' : 'x'] -
    restored.nodes[b][portrait ? 'y' : 'x']), canonical, 'Reloaded single mode lost canonical sibling order.');
  await fs.writeFile(path.join(output, `${label}-complete-journal.json`), JSON.stringify(journal, null, 2));
  report.scenarios.push({ name: `${label}-personal-ancestry-order-summary`, geometryStates: evidence.length,
    ancestralLevels: 3, selectedPartnerCannotReorder: true, singlesCanonical: true, completeJournalUnchanged: true,
    comparator: 'unknown-first/date/trim-lower-ё=е given name/ID only total tie',
    noDobAndEqualDobNamesOpposeIds: true, normalizedNameTieUsesId: true, ownSiblingOrder, guestBrownEye: true });
  console.log(`PASS: ${label} canonical siblings except actual ancestral seams in BOTH, every ancestor level; selected partner cannot reorder; all single modes canonical.`);
}

async function surnameEditing(page, seeded, label) {
  await loadRoom(page, seeded);
  const initial = await history(page, seeded);
  const inheritedFooter = await surnameFooter(page, 'Ивановы', ['Борис', 'Анна', 'Вера'], `${label}-inherited`);
  await singletonSurnameBlocks(page, seeded, label);
  await assertReadSurname(page, 'Анна', 'Анна Иванова');
  await surnameSearch(page, seeded, label);
  assert.deepEqual(await history(page, seeded), initial, 'Viewing surnames/footers/search wrote history.');
  await openBiography(page, 'Мария', true);
  await surnameControls(page, { text: '', decline: true });
  const unset = await history(page, seeded);
  await surnameDecline(page).click();
  await surnameControls(page, { text: '', decline: false });
  assert.deepEqual(await history(page, seeded), unset, 'Unset decline draft must not create a surname register.');
  await closeBiography(page);
  await openBiography(page, 'Анна', true);
  await surnameControls(page, { text: '', decline: true });
  assert.match(await body(page), /Наследуется от отца: Павел Иванов/);
  await personalSurnameWrite(page, seeded, `${label}-personal-typed`, 'root', 'Орлов', true);
  await personalSurnameWrite(page, seeded, `${label}-literal-no-decline`, 'root', 'Орлов', false, { toggle: true });
  await closeBiography(page);
  await assertReadSurname(page, 'Анна', 'Анна Орлов');
  await assertReadSurname(page, 'Вера', 'Вера Иванова');
  const mixedFooter = await surnameFooter(page, 'разные фамилии', ['Борис', 'Анна', 'Вера'], `${label}-personal-mixed`);
  await openBiography(page, 'Анна', true);
  await personalSurnameWrite(page, seeded, `${label}-personal-clear-inherits`, 'root', null, false, { clearButton: true });
  assert.match(await body(page), /Наследуется от отца: Павел Иванов/);
  await closeBiography(page);
  await assertReadSurname(page, 'Анна', 'Анна Иванова');
  await openBiography(page, 'Борис', true);
  await surnameControls(page, { text: '', decline: true });
  await personalSurnameWrite(page, seeded, `${label}-other-sibling-personal`, 'brother', 'Орлов', true);
  await closeBiography(page);
  await assertReadSurname(page, 'Вера', 'Вера Иванова');
  await openBiography(page, 'Анна', true);
  await personalSurnameWrite(page, seeded, `${label}-personal-retype`, 'root', 'Ким', true);
  await personalSurnameWrite(page, seeded, `${label}-personal-false`, 'root', 'Ким', false, { toggle: true });
  await closeBiography(page);
  const lookup = await history(page, seeded);
  await type(page, treeSearch(page), 'Анна Ким 1985');
  await searchOption(page, 'Анна Ким').click();
  await settle(page);
  assert.deepEqual(await history(page, seeded), lookup, 'Canonical lookup wrote history.');
  await surnamePicker(page, seeded, label);
  const saved = await history(page, seeded);
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), saved, 'Complete surname/relative journal changed after reload.');
  await assertReadSurname(page, 'Анна', 'Анна Ким');
  await openBiography(page, 'Анна', true);
  await surnameControls(page, { text: 'Ким', decline: false });
  await page.screenshot({ path: path.join(output, `${label}-personal-surname-and-edge-reloaded.png`), animations: 'disabled' });
  await closeBiography(page);
  const edits = await appendedOperations(page, seeded, initial);
  assert.ok(edits.every((op) => op.type === 'setSurname' ? op.scope === 'individual' && op.familyKey === null :
    op.type === 'setValue' && op.personId === 'root' && op.field === 'fatherId' && [null, 'brother'].includes(op.value)),
  'Surname flow emitted shared/maiden/unrelated operations.');
  assert.deepEqual(await history(page, seeded), saved, 'Readonly/reload checks appended edits.');
  report.scenarios.push({ name: `${label}-personal-birth-surname-and-reload`, inheritedFooter, mixedFooter,
    personalOnlyWrites: true, fullSiblingUnaffected: true, clearInheritsFather: true, noScopeToggle: true,
    defaultDeclineAndExistingFalse: true, canonicalSearchOnly: true, literalFemaleSuffix: 'а', literalPluralSuffix: 'ы',
    legacyHistoryUnchanged: true, fullJournalSurvivesReload: true });
  console.log(`PASS: ${label} personal-only surname, no scope toggle, sibling isolation, clear/father inheritance, canonical search/picker and full reload.`);
}

async function surnameCanvasChrome(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const unchanged = await history(page, seeded);
  const box = await node(page, 'Фокус').boundingBox();
  const viewport = page.viewportSize();
  const top = await canvasTop(page);
  const hover = portrait ? { x: box.x - 22, y: viewport.height - 70 } : { x: 24, y: box.y - 22 };
  const samples = portrait ? [top + 45, (top + viewport.height) / 2, viewport.height - 55]
    .map((y) => ({ x: box.x - 22, y })) : [50, viewport.width / 2, viewport.width - 50]
    .map((x) => ({ x, y: box.y - 22 }));
  const witnesses = [-176, 176].map((offset) => portrait ? { x: hover.x + offset, y: hover.y } :
    { x: hover.x, y: hover.y + offset }).filter((point) => point.x > 2 && point.x < viewport.width - 2 &&
      point.y > top + 2 && point.y < viewport.height - 20);
  const before = await page.screenshot({ animations: 'disabled', scale: 'css' });
  await page.mouse.move(hover.x, hover.y);
  await sleep(180);
  const afterHover = await page.screenshot({ path: path.join(output, `${label}-generation-hover-band.png`), animations: 'disabled', scale: 'css' });
  // Physical cross-axis wheel creates overflow notifications while the pointer
  // remains in the band. Inner scrollbar paint would be visible at this instant.
  await page.mouse.wheel(portrait ? 0 : 110, portrait ? 110 : 0);
  await sleep(70);
  const afterWheel = await page.screenshot({ path: path.join(output, `${label}-no-inner-generation-bars.png`), animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async ({ a, b, c, samples, witnesses, portrait, box, top }) => {
    const decode = async (png) => {
      const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      return { width: image.width, height: image.height, context };
    };
    const [before, hover, wheel] = await Promise.all([a, b, c].map(decode));
    const pixel = (image, point) => [...image.context.getImageData(Math.round(point.x), Math.round(point.y), 1, 1).data].slice(0, 3);
    const changes = samples.map((point) => ({ point, before: pixel(before, point), after: pixel(hover, point) }));
    const outside = witnesses.map((point) => ({ point, before: pixel(before, point), after: pixel(hover, point) }));
    const background = pixel(wheel, samples[0]);
    let longestDarkRun = 0;
    const edge = portrait ? box.x + 108 + 34 : box.y + 108 + 34;
    for (let inset = 2; inset <= 9; inset++) {
      let run = 0;
      const start = portrait ? Math.ceil(top + 25) : 25;
      const end = portrait ? wheel.height - 60 : wheel.width - 25;
      for (let cross = start; cross < end; cross++) {
        const point = portrait ? { x: edge - inset, y: cross } : { x: cross, y: edge - inset };
        const rgb = pixel(wheel, point);
        if (rgb.every((channel, index) => channel < background[index] - 20)) run++;
        else run = 0;
        longestDarkRun = Math.max(longestDarkRun, run);
      }
    }
    return { changes, outside, background, longestDarkRun, scrollbarScanEdge: edge };
  }, { a: before.toString('base64'), b: afterHover.toString('base64'), c: afterWheel.toString('base64'),
    samples, witnesses, portrait, box, top });
  assert.ok(pixels.changes.filter((entry) => entry.before.every((value, index) => value - entry.after[index] >= 3 &&
    value - entry.after[index] <= 14)).length >= 2, `Hover did not subtly highlight the full generation band: ${JSON.stringify(pixels)}`);
  assert.ok(pixels.outside.length > 0 && pixels.outside.every((entry) => entry.before.every((value, index) =>
    Math.abs(value - entry.after[index]) <= 1)), 'Hover highlight escaped its generation band.');
  assert.ok(pixels.longestDarkRun < 30, `A long inner-generation scrollbar-like stroke was painted: ${JSON.stringify(pixels)}`);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), viewport.width);
  assert.deepEqual(await history(page, seeded), unchanged, 'Hover/scroll chrome wrote an edit.');
  report.scenarios.push({ name: `${label}-subtle-generation-hover-without-inner-scrollbar`, pixels,
    actualCrossAxisWheel: true, journalUnchanged: true });
  console.log(`PASS: ${label} subtle full-generation hover band and no inner scrollbar paint during real overflow scrolling.`);
}

async function browserZoomState(page) {
  const state = await page.evaluate(() => ({ scale: visualViewport.scale, width: innerWidth,
    visualWidth: visualViewport.width, dpr: devicePixelRatio, x: scrollX, y: scrollY,
    documentWidth: document.documentElement.scrollWidth }));
  assert.equal(state.scale, 1, 'The browser visual viewport was natively zoomed.');
  return state;
}

async function assertNodeScale(page, name, percent) {
  const box = await node(page, name).boundingBox();
  assert.ok(box && Math.abs(box.width - 108 * percent / 100) <= 1.5 &&
    Math.abs(box.height - 108 * percent / 100) <= 1.5,
  `${name}'s rendered node did not scale uniformly to ${percent}%: ${JSON.stringify(box)}`);
  return box;
}

async function assertNoGestureSelection(page, selected = 'Фокус') {
  assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0,
    'A zoom gesture accidentally opened a biography.');
  await assertSelected(page, selected);
  const selectedButtons = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) =>
    elements.filter((element) => element.getAttribute('aria-selected') === 'true' ||
      element.getAttribute('aria-pressed') === 'true').map((element) => element.getAttribute('aria-label')));
  if (selectedButtons.length) assert.deepEqual(selectedButtons, [`Выбрать ${selected}`],
    'A zoom gesture accidentally selected a different person.');
}

async function zoomToolbar(page, seeded, label) {
  await loadRoom(page, seeded);
  const unchanged = await history(page, seeded);
  const ordinaryBrowser = await browserZoomState(page);
  assert.equal(await zoomPercent(page), 100, 'The initial tree zoom is not 100%.');
  assert.doesNotMatch(await body(page), /(?:^|\n)\s*- text: (?:Мужчина|Женщина|Пол не указан)(?:\n|$)/,
    'The removed gender legend is still painted/exported.');
  const controls = {};
  for (const [name, locator] of [['in', zoomIn(page)], ['out', zoomOut(page)],
    ['floatingBiography', page.getByRole('button', { name: 'Биография', exact: true })]]) {
    controls[name] = await locator.boundingBox();
  }
  const steps = [];
  for (const expected of [90, 80, 70, 60, 50, 40, 30, 26]) {
    await zoomOut(page).click();
    await until(async () => await zoomPercent(page) === expected, `Zoom-out missed its 10% step to ${expected}%.`);
    steps.push(expected);
  }
  await settle(page);
  await assertNodeScale(page, 'Фокус', 26);
  const lower = await zoomOut(page).boundingBox();
  await page.mouse.click(center(lower).x, center(lower).y);
  assert.equal(await zoomPercent(page), 26, 'The nominal 4mm-avatar lower toolbar limit is not enforced.');
  for (let expected = 30; expected <= 200; expected += 10) {
    await zoomIn(page).click();
    await until(async () => await zoomPercent(page) === expected, `Zoom-in missed its 10% step to ${expected}%.`);
    steps.push(expected);
  }
  await settle(page);
  await assertNodeScale(page, 'Фокус', 200);
  const upper = await zoomIn(page).boundingBox();
  await page.mouse.click(center(upper).x, center(upper).y);
  assert.equal(await zoomPercent(page), 200, 'The upper toolbar limit is not enforced.');
  for (const [name, locator] of [['in', zoomIn(page)], ['out', zoomOut(page)],
    ['floatingBiography', page.getByRole('button', { name: 'Биография', exact: true })]]) {
    const box = await locator.boundingBox();
    for (const dimension of ['x', 'y', 'width', 'height']) {
      assert.ok(Math.abs(box[dimension] - controls[name][dimension]) <= 1.5,
        `Logical-canvas zoom changed the physical ${name}.${dimension}.`);
    }
  }
  await capture(page, seeded, `${label}-toolbar-200-percent`);
  await zoomReset(page).hover();
  await until(async () => (await body(page)).includes('Сбросить масштаб'),
    'Real pointer hover did not expose the reset zoom tooltip.');
  await settle(page);
  await zoomReset(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 100);
  await assertNodeScale(page, 'Фокус', 100);
  await page.getByRole('button', { name: 'Свернуть панель дерева', exact: true }).click();
  await settle(page);
  assert.equal(await page.getByRole('button', { name: /^Линия дерева:/ }).count(), 0);
  assert.equal(await treeSearch(page).count(), 0, 'Collapsed toolbar kept its search input.');
  for (const control of [zoomOut(page), zoomReset(page), zoomIn(page)]) {
    assert.equal(await control.count(), 0, 'Collapsed toolbar kept an actual zoom control.');
  }
  await page.screenshot({ path: path.join(output, `${label}-entire-toolbar-collapsed-floating-opener.png`), animations: 'disabled' });
  await page.getByRole('button', { name: 'Развернуть панель дерева', exact: true }).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 100, 'Expanding the toolbar changed its saved zoom.');
  assert.equal(await treeSearch(page).count(), 1);
  assert.equal(await page.getByRole('button', { name: /^Линия дерева:/ }).count(), 1);
  assert.deepEqual(await browserZoomState(page), ordinaryBrowser, 'Toolbar zoom changed browser/page scale.');
  assert.deepEqual(await history(page, seeded), unchanged, 'View-only toolbar zoom wrote to the immutable journal.');
  report.scenarios.push({ name: `${label}-toolbar-zoom-limits-steps-reset-and-collapse`, steps, controls,
    lowerLimit: 26, upperLimit: 200, browserZoomUnchanged: true, historyUnchanged: true });
}

async function controlWheel(page, point, delta) {
  await page.mouse.move(point.x, point.y);
  await page.keyboard.down('Control');
  try { await page.mouse.wheel(0, delta); } finally { await page.keyboard.up('Control'); }
  await settle(page);
}

const siblingUnlinkLabel = 'Убрать прямую братскую связь';
const relativeChip = (page, name) => page.getByRole('checkbox', { name, exact: true })
  .or(page.getByRole('button', { name, exact: true }));

async function explicitSiblingDelta(page, seeded, before, label, count) {
  await until(async () => (await history(page, seeded)).length >= before.length + count,
    `${label}: the actual UI command was not saved.`, 10000);
  const after = await history(page, seeded), operations = await appendedOperations(page, seeded, before);
  assert.equal(operations.length, count, `${label}: command appended extra parent/person/claim writes.`);
  const records = after.filter((record) => !before.some((old) => old.id === record.id));
  report.scenarios.push({ name: label, records, operations });
  await fs.writeFile(path.join(output, `${label}-journal.json`), JSON.stringify(after, null, 2));
  await refinementCheckpoint(page, `${label}-errors`);
  return { after, records, operations };
}

async function explicitSiblingForm(page, label, kind) {
  await chooseKind(page, 'Брат/сестра');
  const dialog = page.getByRole('alertdialog');
  await dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }).waitFor();
  assert.equal(await dialog.getByRole('button', { name: 'Выбрать', exact: true }).count(), 0,
    `${label}: a sibling kind must not offer an existing-person picker.`);
  const fromTree = dialog.getByRole('checkbox', { name: 'Из дерева', exact: true });
  const fresh = dialog.getByRole('checkbox', { name: 'Новый человек', exact: true });
  assert.equal(await fromTree.count(), 1, `${label}: the sibling source row must keep from-tree visible.`);
  assert.equal(await fresh.count(), 1, `${label}: the sibling source row must keep new-person visible.`);
  assert.equal(await fresh.isChecked(), true, `${label}: a sibling stays on the new person.`);
  assert.equal(await fromTree.isDisabled(), true, `${label}: from-tree must be muted for a sibling.`);
  await chooseNewPersonSex(page, kind === 'Брат' ? 'Мужской' : 'Женский');
  await dialog.getByRole('button', { name: 'Дата рождения (необязательно)', exact: true }).waitFor();
  await page.screenshot({ path: path.join(output, `${label}-${kind === 'Брат' ? 'brother' : 'sister'}-form.png`), animations: 'disabled' });
  await refinementCheckpoint(page, `${label}-form-errors`);
}

async function explicitSiblingAdd(page, seeded, source, kind, name, label) {
  const before = await history(page, seeded);
  await openBiography(page, source, true);
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add); await add.click();
  await explicitSiblingForm(page, label, kind);
  assert.deepEqual(await history(page, seeded), before, `${label}: opening/inspecting a sibling form wrote history.`);
  const dialog = page.getByRole('alertdialog');
  await type(page, dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  const delta = await explicitSiblingDelta(page, seeded, before, label, 1), op = delta.operations[0];
  assert.deepEqual(op, { type: 'createSibling', personId: op.personId,
    siblingId: seeded.people.find((person) => person.name === source).id,
    name, sex: kind === 'Брат' ? 'male' : 'female', birthDate: null });
  assert.ok(op.personId && !seeded.people.some((person) => person.id === op.personId));
  seeded.people.push({ id: op.personId, name, sex: op.sex, generation: 1 });
  seeded.names[op.personId] = name;
  await closeBiography(page);
  return { ...op, linkId: delta.records[0].id };
}

async function explicitSiblingParent(page, seeded, source, kind, name, label, existing = false) {
  const before = await history(page, seeded);
  await openBiography(page, source, true);
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add); await add.click(); await chooseKind(page, kind);
  const dialog = page.getByRole('alertdialog'), field = kind === 'Отца' ? 'fatherId' : 'motherId';
  if (existing) {
    await dialog.getByRole('checkbox', { name: 'Из дерева', exact: true }).click();
    await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
    await page.getByRole('button', { name: 'Отмена выбора', exact: true }).waitFor();
    await select(page, name);
    await page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).click();
    await dialog.waitFor();
    assert.deepEqual(await history(page, seeded), before, `${label}: browsing an existing parent wrote history.`);
  } else {
    await dialog.getByRole('checkbox', { name: 'Новый человек', exact: true }).click();
    await type(page, dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }), name);
  }
  await dialog.getByRole('button', { name: 'Добавить', exact: true }).click();
  await dialog.waitFor({ state: 'hidden' });
  const delta = await explicitSiblingDelta(page, seeded, before, label, existing ? 1 : 2);
  let parent = seeded.people.find((person) => person.name === name);
  if (!existing) {
    const op = delta.operations.find((op) => op.type === 'createPerson');
    assert.ok(op && op.name === name && op.sex === (kind === 'Отца' ? 'male' : 'female'));
    parent = { id: op.personId, name, sex: op.sex, generation: 0 };
    seeded.people.push(parent); seeded.names[parent.id] = name;
  }
  assert.deepEqual(delta.operations.filter((op) => op.type !== 'createPerson'), [{ type: 'setValue',
    personId: seeded.people.find((person) => person.name === source).id, field, value: parent.id }],
  `${label}: propagation must be domain-derived, not per-sibling writes or auto-unlinks.`);
  await closeBiography(page);
  return parent;
}

async function explicitSiblingInspect(page, seeded, source, expected, label, screenshot = false) {
  const before = await history(page, seeded);
  await openBiography(page, source, true);
  const observations = [];
  for (const [name, present, direct] of expected) {
    const chip = relativeChip(page, name);
    assert.equal(await chip.count(), present ? 1 : 0, `${label}: ${source}'s actual relative ${name} differs.`);
    if (!present) continue;
    await revealBiography(page, chip);
    const remove = await chip.getByRole('button', { name: siblingUnlinkLabel, exact: true }).count();
    assert.equal(remove, direct ? 1 : 0, `${label}: direct-only sibling X differs for ${source}↔${name}.`);
    observations.push({ name, directSiblingX: Boolean(remove) });
  }
  if (screenshot) await page.screenshot({ path: path.join(output, `${label}-biography.png`), animations: 'disabled' });
  assert.deepEqual(await history(page, seeded), before, `${label}: opening/reading relative controls wrote history.`);
  report.scenarios.push({ name: label, source, observations, openingHistoryUnchanged: true });
  await closeBiography(page);
}

async function explicitSiblingGeometry(page, seeded, label, groups) {
  await select(page, 'Алексей');
  await alignAll(page).click(); await settle(page);
  const before = await history(page, seeded), state = await branchCapture(page, seeded, label);
  const portrait = page.viewportSize().width < page.viewportSize().height, cross = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  const children = ['Алексей', 'Борис', 'Вера'].filter((name) => seeded.people.some((person) => person.name === name));
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${label}: tiny-fixture card ${person.name} clipped.`);
  const row = children.slice().sort((a, b) => state.nodes[a][cross] - state.nodes[b][cross]);
  for (const name of children) assert.ok(Math.abs(state.nodes[name][main] - state.nodes[children[0]][main]) <= 1.5,
    `${label}: explicit or former siblings split across generations.`);
  for (const group of groups) {
    const canonical = group.slice().sort((a, b) => compareDisplayPeople({ name: a, id: a }, { name: b, id: b }));
    const actual = row.filter((name) => group.includes(name));
    assert.deepEqual(actual, canonical, `${label}: undated full-group given-name order changed.`);
    const indices = actual.map((name) => row.indexOf(name));
    assert.equal(indices.at(-1) - indices[0], group.length - 1, `${label}: sibling block interleaved.`);
  }
  for (let index = 1; index < row.length; index++) {
    const a = row[index - 1], b = row[index], together = groups.some((group) => group.includes(a) && group.includes(b));
    const pitch = state.nodes[b][cross] - state.nodes[a][cross];
    assert.ok(together ? Math.abs(pitch - 132) <= 1.5 : pitch >= 156 - 1.5,
      `${label}: ${a}/${b} do not have the expected ${together ? '132px same-block' : 'minimum 156px separate-block'} pitch.`);
  }
  for (const parent of seeded.people.filter((person) => person.generation === 0)) assert.ok(
    Math.abs(state.nodes[children[0]][main] - state.nodes[parent.name][main] - 176) <= 1.5,
    `${label}: parent is not in the immediately preceding generation.`);
  assert.deepEqual(await history(page, seeded), before, `${label}: alignment/geometry wrote history.`);
  await refinementCheckpoint(page, `${label}-errors`);
  report.scenarios.push({ name: label, state, groups, sameRank: true, canonicalBlocks: true });
}

async function explicitSiblingsLocal(desktop, phone, desktopSeed, phoneSeed) {
  // Start both real saved-member gates together; do not bypass their ~30s UI wait.
  await Promise.all([loadRoom(desktop, desktopSeed), loadRoom(phone, phoneSeed)]);
  const initial = await history(desktop, desktopSeed), phoneInitial = await history(phone, phoneSeed);
  await fs.writeFile(path.join(output, 'explicit-siblings-desktop-journal-before.json'), JSON.stringify(initial, null, 2));
  await fs.writeFile(path.join(output, 'explicit-siblings-phone-journal-before.json'), JSON.stringify(phoneInitial, null, 2));
  await openBiography(phone, 'Алексей', true);
  const add = phone.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(phone, add); await add.click();
  for (const kind of ['Брат', 'Сестра']) await explicitSiblingForm(phone, `explicit-siblings-phone-${kind === 'Брат' ? 'brother' : 'sister'}`, kind);
  await phone.getByRole('alertdialog').getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(phone);
  assert.deepEqual(await history(phone, phoneSeed), phoneInitial, 'Phone sibling form cancellation wrote history.');
  const brother = await explicitSiblingAdd(desktop, desktopSeed, 'Алексей', 'Брат', 'Борис', 'explicit-siblings-create-brother');
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-zero-parent-pair', [['Алексей', 'Борис']]);
  const sister = await explicitSiblingAdd(desktop, desktopSeed, 'Борис', 'Сестра', 'Вера', 'explicit-siblings-create-transitive-sister');
  await explicitSiblingInspect(desktop, desktopSeed, 'Алексей', [['Борис', true, true], ['Вера', true, false]], 'explicit-siblings-direct-versus-transitive', true);
  await explicitSiblingInspect(desktop, desktopSeed, 'Борис', [['Алексей', true, true], ['Вера', true, true]], 'explicit-siblings-bridge-two-direct-edges');
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-zero-parent-transitive-group', [['Алексей', 'Борис', 'Вера']]);
  const father = await explicitSiblingParent(desktop, desktopSeed, 'Алексей', 'Отца', 'Николай', 'explicit-siblings-add-shared-father');
  for (const name of ['Алексей', 'Борис', 'Вера']) await explicitSiblingInspect(desktop, desktopSeed, name,
    [['Николай', true, false]], `explicit-siblings-father-on-${name}`);
  await openBiography(desktop, 'Алексей', true);
  let before = await history(desktop, desktopSeed);
  await unlinkChip(desktop, 'Николай');
  let delta = await explicitSiblingDelta(desktop, desktopSeed, before, 'explicit-siblings-clear-shared-father', 1);
  assert.deepEqual(delta.operations, [{ type: 'setValue', personId: 'root', field: 'fatherId', value: null }]);
  await closeBiography(desktop);
  for (const name of ['Алексей', 'Борис', 'Вера']) await explicitSiblingInspect(desktop, desktopSeed, name,
    [['Николай', false, false]], `explicit-siblings-father-cleared-on-${name}`);
  await explicitSiblingParent(desktop, desktopSeed, 'Алексей', 'Отца', 'Николай', 'explicit-siblings-reassign-existing-father', true);
  await openBiography(desktop, 'Алексей', true);
  before = await history(desktop, desktopSeed);
  const direct = relativeChip(desktop, 'Борис').getByRole('button', { name: siblingUnlinkLabel, exact: true });
  await revealBiography(desktop, relativeChip(desktop, 'Борис')); await direct.click();
  delta = await explicitSiblingDelta(desktop, desktopSeed, before, 'explicit-siblings-unlink-bridge', 1);
  assert.deepEqual(delta.operations, [{ type: 'unlinkSibling', personId: brother.personId, siblingId: 'root', linkId: brother.linkId }]);
  await closeBiography(desktop);
  for (const name of ['Алексей', 'Борис', 'Вера']) await explicitSiblingInspect(desktop, desktopSeed, name,
    [['Николай', true, false]], `explicit-siblings-retained-father-on-${name}`);
  await explicitSiblingInspect(desktop, desktopSeed, 'Алексей', [['Борис', true, false], ['Вера', true, false]], 'explicit-siblings-split-half-no-x', true);
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-one-parent-split', [['Алексей'], ['Борис', 'Вера']]);
  const mother = await explicitSiblingParent(desktop, desktopSeed, 'Борис', 'Мать', 'Мария', 'explicit-siblings-materialize-second-parent');
  await explicitSiblingInspect(desktop, desktopSeed, 'Алексей', [['Мария', false, false]], 'explicit-siblings-detached-not-propagated');
  for (const name of ['Борис', 'Вера']) await explicitSiblingInspect(desktop, desktopSeed, name,
    [['Николай', true, false], ['Мария', true, false], [name === 'Борис' ? 'Вера' : 'Борис', true, false]],
    `explicit-siblings-computed-full-${name}`, true);
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-materialized-full-no-claims', [['Алексей'], ['Борис', 'Вера']]);
  await openBiography(desktop, 'Борис', true);
  before = await history(desktop, desktopSeed); await unlinkChip(desktop, 'Мария');
  delta = await explicitSiblingDelta(desktop, desktopSeed, before, 'explicit-siblings-clear-after-retirement', 1);
  assert.deepEqual(delta.operations, [{ type: 'setValue', personId: brother.personId, field: 'motherId', value: null }]);
  await closeBiography(desktop);
  await explicitSiblingInspect(desktop, desktopSeed, 'Вера', [['Мария', true, false], ['Борис', true, false]], 'explicit-siblings-retired-claim-no-fanout', true);
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-retired-claim-no-revival', [['Алексей'], ['Борис'], ['Вера']]);
  const final = await history(desktop, desktopSeed);
  const all = await appendedOperations(desktop, desktopSeed, initial);
  assert.equal(all.filter((op) => op.type === 'createSibling').length, 2);
  assert.equal(all.filter((op) => op.type === 'unlinkSibling').length, 1, 'Materialization must retire claims without journal-side cleanup writes.');
  await fs.writeFile(path.join(output, 'explicit-siblings-desktop-journal-after.json'), JSON.stringify(final, null, 2));
  await Promise.all([loadRoom(desktop, desktopSeed), loadRoom(phone, phoneSeed)]);
  assert.deepEqual(await history(desktop, desktopSeed), final, 'Desktop reload lost immutable sibling history.');
  assert.deepEqual(await history(phone, phoneSeed), phoneInitial, 'Phone form cancellation/reload changed history.');
  await fs.writeFile(path.join(output, 'explicit-siblings-desktop-journal-reloaded.json'), JSON.stringify(await history(desktop, desktopSeed), null, 2));
  await fs.writeFile(path.join(output, 'explicit-siblings-phone-journal-reloaded.json'), JSON.stringify(await history(phone, phoneSeed), null, 2));
  await explicitSiblingGeometry(desktop, desktopSeed, 'explicit-siblings-reloaded-no-revival', [['Алексей'], ['Борис'], ['Вера']]);
  await refinementCheckpoint(phone, 'explicit-siblings-phone-reloaded-errors', true);
  report.scenarios.push({ name: 'explicit-siblings-local-summary', completed: true,
    atomicCreates: [brother, sister], father, mother, oneOperationParentFanoutAndClear: true,
    directOnlyX: true, bridgeUnlinkRetainsParents: true, completionRetiresClaimsWithoutWrites: true,
    laterClearDoesNotReviveClaim: true, canonicalGroupsAndRanks: true, phoneFormsOnly: true,
    records: final.length, journalSha256: crypto.createHash('sha256').update(JSON.stringify(final)).digest('hex'),
    fullImmutableJournalsReloaded: true, pixels: 'unrun; geometry/screenshots only', networking: 'blocked; no sync claim',
    limitations: 'Finite zero/one-parent chain; broader cycles/conflicts/retry/atomic failure and capability rejection remain unit/session tests.' });
  console.log('PASS: local explicit siblings atomic UI creation, transitive grouping/direct-only X, shared parents, bridge split, irreversible claim retirement, phone forms and full journal reload.');
}

// Nominal CSS/logical sizing only: this is not monitor or phone calibration.
const minimumAvatarFloorPercent = Math.ceil(4 * 96 / 25.4 / 60 * 100);

async function minimumAvatarZoom(page, seeded, label, mobile) {
  await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), native = await browserZoomState(page);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  assert.equal(native.dpr, mobile ? 3 : 1, `${label}: the intended DPR contrast is missing.`);
  assert.equal(await zoomPercent(page), 100);
  const steps = [];
  for (const expected of [90, 80, 70, 60, 50, 40, 30, minimumAvatarFloorPercent]) {
    await zoomOut(page).click();
    await until(async () => await zoomPercent(page) === expected, `${label}: minus missed ${expected}%.`, 5000);
    steps.push(expected);
  }
  await settle(page);
  assert.equal(minimumAvatarFloorPercent, 26);
  assert.equal(await zoomOut(page).isEnabled(), false, `${label}: minus is not disabled at 26%.`);
  const lower = await zoomOut(page).boundingBox();
  await page.mouse.click(center(lower).x, center(lower).y);
  await sleep(100);
  assert.equal(await zoomPercent(page), 26, `${label}: a disabled minus exceeded the floor.`);
  const state = await branchSnapshot(page, seeded, `${label}-floor-26`);
  // Device-resolution PNGs retain the DPR3 outline; measured bounds are later
  // divided back to CSS px, never interpreted as a physical-DPI calibration.
  const screenshot = `${state.title}.png`;
  await page.screenshot({ path: path.join(output, screenshot), animations: 'disabled', scale: 'device' });
  await fs.writeFile(path.join(output, `${state.title}.json`), JSON.stringify(state, null, 2));
  const documentBounds = await page.evaluate(() => ({ width: innerWidth, height: innerHeight,
    scrollWidth: document.documentElement.scrollWidth, scrollHeight: document.documentElement.scrollHeight }));
  assert.equal(documentBounds.scrollWidth, documentBounds.width, `${label}: native document overflows horizontally.`);
  assert.ok(documentBounds.scrollHeight <= documentBounds.height + .5, `${label}: native document overflows vertically.`);
  const controls = {};
  for (const [name, locator] of [['minus', zoomOut(page)], ['plus', zoomIn(page)], ['percentage', zoomReset(page)]]) {
    const box = await locator.boundingBox();
    controls[name] = box;
    assert.ok(box && box.x >= -.5 && box.y >= -.5 && box.x + box.width <= state.viewport.width + .5 &&
      box.y + box.height <= state.viewport.height + .5, `${label}: ${name} control is outside the viewport.`);
  }
  const entry = { name: `${label}-minimum-avatar-core`, state, screenshot, steps, native, documentBounds, controls,
    nominalMinimumCssPx: 4 * 96 / 25.4, expectedAvatarCssPx: 60 * 26 / 100,
    expectedNominalMillimeters: 60 * 26 / 100 * 25.4 / 96,
    physicalMillimetersVerified: false, paintStatus: 'unrun' };
  report.scenarios.push(entry);
  assert.equal(Object.keys(state.nodes).length, seeded.people.length, `${label}: a tiny fixture card is clipped.`);
  for (const person of seeded.people) {
    const card = await assertNodeScale(page, person.name, 26);
    assert.ok(Math.abs(card.width - 28.08) <= .2 && Math.abs(card.height - 28.08) <= .2,
      `${label}: actual semantic card does not match the 26% geometry.`);
    assert.ok(card.width * 60 / 108 >= entry.nominalMinimumCssPx,
      `${label}: semantic geometry implies an avatar below the nominal 4mm threshold.`);
  }
  await assertNoGestureSelection(page);
  await refinementCheckpoint(page, `${label}-floor-errors`);
  await zoomIn(page).click();
  await until(async () => await zoomPercent(page) === 30, `${label}: plus must snap 26→30, not36.`, 5000);
  await settle(page);
  await assertNodeScale(page, 'Фокус', 30);
  entry.nextPlusPercent = 30;
  await zoomOut(page).click();
  await until(async () => await zoomPercent(page) === 26, `${label}: minus must return 30→26.`, 5000);
  if (!mobile) {
    await zoomReset(page).click();
    await until(async () => await zoomPercent(page) === 100, `${label}: reset did not restore100%.`, 5000);
    const wheel = [];
    for (const [delta, expected] of [[10000, 26], [60, 26], [-100, 30]]) {
      const point = center(await node(page, 'Фокус').boundingBox());
      await controlWheel(page, point, delta);
      const actual = await zoomPercent(page), event = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
      wheel.push({ delta, actual, expected, event });
      assert.equal(actual, expected, `${label}: Ctrl+wheel floor/grid or boundary residual failed.`);
      assert.ok(event?.trusted && event.ctrl && event.prevented && event.deltaY === delta,
        `${label}: Ctrl+wheel was not a genuine owned browser event.`);
      await assertNodeScale(page, 'Фокус', expected);
    }
    entry.trustedWheel = wheel;
  }
  await assertNoGestureSelection(page);
  assert.deepEqual(await browserZoomState(page), native, `${label}: app zoom changed native browser scale/scroll.`);
  const after = await history(page, seeded);
  assert.deepEqual(after, journal, `${label}: view-only zoom wrote immutable history.`);
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(after, null, 2));
  await refinementCheckpoint(page, `${label}-after-zoom-errors`);
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded);
  assert.deepEqual(reloaded, journal, `${label}: complete persistent journal changed on reload.`);
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(reloaded, null, 2));
  await refinementCheckpoint(page, `${label}-reloaded-errors`);
  entry.records = journal.length;
  entry.journalSha256 = crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex');
  entry.completeBeforeAfterReloadEqual = entry.corePassed = true;
  console.log(`PASS: ${label} nominal26% floor, 28.08px cards, 26→30→26 controls, full journal/reload; physical mm not calibrated.`);
  return entry;
}

async function minimumAvatarPaint(page, entry) {
  const png = await fs.readFile(path.join(output, entry.screenshot));
  // The unselected direct ancestor has a real photo and NO selected-card stroke.
  // Restrict to its avatar, using several central scanlines to reject its one
  // outgoing connector. Do not reuse the selected-card color sampler.
  const measured = await page.evaluate(async ({ base64, state }) => {
    const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const data = context.getImageData(0, 0, image.width, image.height).data;
    const rasterScale = image.width / state.viewport.width, box = state.nodes['Фото'], scale = box.width / 108;
    const expected = { x: box.x + 24 * scale, y: box.y + 6 * scale, width: 60 * scale, height: 60 * scale };
    const pixel = (x, y) => [...data.slice((Math.round(y) * image.width + Math.round(x)) * 4,
      (Math.round(y) * image.width + Math.round(x)) * 4 + 3)];
    const ring = (rgb) => rgb.length === 3 && Math.max(...rgb.map((v, c) => Math.abs(v - [40, 100, 75][c]))) <= 65;
    const x0 = expected.x * rasterScale, y0 = expected.y * rasterScale;
    const width = expected.width * rasterScale, height = expected.height * rasterScale, xs = [], ys = [];
    for (let x = Math.floor(x0 - rasterScale); x <= Math.ceil(x0 + width + rasterScale); x++) {
      if ([.35, .5, .65].filter((t) => ring(pixel(x, y0 + height * t))).length >= 2) xs.push(x);
    }
    for (let y = Math.floor(y0 - rasterScale); y <= Math.ceil(y0 + height + rasterScale); y++) {
      if ([.35, .5, .65].filter((t) => ring(pixel(x0 + width * t, y))).length >= 2) ys.push(y);
    }
    let greenPhotoPixels = 0;
    for (let y = Math.ceil(y0 + height * .22); y < y0 + height * .78; y++) {
      for (let x = Math.ceil(x0 + width * .22); x < x0 + width * .78; x++) {
        const [r, g, b] = pixel(x, y);
        if (g > r + 15 && g > b + 5) greenPhotoPixels++;
      }
    }
    const paintedAvatarCssRect = xs.length && ys.length ? {
      x: Math.min(...xs) / rasterScale, y: Math.min(...ys) / rasterScale,
      width: (Math.max(...xs) - Math.min(...xs) + 1) / rasterScale,
      height: (Math.max(...ys) - Math.min(...ys) + 1) / rasterScale } : null;
    return { observed: 'unselected direct-ancestor real-photo avatar', imageWidth: image.width, imageHeight: image.height,
      rasterScale, expectedAvatarCssRect: expected, paintedAvatarCssRect, greenPhotoPixels,
      rasterToleranceCssPx: 1.5, physicalMillimetersVerified: false };
  }, { base64: png.toString('base64'), state: entry.state });
  const rect = measured.paintedAvatarCssRect;
  const matches = rect && measured.greenPhotoPixels > 0 && ['x', 'y', 'width', 'height'].every((dimension) =>
    Math.abs(rect[dimension] - measured.expectedAvatarCssRect[dimension]) <= measured.rasterToleranceCssPx);
  entry.paintStatus = matches ? 'passed-with-raster-tolerance' : 'unverified';
  entry.paint = measured;
  await fs.writeFile(path.join(output, `${entry.state.title}-paint.json`), JSON.stringify(measured, null, 2));
  // Pixel quantization can straddle 15.12px; only the semantic-derived nominal
  // size is an exact minimum assertion. This evidence is not a ruler reading.
  return matches;
}

async function desktopZoom(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const unchanged = await history(page, seeded);
  const browserBefore = await browserZoomState(page);
  const original = await capture(page, seeded, `${label}-ctrl-wheel-100-before`);
  const focal = center(original.nodes['Фокус']);
  await controlWheel(page, focal, -1000); // Linear 5 percentage points per 100 physical wheel pixels.
  assert.equal(await zoomPercent(page), 150, 'A real Ctrl+wheel did not produce the engine PointerScaleEvent zoom.');
  const scaled = await assertNodeScale(page, 'Фокус', 150);
  const scaledCenter = center(scaled);
  assert.ok(Math.abs(scaledCenter.x - focal.x) <= 2 && Math.abs(scaledCenter.y - focal.y) <= 2,
    `Ctrl+wheel lost the content under its focal point with available scroll bounds: ${JSON.stringify({ focal, scaledCenter })}`);
  const nativeWheel = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
  assert.ok(nativeWheel.trusted && nativeWheel.ctrl && nativeWheel.prevented,
    `Zoom did not own the genuine browser Ctrl+wheel event: ${JSON.stringify(nativeWheel)}`);
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Ctrl+wheel zoomed/scrolled the browser instead of only the tree.');
  await capture(page, seeded, `${label}-ctrl-wheel-150-after`);
  await assertNoGestureSelection(page);
  // Place three complete scaled generations inside the viewport. Flutter clips
  // semantic bounds at the scene edge; clipped boxes are not movement witnesses.
  const mainFocal = portrait ? focal.x : focal.y;
  const desiredMain = portrait ? page.viewportSize().width / 2 + 16 :
    ((await canvasTop(page)) + page.viewportSize().height - 16) / 2 + 16;
  await page.mouse.move(focal.x, focal.y);
  await page.mouse.down({ button: 'middle' });
  await page.mouse.move(focal.x + (portrait ? desiredMain - mainFocal : 0),
    focal.y + (portrait ? 0 : desiredMain - mainFocal), { steps: 10 });
  await page.mouse.up({ button: 'middle' });
  await settle(page);
  await wheelOwnership(page, seeded, `${label}-150-percent`, portrait, 3, 32);
  const middle = await middleCanvasDrag(page, seeded, `${label}-150-percent`, { travel: { x: -64, y: -52 } });
  const movement = middle.movements['Фокус'];
  // The rigid middle translation must not turn ordinary cross-axis wheel input
  // into whole-canvas movement, including after a zoom and whole-canvas pan.
  const ordinaryCross = await crossWheel(page, seeded, portrait, 3, 24, `${label}-150-percent-independent-cross-wheel`);
  await crossWheel(page, seeded, portrait, 3, -ordinaryCross.appliedDelta, `${label}-150-percent-cross-wheel-restored`);
  // The primary drag uses the same physical-travel contract, without scaling deltas twice.
  const primaryBefore = await snapshot(page, seeded, `${label}-zoom-primary-before`);
  await fs.writeFile(path.join(output, `${label}-zoom-primary-before.json`), JSON.stringify(primaryBefore, null, 2));
  const primaryPoint = center(primaryBefore.nodes['Фокус']);
  const rawPrimaryBefore = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => elements.map((element) => ({
    label: element.getAttribute('aria-label'), box: element.getBoundingClientRect().toJSON(),
    selected: element.getAttribute('aria-selected'), pressed: element.getAttribute('aria-pressed'),
  })));
  const semanticAncestors = () => node(page, 'Мать').evaluate((element) => {
    const ancestors = [];
    for (let current = element; current && ancestors.length < 16; current = current.parentElement) {
      const style = getComputedStyle(current), box = current.getBoundingClientRect();
      ancestors.push({ tag: current.tagName, id: current.id, role: current.getAttribute('role'),
        attributes: Object.fromEntries([...current.attributes].map((attribute) => [attribute.name, attribute.value])),
        box: box.toJSON(), scrollTop: current.scrollTop, scrollLeft: current.scrollLeft,
        clientWidth: current.clientWidth, clientHeight: current.clientHeight,
        scrollWidth: current.scrollWidth, scrollHeight: current.scrollHeight,
        style: { transform: style.transform, overflow: style.overflow, overflowX: style.overflowX,
          overflowY: style.overflowY, position: style.position, top: style.top, left: style.left },
        children: [...current.children].map((child) => ({ tag: child.tagName, id: child.id,
          role: child.getAttribute('role'), style: child.getAttribute('style') })).slice(0, 20) });
    }
    return { ancestors, activeElement: { tag: document.activeElement?.tagName, id: document.activeElement?.id },
      documentScroll: { x: scrollX, y: scrollY } };
  });
  const ancestorsBefore = await semanticAncestors();
  const primaryEventStart = await page.evaluate(() => window.__canvasPrimaryEvents.length);
  await page.mouse.move(primaryPoint.x, primaryPoint.y);
  await page.mouse.down();
  await page.mouse.move(primaryPoint.x - 70, primaryPoint.y, { steps: 12 });
  // Observe held-pointer travel, before release can add legitimate fling inertia.
  await sleep(180);
  const primaryAfter = await snapshot(page, seeded, `${label}-zoom-primary-held`);
  await fs.writeFile(path.join(output, `${label}-zoom-primary-held.json`), JSON.stringify(primaryAfter, null, 2));
  await page.screenshot({ path: path.join(output, `${label}-zoom-primary-held.png`), animations: 'disabled' });
  const rawPrimaryAfter = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => elements.map((element) => ({
    label: element.getAttribute('aria-label'), box: element.getBoundingClientRect().toJSON(),
    selected: element.getAttribute('aria-selected'), pressed: element.getAttribute('aria-pressed'),
  })));
  const primaryEvents = await page.evaluate((start) => window.__canvasPrimaryEvents.slice(start), primaryEventStart);
  const primaryDeltas = Object.fromEntries(Object.keys(primaryBefore.nodes).filter((name) => primaryAfter.nodes[name]).map((name) =>
    [name, Object.fromEntries(['x', 'y', 'width', 'height'].map((axis) => [axis, round(primaryAfter.nodes[name][axis] - primaryBefore.nodes[name][axis])]))]));
  await fs.writeFile(path.join(output, `${label}-zoom-primary-diagnostics.json`), JSON.stringify({ selected: seeded.focusName,
    requestedInput: { start: primaryPoint, travel: { x: -70, y: 0 } }, events: primaryEvents, deltas: primaryDeltas,
    before: primaryBefore, held: primaryAfter, rawBefore: rawPrimaryBefore, rawHeld: rawPrimaryAfter,
    semanticAncestorsBefore: ancestorsBefore, semanticAncestorsHeld: await semanticAncestors() }, null, 2));
  const primaryDx = primaryAfter.nodes['Фокус'].x - primaryBefore.nodes['Фокус'].x;
  assert.ok(primaryDx <= -45 && primaryDx >= -75, `Primary drag at 150% lost physical travel (${primaryDx}px).`);
  assert.ok(Math.abs(primaryAfter.nodes['Фокус'].y - primaryBefore.nodes['Фокус'].y) <= 1.5);
  const primaryWitnesses = Object.keys(primaryBefore.nodes).filter((name) => primaryAfter.nodes[name] && primaryBefore.nodes[name].generation !== 3);
  assert.ok(new Set(primaryWitnesses.map((name) => primaryBefore.nodes[name].generation)).size >= 2,
    'Zoomed primary drag needs two independent non-hovered generation witnesses.');
  const cross = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  for (const name of primaryWitnesses) {
    assert.ok(Math.abs(primaryAfter.nodes[name][cross] - primaryBefore.nodes[name][cross]) <= 1.5,
      `Zoomed primary drag moved independent non-hovered row ${name} on ${cross}: ${primaryBefore.nodes[name][cross]} -> ${primaryAfter.nodes[name][cross]}.`);
    const mainTravel = primaryAfter.nodes['Фокус'][main] - primaryBefore.nodes['Фокус'][main];
    assert.ok(Math.abs(primaryAfter.nodes[name][main] - primaryBefore.nodes[name][main] - mainTravel) <= 1.5,
      `Zoomed primary drag lost consistent outer-axis travel (${name}).`);
  }
  await page.mouse.up();
  await settle(page);
  await independentPrimaryDrag(page, seeded, `${label}-150-percent`, portrait);
  // Biography and its text stay at physical 100%, outside the logical scene.
  await openBiography(page);
  const biographyBefore = await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).boundingBox();
  await zoomReset(page).click();
  await settle(page);
  const biographyAfter = await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).boundingBox();
  assert.deepEqual(biographyAfter, biographyBefore, 'Tree zoom scaled or displaced biography controls.');
  await closeBiography(page);
  assert.deepEqual(await browserZoomState(page), browserBefore);
  assert.deepEqual(await history(page, seeded), unchanged, 'Ctrl+wheel/panning/biography browsing wrote to the journal.');
  report.scenarios.push({ name: `${label}-real-ctrl-wheel-and-zoomed-physical-navigation`, focal,
    scaledCenter, nativeWheel, percent: 150, middleMovement: movement, ordinaryCross, primaryDx, primaryWitnesses,
    biographyControlsUnscaled: true, browserZoomUnchanged: true, historyUnchanged: true });
  console.log(`PASS: ${label} genuine Ctrl+wheel 150%, focal stability, no browser zoom, zoomed wheel/primary/native middle navigation.`);
}

async function touchSequence(cdp, type, points) {
  await cdp.send('Input.dispatchTouchEvent', { type,
    touchPoints: points.map((point, index) => ({ id: point.id ?? index + 1, x: point.x, y: point.y,
      radiusX: 3, radiusY: 3, force: 1 })) });
  await sleep(32);
}

async function pinch(page, cdp, focal, fromDistance, toDistance, remainingFinger = false) {
  const pair = (distance) => [{ id: 1, x: focal.x - distance / 2, y: focal.y },
    { id: 2, x: focal.x + distance / 2, y: focal.y }];
  await touchSequence(cdp, 'touchStart', pair(fromDistance));
  for (let step = 1; step <= 10; step++) {
    await touchSequence(cdp, 'touchMove', pair(fromDistance + (toDistance - fromDistance) * step / 10));
  }
  if (remainingFinger) {
    const [finger] = pair(toDistance);
    await touchSequence(cdp, 'touchEnd', [finger]);
    await settle(page);
    const before = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) =>
      elements.map((element) => ({ label: element.getAttribute('aria-label'), rect: element.getBoundingClientRect().toJSON() })));
    await touchSequence(cdp, 'touchMove', [{ ...finger, y: finger.y - 64 }]);
    await settle(page);
    const after = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) =>
      elements.map((element) => ({ label: element.getAttribute('aria-label'), rect: element.getBoundingClientRect().toJSON() })));
    assert.deepEqual(after, before, 'A remaining finger resumed scrolling before all pinch contacts lifted.');
  }
  await touchSequence(cdp, 'touchEnd', []);
  await settle(page);
}

async function mobileZoom(page, seeded, label) {
  await loadRoom(page, seeded);
  const unchanged = await history(page, seeded);
  const browserBefore = await browserZoomState(page);
  const original = await capture(page, seeded, `${label}-touch-100-before`);
  // Both actual touch contacts start on an unselected sibling, so accidental
  // node selection/long-press biography cannot hide behind the current selection.
  const target = Object.entries(original.nodes).filter(([name, box]) => name !== 'Фокус' && box.generation === 3)
    .sort(([, a], [, b]) => Math.abs(center(a).y - center(original.nodes['Фокус']).y) -
      Math.abs(center(b).y - center(original.nodes['Фокус']).y))[0];
  assert.ok(target, 'The mobile pinch fixture needs a visible, unselected sibling.');
  const focal = center(target[1]);
  const cdp = await page.context().newCDPSession(page);
  await pinch(page, cdp, focal, 40, 60, true);
  assert.equal(await zoomPercent(page), 150, 'Trusted two-contact expansion did not zoom the tree to 150%.');
  await assertNodeScale(page, target[0], 150);
  await assertNoGestureSelection(page);
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Two-finger expansion caused native browser zoom.');
  await capture(page, seeded, `${label}-trusted-pinch-expand-150`);
  const contractedFocal = center(await node(page, target[0]).boundingBox());
  await pinch(page, cdp, contractedFocal, 60, 44);
  assert.equal(await zoomPercent(page), 110, 'Trusted two-contact contraction did not reduce the tree to 110%.');
  await assertNodeScale(page, target[0], 110);
  await assertNoGestureSelection(page);
  const beforeDrag = await snapshot(page, seeded, `${label}-one-finger-before`);
  const point = center(beforeDrag.nodes['Фокус']);
  await touchSequence(cdp, 'touchStart', [{ ...point, id: 1 }]);
  for (let step = 1; step <= 10; step++) {
    await touchSequence(cdp, 'touchMove', [{ id: 1, x: point.x, y: point.y - 74 * step / 10 }]);
  }
  await sleep(180); // Stop the contact before release; don't measure a fling as drag travel.
  await touchSequence(cdp, 'touchEnd', []);
  const afterDrag = await capture(page, seeded, `${label}-one-finger-restored-110`);
  const dy = afterDrag.nodes['Фокус'].y - beforeDrag.nodes['Фокус'].y;
  assert.ok(dy < -25 && dy > -105, `One-finger dragging did not resume after all pinch contacts lifted (${dy}px).`);
  assert.ok(Math.abs(afterDrag.nodes['Фокус'].x - beforeDrag.nodes['Фокус'].x) <= 1.5);
  const otherRows = Object.keys(beforeDrag.nodes).filter((name) => beforeDrag.nodes[name].generation !== 3);
  stable(beforeDrag, afterDrag, otherRows, 'Restored one-finger drag moved another independent generation');
  const touchEvents = await page.evaluate(() => window.__canvasTouchEvents);
  assert.ok(touchEvents.some((event) => event.type === 'touchstart' && event.touches === 2 && event.trusted) &&
    touchEvents.some((event) => event.type === 'touchmove' && event.touches === 2 && event.trusted),
  'Pinch coverage did not generate trusted native browser events with two real contacts.');
  assert.ok(touchEvents.every((event) => event.trusted));
  assert.deepEqual(await browserZoomState(page), browserBefore);
  assert.deepEqual(await history(page, seeded), unchanged, 'Touch zoom/navigation wrote to the immutable journal.');
  await zoomReset(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 100);
  await cdp.detach();
  report.scenarios.push({ name: `${label}-trusted-two-contact-pinch-and-restored-one-finger-pan`, target: target[0],
    percentages: [100, 150, 110, 100], remainingFingerFrozen: true, oneFingerDy: dy,
    touchEvents, browserZoomUnchanged: true, noAccidentalSelectionOrBiography: true, historyUnchanged: true });
  console.log('PASS: mobile trusted two-contact expand/contract pinch; no browser zoom/taps/biography, remaining-contact freeze, one-finger navigation restored.');
}

async function pickerZoom(page, seeded, label, touch = false) {
  await loadRoom(page, seeded);
  const unchanged = await history(page, seeded);
  await zoomIn(page).click();
  await zoomIn(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 120);
  await openBiography(page, null, true);
  await page.getByRole('button', { name: 'Добавить родственника', exact: true }).click();
  const dialog = page.getByRole('alertdialog');
  await useExistingRelative(page);
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
  const cancel = page.getByRole('button', { name: 'Отмена выбора', exact: true });
  await cancel.waitFor();
  await settle(page);
  assert.equal(await zoomPercent(page), 100, 'The full-screen picker inherited the main tree zoom.');
  const before = await snapshot(page, seeded, `${label}-picker-zoom-before`);
  const candidate = Object.entries(before.nodes).filter(([name, box]) => /^Недат0[13579]$/.test(name) && box.generation === 3)
    .sort(([, a], [, b]) => Math.hypot(center(a).x - center(before.nodes['Фокус']).x,
      center(a).y - center(before.nodes['Фокус']).y) - Math.hypot(center(b).x - center(before.nodes['Фокус']).x,
      center(b).y - center(before.nodes['Фокус']).y))[0];
  assert.ok(candidate, 'The full-screen picker needs a visible valid sibling for gesture-tap isolation.');
  const focal = center(candidate[1]);
  if (touch) {
    const cdp = await page.context().newCDPSession(page);
    await pinch(page, cdp, focal, 40, 60, true);
    await cdp.detach();
  } else {
    await controlWheel(page, focal, -1000); // Linear 5 percentage points per 100 physical wheel pixels.
  }
  assert.equal(await zoomPercent(page), 150);
  await assertNodeScale(page, candidate[0], 150);
  assert.equal(await cancel.count(), 1, 'A pinch/Ctrl+wheel accidentally committed the graphical relative picker.');
  assert.equal(await dialog.count(), 0);
  await assertNoGestureSelection(page);
  await capture(page, seeded, `${label}-picker-independent-150-percent`);
  await cancel.click();
  await dialog.waitFor();
  // Modal semantics correctly hide the underlying tree until the dialog closes.
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(page);
  assert.equal(await zoomPercent(page), 120, 'Returning from the picker changed the main tree zoom.');
  await assertNodeScale(page, 'Фокус', 120);
  assert.deepEqual(await history(page, seeded), unchanged, 'Picker zoom/cancellation wrote to the journal.');
  report.scenarios.push({ name: `${label}-independent-fullscreen-picker-zoom`, mainPercent: 120, pickerPercent: 150,
    trustedPinch: touch, noAccidentalCommit: true, mainZoomPreserved: true, historyUnchanged: true });
}

async function unknownAvatarVisual(page, seeded) {
  await loadRoom(page, seeded);
  const box = await assertNodeScale(page, 'Без имени', 100);
  await capture(page, seeded, 'mobile-no-gender-legend-unknown-avatar');
  const png = await page.screenshot({ path: path.join(output, 'unknown-avatar-no-corner-badge.png'),
    clip: box, animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async (base64) => {
    const image = new Image();
    image.src = `data:image/png;base64,${base64}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const rgb = (x, y) => [...context.getImageData(x, y, 1, 1).data].slice(0, 3);
    const errors = [];
    for (let y = 51; y <= 64; y++) for (let x = 69; x <= 82; x++) {
      const right = rgb(x, y); const left = rgb(107 - x, y);
      errors.push(...right.map((channel, index) => Math.abs(channel - left[index])));
    }
    let centerGlyphPixels = 0;
    for (let y = 22; y < 50; y++) for (let x = 40; x < 68; x++) {
      if (rgb(x, y).every((channel, index) => Math.abs(channel - [104, 108, 101][index]) < 18)) centerGlyphPixels++;
    }
    return { cornerMeanAsymmetry: errors.reduce((sum, value) => sum + value, 0) / errors.length, centerGlyphPixels };
  }, png.toString('base64'));
  assert.ok(pixels.cornerMeanAsymmetry < 10, `Unknown-sex avatar still has a painted corner badge: ${JSON.stringify(pixels)}`);
  assert.ok(pixels.centerGlyphPixels > 30, 'Removing the unknown-sex badge also removed the central person fallback.');
  assert.doesNotMatch(await body(page), /(?:^|\n)\s*- text: (?:Мужчина|Женщина|Пол не указан)(?:\n|$)/);
  report.scenarios.push({ name: 'unknown-sex-no-corner-badge-central-person-fallback-and-no-legend', pixels });
}

// Unlike the broad canvas fixture, these small regressions retain EVERY fully
// visible card. Derive clipping from the rendered semantics scene/ancestors;
// fixed viewport margins would silently omit edge cards on a real phone.
async function branchSnapshot(page, seeded, title) {
  const measured = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => {
    const rect = (element) => {
      const r = element.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    };
    const intersect = (a, b) => {
      const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
      return { x, y, width: Math.min(a.x + a.width, b.x + b.width) - x,
        height: Math.min(a.y + a.height, b.y + b.height) - y };
    };
    const viewport = { x: 0, y: 0, width: innerWidth, height: innerHeight };
    let scene = elements[0]?.parentElement;
    while (scene && !elements.every((element) => scene.contains(element))) scene = scene.parentElement;
    while (scene && (rect(scene).width < 1 || rect(scene).height < 1)) scene = scene.parentElement;
    if (!scene) throw new Error('No rendered common ancestor for the tree cards.');
    const canvas = intersect(rect(scene), viewport);
    return { canvas, nodes: elements.map((element) => {
      let clip = canvas;
      for (let parent = element.parentElement; parent; parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        if (/(hidden|clip|scroll|auto)/.test(`${style.overflowX} ${style.overflowY}`)) {
          const bounds = rect(parent);
          if (bounds.width > 0 && bounds.height > 0) clip = intersect(clip, bounds);
        }
      }
      return { label: element.getAttribute('aria-label') || element.textContent || '', ...rect(element), clip };
    }) };
  });
  assert.ok(measured.canvas.width > 108 && measured.canvas.height > 108, 'Actual tree scene has no usable extent.');
  const extent = 108 * await zoomPercent(page) / 100;
  const nodes = {}, clips = {};
  for (const box of measured.nodes) {
    const name = box.label.replace(/^Выбрать /, '');
    const normalizeSemanticSpace = (value) => value.trim().replace(/\s+/g, ' ');
    const person = seeded.people.find((entry) => normalizeSemanticSpace(entry.name) === normalizeSemanticSpace(name));
    const clip = box.clip;
    if (!person || Math.abs(box.width - extent) > 1.5 || Math.abs(box.height - extent) > 1.5 ||
        box.x < clip.x - .5 || box.y < clip.y - .5 || box.x + box.width > clip.x + clip.width + .5 ||
        box.y + box.height > clip.y + clip.height + .5) continue;
    nodes[person.name] = { generation: person.generation, x: round(box.x), y: round(box.y),
      width: round(box.width), height: round(box.height) };
    clips[person.name] = Object.fromEntries(Object.entries(clip).map(([key, value]) => [key, round(value)]));
  }
  return { title, viewport: page.viewportSize(), canvas: measured.canvas, zoom: await zoomPercent(page), nodes, clips };
}

async function branchCapture(page, seeded, title) {
  const state = await branchSnapshot(page, seeded, title);
  await page.screenshot({ path: path.join(output, `${title}.png`), animations: 'disabled', scale: 'css' });
  await fs.writeFile(path.join(output, `${title}.json`), JSON.stringify(state, null, 2));
  return state;
}

async function halfSiblingStability(page, seeded, label, mobile) {
  await loadRoom(page, seeded);
  await assertNoGestureSelection(page, 'Ольга');
  const journal = await history(page, seeded);
  for (const percent of [100, 150]) {
    while (await zoomPercent(page) < percent) {
      await zoomIn(page).click();
      await settle(page);
    }
    const title = `${label}-${percent}`;
    // Toolbar zoom preserves the scene focal point, not the selected card. Pan
    // once BEFORE the baseline so both complete hit boxes fit the actual canvas.
    const scene = await branchSnapshot(page, seeded, `${title}-before-reveal`);
    const pair = await Promise.all(['Ольга', 'Анастасия'].map((name) => node(page, name).boundingBox()));
    assert.ok(pair.every(Boolean), 'The half-sibling semantics disappeared before viewport preparation.');
    const extent = 108 * percent / 100;
    const reveal = (axis, size) => {
      const start = Math.min(...pair.map((box) => box[axis]));
      const end = Math.max(...pair.map((box) => box[axis] + extent));
      const margin = 16 * percent / 100;
      return start < scene.canvas[axis] + margin ? start - scene.canvas[axis] - margin :
        Math.max(0, end - scene.canvas[axis] - scene.canvas[size] + margin);
    };
    const dx = reveal('x', 'width'), dy = reveal('y', 'height');
    if (dx || dy) {
      const point = center(pair[0]);
      await page.mouse.move(Math.min(scene.canvas.x + scene.canvas.width - 12, Math.max(scene.canvas.x + 12, point.x)),
        Math.min(scene.canvas.y + scene.canvas.height - 12, Math.max(scene.canvas.y + 12, point.y)));
      await page.mouse.wheel(dx, dy);
      await settle(page);
    }
    const baseline = await branchCapture(page, seeded, `${title}-initial-olga`);
    for (const name of ['Ольга', 'Анастасия']) assert.ok(baseline.nodes[name], `${title}: ${name} is clipped before testing.`);
    const changes = [], states = new Map([['Ольга', baseline]]);
    for (let cycle = 1; cycle <= 4; cycle++) {
      for (const name of ['Анастасия', 'Ольга']) {
        const box = await node(page, name).boundingBox();
        assert.ok(box, `${title}: ${name} has no actual pointer target.`);
        const point = center(box);
        if (mobile) await page.touchscreen.tap(point.x, point.y);
        else await page.mouse.click(point.x, point.y);
        await settle(page);
        await assertNoGestureSelection(page, name);
        const after = await branchSnapshot(page, seeded, `${title}-${cycle}-${name}`);
        changes.push({ cycle, selected: name, screenRects: after.nodes });
        if (states.has(name)) sameCurrentLayout(states.get(name), after, mobile, `${title}: half-sibling tap ${cycle}/${name}`);
        else states.set(name, after);
        if (cycle === 1 && name === 'Анастасия') await branchCapture(page, seeded, `${title}-anastasia`);
      }
    }
    await branchCapture(page, seeded, `${title}-after-four-cycles`);
    report.scenarios.push({ name: `${title}-separate-half-sibling-blocks-stable`, cycles: 4,
      input: mobile ? 'trusted touchscreen taps' : 'trusted mouse clicks', baseline, changes });
  }
  assert.deepEqual(await history(page, seeded), journal, 'Selection/zoom appended or changed immutable room history.');
}

async function hoverWithoutNodeTooltip(page, seeded) {
  await settle(page);
  const box = await node(page, 'Ольга').boundingBox();
  const portrait = page.viewportSize().width < page.viewportSize().height;
  // The generation legitimately highlights on hover. Establish that same band
  // BEFORE the baseline so the pixel delta isolates a forbidden node popup,
  // rather than rejecting the new, intentional .035-alpha lane highlight.
  await page.mouse.move(portrait ? box.x - 22 : box.x + box.width / 2,
    portrait ? box.y + box.height / 2 : box.y - 22);
  await sleep(180);
  const overlays = () => page.evaluate(() => [...document.querySelectorAll(`[role="tooltip"], [role="dialog"],
    flt-semantics[aria-live="polite"], flt-semantics[aria-live="assertive"]`)]
    .filter((element) => { const r = element.getBoundingClientRect(); return r.width && r.height; })
    .map((element) => ({ role: element.getAttribute('role'), text: element.getAttribute('aria-label') || element.textContent })));
  const before = { semantics: await body(page), overlays: await overlays() };
  const beforePng = await page.screenshot({ animations: 'disabled', scale: 'css' });
  const outsidePixels = (png, excluded) => page.evaluate(async ({ before, after, excluded }) => {
    const decode = async (base64) => {
      const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      return { width: image.width, height: image.height, rgba: context.getImageData(0, 0, image.width, image.height).data };
    };
    const a = await decode(before), b = await decode(after);
    let changedOutside = 0, newDarkOutside = 0;
    for (let y = 0; y < a.height; y++) for (let x = 0; x < a.width; x++) {
      if (x >= excluded.x - 10 && x <= excluded.x + excluded.width + 10 &&
          y >= excluded.y - 10 && y <= excluded.y + excluded.height + 10) continue;
      const index = (y * a.width + x) * 4;
      if (Math.max(...[0, 1, 2].map((channel) => Math.abs(a.rgba[index + channel] - b.rgba[index + channel]))) > 15) {
        changedOutside++;
        if ([0, 1, 2].every((channel) => b.rgba[index + channel] < 150)) newDarkOutside++;
      }
    }
    return { changedOutside, newDarkOutside };
  }, { before: beforePng.toString('base64'), after: png.toString('base64'), excluded });
  await page.mouse.move(box.x + box.width / 2, box.y + 36 * await zoomPercent(page) / 100);
  await sleep(1300); // Greater than Flutter's normal tooltip wait duration.
  assert.deepEqual(await overlays(), before.overlays, 'Hovering a node created a tooltip/window overlay.');
  assert.equal(await body(page), before.semantics, 'Node hover introduced transient name/tooltip semantics.');
  const nodePng = await page.screenshot({ path: path.join(output, 'desktop-node-hover-no-tooltip.png'), animations: 'disabled', scale: 'css' });
  const nodePixels = await outsidePixels(nodePng, box);
  assert.ok(nodePixels.changedOutside < 30, `Hover painted a transient overlay outside the node: ${JSON.stringify(nodePixels)}`);
  const toolbarBox = await zoomIn(page).boundingBox();
  await zoomIn(page).hover();
  await sleep(1300);
  const toolbarSemantics = await body(page);
  const toolbarOverlay = await overlays();
  const toolbarText = page.getByText('Увеличить масштаб', { exact: true });
  assert.ok(await page.getByRole('tooltip').count() || await toolbarText.isVisible().catch(() => false) ||
    toolbarOverlay.some((entry) => /Увеличить масштаб/.test(entry.text || '')) ||
    /(?:^|\n)\s*- (?:tooltip|text): Увеличить масштаб(?:\n|$)/.test(toolbarSemantics) ||
    await page.getByRole('button', { name: 'Увеличить масштаб Увеличить масштаб', exact: true }).count(),
  'The normal zoom toolbar tooltip no longer appears on hover.');
  assert.notEqual(toolbarSemantics, before.semantics, 'Toolbar hover produced no observable tooltip semantics.');
  const toolbarPng = await page.screenshot({ path: path.join(output, 'desktop-toolbar-hover-tooltip-kept.png'), animations: 'disabled', scale: 'css' });
  const toolbarPixels = await outsidePixels(toolbarPng, toolbarBox);
  assert.ok(toolbarPixels.newDarkOutside > 150, `Toolbar tooltip is not visibly painted: ${JSON.stringify(toolbarPixels)}`);
  report.scenarios.push({ name: 'node-hover-no-transient-tooltip-toolbar-tooltip-kept', before,
    nodePixels, toolbarPixels, toolbarOverlay, toolbarSemantics });
  await settle(page);
}

async function kinshipPixels(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  const state = await branchCapture(page, seeded, `${label}-cousin-nephew-niece`);
  const boxes = state.nodes;
  const targets = ['Кузен', 'Племянник', 'Племянница'];
  for (const name of [...targets, 'Фокус', 'Отец', 'Мать', 'Общий предок', 'Родитель кузена', 'Полный брат', 'Неполная сестра']) {
    assert.ok(boxes[name], `${label}: ${name} must be fully visible for uncontaminated screenshot samples.`);
  }
  const png = await page.screenshot({ path: path.join(output, `${label}-painted-kinship-evidence.png`), animations: 'disabled', scale: 'css' });
  const connections = [
    { parent: 'Отец', child: 'Фокус', rgb: [174, 116, 44], muted: false, ancestor: true },
    { parent: 'Мать', child: 'Фокус', rgb: [51, 139, 100], muted: false, ancestor: true },
    { parent: 'Общий предок', child: 'Отец', rgb: [138, 144, 135], muted: false, ancestor: true },
    { parent: 'Полный брат', child: 'Племянник', rgb: [174, 116, 44], muted: true },
    { parent: 'Неполная сестра', child: 'Племянница', rgb: [51, 139, 100], muted: true },
    { parent: 'Родитель кузена', child: 'Кузен', rgb: [138, 144, 135], muted: true },
  ];
  const pixels = await page.evaluate(async ({ base64, boxes, targets, portrait, connections }) => {
    const image = new Image();
    image.src = `data:image/png;base64,${base64}`;
    await image.decode();
    const canvas = document.createElement('canvas');
    canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d');
    context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const background = pixel(2, image.height - 5);
    const neutral = [104, 108, 101];
    const blend = (rgb, alpha) => rgb.map((value, index) => value * alpha + background[index] * (1 - alpha));
    const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
    const patch = (name, points) => points.map(([x, y]) => pixel(boxes[name].x + x, boxes[name].y + y));
    // Identical real PNGs isolate photo filtering from initials, sex, or text.
    const photoPoints = [];
    for (let y = 18; y < 53; y += 3) for (let x = 37; x < 72; x += 3) photoPoints.push([x, y]);
    const photos = Object.fromEntries(targets.map((name) => [name, patch(name, photoPoints)]));
    const cousin = photos['Кузен'];
    const styles = targets.map((name) => {
      const photo = photos[name];
      const block = pixel(boxes[name].x + 2, boxes[name].y + 30);
      return { name, block, expectedBlock: blend([133, 136, 74], .14),
        photoDifferenceFromCousin: mean(photo.flatMap((rgb, index) => rgb.map((channel, c) => Math.abs(channel - cousin[index][c])))),
        coloredPhotoPixels: photo.filter((rgb) => Math.max(...rgb) - Math.min(...rgb) > 8).length };
    });
    const lines = connections.map((link) => {
      const parent = boxes[link.parent], child = boxes[link.child];
      const from = portrait ? { x: parent.x + parent.width / 2 + 30, y: parent.y + 36 } :
        { x: parent.x + parent.width / 2, y: parent.y + 66 };
      const to = link.ancestor ? (portrait ? { x: child.x + child.width / 2 - 30, y: child.y + 36 } :
        { x: child.x + child.width / 2, y: child.y + 6 }) :
        (portrait ? { x: child.x - 6, y: child.y + child.height / 2 } :
          { x: child.x + child.width / 2, y: child.y - 6 });
      const distance = Math.abs(portrait ? to.x - from.x : to.y - from.y);
      const bend = Math.max(24, distance * .48);
      const first = portrait ? { x: from.x + bend, y: from.y } : { x: from.x, y: from.y + bend };
      const second = portrait ? { x: to.x - bend, y: to.y } : { x: to.x, y: to.y - bend };
      const color = link.muted ? neutral.map((value, index) => Math.trunc(value + (link.rgb[index] - value) * .35)) : link.rgb;
      const expected = blend(color, link.muted ? .40 : .60);
      const samples = [];
      for (const t of [.30, .35, .40, .45, .50, .55, .60, .65, .70]) {
        const u = 1 - t;
        const x = u ** 3 * from.x + 3 * u ** 2 * t * first.x + 3 * u * t ** 2 * second.x + t ** 3 * to.x;
        const y = u ** 3 * from.y + 3 * u ** 2 * t * first.y + 3 * u * t ** 2 * second.y + t ** 3 * to.y;
        // Exclude EVERY block/card, rather than treating a photo or tinted block
        // as evidence that its connection was drawn. Samples stay in clean gaps.
        if (Object.values(boxes).some((box) => x >= box.x - 9 && x <= box.x + box.width + 9 &&
          y >= box.y - 9 && y <= box.y + box.height + 9)) continue;
        let best = { error: Infinity };
        for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
          const observed = pixel(x + dx, y + dy);
          const error = Math.max(...observed.map((value, index) => Math.abs(value - expected[index])));
          if (error < best.error) best = { error, observed };
        }
        samples.push({ t, x, y, ...best });
      }
      return { ...link, from, to, expected, samples, matching: samples.filter((sample) => sample.error <= 8).length };
    });
    return { background, styles, lines };
  }, { base64: png.toString('base64'), boxes, targets, portrait, connections });
  report.scenarios.push({ name: `${label}-full-half-sibling-children-match-real-cousin-style-and-visible-muted-links`, pixels });
  await fs.writeFile(path.join(output, `${label}-kinship-pixels.json`), JSON.stringify(pixels, null, 2));
  for (const style of pixels.styles) {
    assert.ok(style.photoDifferenceFromCousin < 4, `${style.name} photo differs from the same cousin avatar: ${JSON.stringify(style)}`);
    assert.ok(style.coloredPhotoPixels > 20, `${style.name} is distant grey, not muted cousin color.`);
    assert.ok(style.block.every((value, index) => Math.abs(value - style.expectedBlock[index]) <= 3),
      `${style.name} uses a distant-grey block instead of the cousin block: ${JSON.stringify(style)}`);
  }
  for (const line of pixels.lines) assert.ok(line.matching >= 3,
    `${label}: missing/wrong-alpha ${line.muted ? 'muted' : 'normal'} ${line.parent}→${line.child} line: ${JSON.stringify(line)}`);
  assert.deepEqual(await history(page, seeded), journal, 'Pure kinship rendering changed the room journal.');
}

async function colorfulFixturePhoto(browser) {
  // Resize the real asset on a separate about:blank page, not in the app. This
  // keeps dozens of identical journal photos below real localStorage quotas.
  const page = await browser.newPage();
  try {
    const source = `data:image/png;base64,${(await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'))).toString('base64')}`;
    return await page.evaluate(async (source) => {
      const image = new Image(); image.src = source; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = 128; canvas.height = 128;
      canvas.getContext('2d').drawImage(image, 0, 0, 128, 128);
      return canvas.toDataURL('image/png');
    }, source);
  } finally {
    await page.close();
  }
}

async function chooseTrunk(page, title) {
  await page.getByRole('button', { name: /^Линия дерева:/ }).click();
  await page.getByRole('menuitem', { name: new RegExp(`^${title}(?:\\s|$)`) }).click();
  await settle(page);
  const picker = page.getByRole('button', { name: /^Линия дерева:/ });
  assert.match(await picker.getAttribute('aria-label') || await picker.innerText(), new RegExp(title));
}

// Runs against a captured real frame, not a model/testing hook. Shared by the
// kinship and trunk-mode checks so their route/color/occlusion rules agree.
async function parentCurvePixels({ base64, boxes, connections, portrait }) {
  const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
  const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
  const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
  const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
  const background = pixel(2, image.height - 5);
  const blend = (rgb, alpha) => rgb.map((value, index) => value * alpha + background[index] * (1 - alpha));
  const scale = Object.values(boxes)[0].width / 108;
  const curves = connections.map((link) => {
    const parent = boxes[link.parent], child = boxes[link.target];
    const cross = portrait ? 'y' : 'x', extent = portrait ? 'height' : 'width';
    const members = (link.members || [link.target]).map((id) => boxes[id]);
    const blockCross = (Math.min(...members.map((box) => box[cross])) +
      Math.max(...members.map((box) => box[cross] + box[extent]))) / 2;
    const from = portrait ? { x: parent.x + parent.width / 2 + 30 * scale, y: parent.y + 36 * scale } :
      { x: parent.x + parent.width / 2, y: parent.y + 66 * scale };
    const to = link.endpoint === 'avatar' ? (portrait ? { x: child.x + child.width / 2 - 30 * scale, y: child.y + 36 * scale } :
      { x: child.x + child.width / 2, y: child.y + 6 * scale }) :
      (portrait ? { x: child.x - 6 * scale, y: blockCross } : { x: blockCross, y: child.y - 6 * scale });
    const bend = Math.max(24 * scale, Math.abs(portrait ? to.x - from.x : to.y - from.y) * .48);
    const first = portrait ? { x: from.x + bend, y: from.y } : { x: from.x, y: from.y + bend };
    const second = portrait ? { x: to.x - bend, y: to.y } : { x: to.x, y: to.y - bend };
    const at = (t) => {
      const u = 1 - t;
      return { x: u ** 3 * from.x + 3 * u ** 2 * t * first.x + 3 * u * t ** 2 * second.x + t ** 3 * to.x,
        y: u ** 3 * from.y + 3 * u ** 2 * t * first.y + 3 * u * t ** 2 * second.y + t ** 3 * to.y };
    };
    return { ...link, from, to, at,
      expected: blend(link.muted ? [104, 108, 101].map((channel, c) => Math.trunc(channel + (link.rgb[c] - channel) * .35)) : link.rgb,
        link.muted ? .40 : .60) };
  });
  return curves.map(({ at, ...link }, index) => {
    const samples = [];
    for (let step = 16; step <= 84; step += 2) {
      const t = step / 100, { x, y } = at(t);
      if (x < 2 || y < 2 || x > image.width - 3 || y > image.height - 3) continue;
      // A card/wash or another coincident parent curve is not proof of this edge.
      if (Object.values(boxes).some((box) => x >= box.x - 9 * scale && x <= box.x + box.width + 9 * scale &&
        y >= box.y - 9 * scale && y <= box.y + box.height + 9 * scale)) continue;
      if (curves.some((curve, other) => other !== index && curve.present !== false &&
        Array.from({ length: 101 }, (_, step) => curve.at(step / 100))
        .some((p) => Math.hypot(p.x - x, p.y - y) < 4))) continue;
      let best = { error: Infinity };
      for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
        const observed = pixel(x + dx, y + dy);
        const error = Math.max(...observed.map((channel, c) => Math.abs(channel - link.expected[c])));
        if (error < best.error) best = { error, observed };
      }
      samples.push({ t, x, y, ...best });
    }
    return { ...link, samples, matching: samples.filter((sample) => sample.error <= 9).length };
  });
}

async function stepParentKinshipFrame(page, seeded, title, portrait, focus) {
  await assertNoGestureSelection(page, seeded.names[focus]);
  const state = await branchCapture(page, seeded, title), boxes = {};
  for (const person of seeded.people) {
    assert.ok(state.nodes[person.name], `${title}: ${person.name} is clipped; the full row must be measured.`);
    boxes[person.id] = state.nodes[person.name];
  }
  const row = order(state, 0, portrait), axis = portrait ? 'y' : 'x';
  const relevant = ['natalia', 'veronika', 'oleg', 'sergey'].map((id) => seeded.names[id]);
  const indices = relevant.map((name) => row.indexOf(name));
  const cluster = row.slice(Math.min(...indices), Math.max(...indices) + 1);
  const stepParent = focus === 'root' ? 'sergey' : 'oleg';
  const normalFather = focus === 'root' ? 'oleg' : 'sergey';
  const connections = [
    { parent: 'natalia', target: 'root' }, { parent: 'oleg', target: 'root' },
    { parent: 'natalia', target: 'nastyusha' }, { parent: 'sergey', target: 'nastyusha' },
    { parent: 'veronika', target: 'nikita' },
  ].map((link) => ({ ...link, endpoint: link.target === focus ? 'avatar' : 'block',
    muted: link.parent === stepParent || link.target === 'nikita',
    rgb: ['oleg', 'sergey'].includes(link.parent) ? [174, 116, 44] : [51, 139, 100] }));
  const png = await fs.readFile(path.join(output, `${title}.png`));
  const pixels = await page.evaluate(async ({ base64, boxes, normalFather, stepParent }) => {
    const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const background = pixel(2, image.height - 5);
    const blend = (rgb, alpha) => rgb.map((value, c) => value * alpha + background[c] * (1 - alpha));
    const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
    const ids = [normalFather, stepParent, 'nikita', 'elena'];
    const photos = Object.fromEntries(ids.map((id) => {
      const samples = [];
      for (let y = 18; y < 53; y += 3) for (let x = 37; x < 72; x += 3) {
        samples.push(pixel(boxes[id].x + x, boxes[id].y + y));
      }
      return [id, samples];
    }));
    const chroma = (id) => mean(photos[id].map((rgb) => Math.max(...rgb) - Math.min(...rgb)));
    const normalChroma = chroma(normalFather);
    // Reuse kinshipFollowup's real cousin palette/filter and clean wash patches.
    const styles = ids.map((id) => {
      const saturation = id === normalFather ? 1 : id === 'elena' ? 0 : .35;
      const box = boxes[id], blockSamples = [];
      for (const x of [1, 3, 8, 12, 16]) for (const y of [18, 24, 30, 42, 48, 54]) {
        blockSamples.push(pixel(box.x + x, box.y + y));
      }
      const block = [0, 1, 2].map((c) => blockSamples.map((rgb) => rgb[c]).sort((a, b) => a - b)[15]);
      const rgb = id === 'elena' ? [40, 100, 75] : [135, 88, 38];
      const grey = rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
      return { id, saturation, chromaRatio: chroma(id) / normalChroma, block, blockSamples,
        photoDifferenceFromCousin: mean(photos[id].flatMap((rgb, index) =>
          rgb.map((channel, c) => Math.abs(channel - photos.nikita[index][c])))),
        ring: [[25, 30], [25, 36], [26, 42], [81, 30], [82, 36]].map(([x, y]) => pixel(box.x + x, box.y + y)),
        expectedRing: rgb.map((channel) => grey * (1 - saturation) + channel * saturation),
        expectedBlock: blend(id === 'elena' ? [104, 108, 101] : [133, 136, 74], saturation === .35 ? .14 : .24) };
    });
    return { background, normalChroma, styles };
  }, { base64: png.toString('base64'), boxes, normalFather, stepParent });
  pixels.lines = await page.evaluate(parentCurvePixels, { base64: png.toString('base64'), boxes, connections, portrait });
  // Explicitly reject the bug's normal .60 edge, not merely a missing line.
  pixels.normalStepParentCandidate = (await page.evaluate(parentCurvePixels, {
    base64: png.toString('base64'), boxes, portrait,
    connections: connections.map((link) => link.parent === stepParent ? { ...link, muted: false } : link),
  })).find((link) => link.parent === stepParent);
  await fs.writeFile(path.join(output, `${title}-pixels.json`), JSON.stringify(pixels, null, 2));
  report.scenarios.push({ name: title, focus, stepParent, state, parentRow: row, relevantCluster: cluster, pixels });
  assert.deepEqual([...cluster].sort(), [...relevant].sort(),
    `${title}: a distant sibling block intrudes between relevant parental family blocks: ${row.join(' / ')}.`);
  for (let index = 1; index < cluster.length; index++) assert.ok(
    state.nodes[cluster[index]][axis] - state.nodes[cluster[index - 1]][axis] <= 156 + 1.5,
    `${title}: relevant family blocks are not packed together (108px card + at most 48px block gap).`);
  for (const ids of [['natalia', 'veronika'], ['elena', 'stepan', 'roman']]) {
    const members = ids.map((id) => boxes[id]).sort((a, b) => a[axis] - b[axis]);
    for (let index = 1; index < members.length; index++) assert.ok(
      Math.abs(members[index][axis] - members[index - 1][axis] - 132) <= 1.5,
      `${title}: explicit sibling block ${ids.join('/')} was split.`);
  }
  assert.ok(pixels.normalChroma > 20, `${title}: the identical colorful PNG did not paint.`);
  for (const style of pixels.styles) {
    assert.ok(Math.abs(style.chromaRatio - style.saturation) < .07,
      `${title}: ${style.id} must use ${style.saturation === .35 ? 'cousin, not distant/normal' : 'control'} card style: ${JSON.stringify(style)}`);
    if (style.saturation === .35) assert.ok(style.photoDifferenceFromCousin < 4,
      `${title}: ${style.id} does not match the real cousin Nikita's photo filter.`);
    assert.ok(style.ring.every((rgb) => rgb.every((channel, c) => Math.abs(channel - style.expectedRing[c]) <= 6)),
      `${title}: ${style.id} has wrong card ring saturation.`);
    assert.ok(style.block.every((channel, c) => Math.abs(channel - style.expectedBlock[c]) <= 3),
      `${title}: ${style.id} has wrong existing olive/grey block wash: ${JSON.stringify(style)}`);
  }
  for (const link of pixels.lines) assert.ok(link.samples.length >= 3 && link.matching >= 3,
    `${title}: missing/wrong ${link.muted ? 'muted cousin .40' : 'normal .60'} ${link.parent}→${link.target} route: ${JSON.stringify(link)}`);
  assert.ok(pixels.normalStepParentCandidate.matching < 3,
    `${title}: the step-parent edge incorrectly uses normal .60 paint.`);
  return state;
}

async function stepParentKinship(page, seeded, label, portrait) {
  const journal = [...seeded.records].sort((a, b) => a.id.localeCompare(b.id));
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, `${label}: loaded complete journal differs from the fixture.`);
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  await chooseTrunk(page, 'Обе линии');
  await setTreeZoom(page, 100);
  await alignAll(page).click();
  await settle(page);
  const cold = await stepParentKinshipFrame(page, seeded, `${label}-initial-olga`, portrait, 'root');
  await toolbarSearchBrowse(page, seeded, `${label}-select-nastyusha`, 'Настюша Сергеевна', false, 'Настюша');
  await stepParentKinshipFrame(page, seeded, `${label}-selected-nastyusha`, portrait, 'nastyusha');
  assert.deepEqual(await history(page, seeded), journal, `${label}: selecting Nastyusha changed the complete journal.`);
  await toolbarSearchBrowse(page, seeded, `${label}-return-olga`, 'Ольга Олеговна', false, 'Ольга');
  const restored = await stepParentKinshipFrame(page, seeded, `${label}-returned-olga`, portrait, 'root');
  sameCurrentLayout(cold, restored, portrait, `${label}: returning to Olga changed family geometry`);
  const after = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(after, null, 2));
  assert.deepEqual(after, journal, `${label}: view-only browsing changed the complete immutable journal.`);
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, `${label}: reload changed the complete journal.`);
  await alignAll(page).click();
  await settle(page);
  const reloaded = await stepParentKinshipFrame(page, seeded, `${label}-reloaded-olga`, portrait, 'root');
  sameCurrentLayout(cold, reloaded, portrait, `${label}: reload changed the same-focus family layout`);
  assert.deepEqual(await history(page, seeded), journal, `${label}: passive reload inspection changed the complete journal.`);
  report.scenarios.push({ name: `${label}-summary`, wholeJournalUnchanged: true, reloadUnchanged: true,
    immutableOperations: journal.length, selection: ['Ольга', 'Настюша', 'Ольга'],
    limitation: 'Finite local desktop rendering only; no public-network synchronization or arbitrary graph coverage.' });
}

async function kinshipFollowup(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  const cousinIds = ['cousin', 'uncle', 'aunt', 'grand-aunt', 'higher-aunt', 'nephew', 'niece', 'half-father', 'half-mother'];
  const partnerIds = ['partner-a', 'partner-b', 'partner-c'];
  const distantIds = ['partner-father', 'partner-mother', 'partner-sibling'];
  const styles = seeded.people.map((person) => ({ ...person,
    saturation: cousinIds.includes(person.id) ? .35 : distantIds.includes(person.id) ? 0 : 1,
    distantBlock: distantIds.includes(person.id) || partnerIds.includes(person.id),
  }));
  const connections = [
    // Full siblings deliberately share the existing selected-avatar endpoint;
    // separate half-sibling blocks terminate at their own whole-block centers.
    { parent: 'father', target: 'root', endpoint: 'avatar' },
    { parent: 'mother', target: 'root', endpoint: 'avatar' },
    { parent: 'mother', target: 'maternal-half', endpoint: 'block' },
    { parent: 'half-father', target: 'maternal-half', endpoint: 'block', muted: true },
    { parent: 'father', target: 'paternal-half', endpoint: 'block' },
    { parent: 'half-mother', target: 'paternal-half', endpoint: 'block', muted: true },
    // Retain the prior normal and muted ancestry/descendant link coverage.
    { parent: 'great', target: 'grandparent', endpoint: 'avatar' },
    { parent: 'great', target: 'ancestor-aunt', endpoint: 'avatar' },
    { parent: 'uncle', target: 'cousin', endpoint: 'block', muted: true },
    { parent: 'brother', target: 'nephew', endpoint: 'block', muted: true },
    { parent: 'maternal-half', target: 'niece', endpoint: 'block', muted: true },
  ].map((link) => ({ ...link, rgb: { male: [174, 116, 44], female: [51, 139, 100], unknown: [138, 144, 135] }[
    seeded.people.find((person) => person.id === link.parent).sex] }));
  for (const [mode, title] of [['both', 'Обе линии'], ['father', 'По отцу'], ['mother', 'По матери']]) {
    if (mode !== 'both') await chooseTrunk(page, title);
    const artifact = `${label}-${mode}`;
    const state = await branchCapture(page, seeded, `${artifact}-whole-tree`);
    const boxes = {};
    for (const person of seeded.people) {
      assert.ok(state.nodes[person.name], `${artifact}: ${person.name} is clipped; do not sample hidden cards.`);
      boxes[person.id] = state.nodes[person.name];
    }
    const cross = portrait ? 'y' : 'x';
    for (const [a, b] of [['root', 'brother'], ['partner-a', 'partner-sibling']]) {
      assert.ok(Math.abs(Math.abs(boxes[a][cross] - boxes[b][cross]) - 132) <= 1.5,
        `${artifact}: ${a}/${b} no longer form the fixture's real full-sibling block.`);
    }
    const png = await page.screenshot({ path: path.join(output, `${artifact}-painted-evidence.png`),
      animations: 'disabled', scale: 'css' });
    const pixels = await page.evaluate(async ({ base64, boxes, styles, connections, portrait }) => {
      const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
      const background = pixel(2, image.height - 5);
      const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
      const difference = (a, b) => mean(a.flatMap((rgb, index) => rgb.map((channel, c) => Math.abs(channel - b[index][c]))));
      const blend = (rgb, alpha) => rgb.map((value, index) => value * alpha + background[index] * (1 - alpha));
      const desaturate = (rgb, saturation) => {
        const grey = rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
        return rgb.map((channel) => grey * (1 - saturation) + channel * saturation);
      };
      const photoPoints = [];
      for (let y = 18; y < 53; y += 3) for (let x = 37; x < 72; x += 3) photoPoints.push([x, y]);
      const photos = Object.fromEntries(styles.map(({ id }) => [id,
        photoPoints.map(([x, y]) => pixel(boxes[id].x + x, boxes[id].y + y))]));
      const normalChroma = mean(photos.root.map((rgb) => Math.max(...rgb) - Math.min(...rgb)));
      const nodes = styles.map((style) => {
        const { id, sex, saturation, distantBlock } = style, box = boxes[id];
        const photo = photos[id];
        const ringColor = desaturate({ male: [135, 88, 38], female: [40, 100, 75], unknown: [104, 108, 101] }[sex], saturation);
        const ring = [[25, 30], [25, 36], [26, 42], [81, 30], [82, 36]].map(([x, y]) => pixel(box.x + x, box.y + y));
        let nameInkPixels = 0;
        for (let y = 72; y < 101; y++) for (let x = 8; x < 100; x++) {
          if (pixel(box.x + x, box.y + y).every((channel, c) => Math.abs(channel - ringColor[c]) <= 6)) nameInkPixels++;
        }
        // Incoming curves can cross a transparent card's left edge. A broad
        // margin patch identifies the actual wash without accepting stroke ink.
        const blockSamples = [];
        for (const x of [1, 3, 8, 12, 16]) for (const y of [18, 24, 30, 42, 48, 54]) blockSamples.push(pixel(box.x + x, box.y + y));
        const block = [0, 1, 2].map((c) => blockSamples.map((rgb) => rgb[c]).sort((a, b) => a - b)[Math.floor(blockSamples.length / 2)]);
        return { id, name: style.name, saturation,
          reference: saturation === 1 ? 'root' : saturation === .35 ? 'cousin' : 'partner-sibling',
          photoDifference: difference(photo, photos[saturation === 1 ? 'root' : saturation === .35 ? 'cousin' : 'partner-sibling']),
          chroma: mean(photo.map((rgb) => Math.max(...rgb) - Math.min(...rgb))),
          chromaRatio: mean(photo.map((rgb) => Math.max(...rgb) - Math.min(...rgb))) / normalChroma,
          ring, expectedRing: ringColor, nameInkPixels, block, blockSamples,
          // Mixed full-sibling blocks retain the strongest member's wash:
          // uncle/grand-aunt/higher-aunt share normal ancestors' blocks, and
          // partner-a's node stays colored while its sibling block stays grey.
          expectedBlock: blend(distantBlock ? [104, 108, 101] : [133, 136, 74],
            saturation === .35 && !['uncle', 'grand-aunt', 'higher-aunt'].includes(id) ? .14 : .24),
          distantBlock };
      });
      const partner = boxes['partner-a'], sibling = boxes['partner-sibling'];
      const between = portrait ? { x: partner.x + 2, y: (partner.y + sibling.y + partner.height) / 2 } :
        { x: (partner.x + sibling.x + partner.width) / 2, y: partner.y + 30 };
      return { background, normalChroma, nodes,
        partnerBlockBridge: { point: between, observed: pixel(between.x, between.y), expected: blend([104, 108, 101], .24) } };
    }, { base64: png.toString('base64'), boxes, styles, portrait });
    pixels.lines = await page.evaluate(parentCurvePixels, { base64: png.toString('base64'), boxes, connections, portrait });
    await fs.writeFile(path.join(output, `${artifact}-pixels.json`), JSON.stringify(pixels, null, 2));
    report.scenarios.push({ name: `${artifact}-ancestor-sibling-context-both-sibling-parents-node-only-partners`,
      mode, portrait, fixture: { room: seeded.room, people: seeded.people.length, immutableOperations: journal.length,
        photo: 'identical real tree-mark PNG, resized to 128px before journal seeding' }, state, pixels });
    assert.ok(pixels.normalChroma > 20, `${artifact}: the identical colorful PNG did not actually paint.`);
    for (const style of pixels.nodes) {
      assert.ok(style.photoDifference < 6, `${artifact}: ${style.name} photo does not match ${style.reference}: ${JSON.stringify(style)}`);
      assert.ok(Math.abs(style.chromaRatio - style.saturation) < .07,
        `${artifact}: ${style.name} has wrong real photo saturation: ${JSON.stringify(style)}`);
      assert.ok(style.ring.every((rgb) => rgb.every((channel, c) => Math.abs(channel - style.expectedRing[c]) <= 6)),
        `${artifact}: ${style.name} node ring has wrong full/context/grey color: ${JSON.stringify(style)}`);
      assert.ok(style.nameInkPixels >= 8, `${artifact}: ${style.name} name is not painted in its expected node color.`);
      if (style.id !== 'root') assert.ok(style.block.every((channel, c) => Math.abs(channel - style.expectedBlock[c]) <= 3),
        `${artifact}: ${style.name} changed the underlying ${style.distantBlock ? 'unrelated grey' : 'olive'} block wash: ${JSON.stringify(style)}`);
    }
    assert.ok(pixels.partnerBlockBridge.observed.every((channel, c) => Math.abs(channel - pixels.partnerBlockBridge.expected[c]) <= 3),
      `${artifact}: the partner's real full-sibling block was promoted out of its unrelated grey wash.`);
    for (const link of pixels.lines) assert.ok(link.matching >= 3,
      `${artifact}: missing/wrong-color ${link.parent}→${link.target} (${link.endpoint}) route: ${JSON.stringify(link)}`);
    assert.deepEqual(await history(page, seeded), journal, 'Kinship rendering or trunk browsing changed the immutable journal.');
    console.log(`PASS: ${artifact} ancestor siblings through higher generations, ancestor precedence, both full/half-sibling parents, three full-color co-parents with unrelated sibling/block still grey.`);
  }
}

const toolbarToggle = (page, expanded) => page.getByRole('button', {
  name: expanded ? 'Свернуть панель дерева' : 'Развернуть панель дерева', exact: true,
});
const trunkPicker = (page) => page.getByRole('button', { name: /^Линия дерева:/ });
const alignAll = (page) => page.getByRole('button', { name: /^Выровнять всё(?:\s|$)/ });

async function compactToolbarGeometry(page, label, portrait) {
  const controls = {};
  for (const [name, locator] of [['toggle', toolbarToggle(page, true)], ['mode', trunkPicker(page)], ['align', alignAll(page)],
    ['search', treeSearch(page)], ['out', zoomOut(page)], ['reset', zoomReset(page)], ['in', zoomIn(page)]]) {
    assert.equal(await locator.count(), 1, `${label}: expanded ${name} control is missing or duplicated.`);
    controls[name] = await locator.boundingBox();
    assert.ok(controls[name], `${label}: ${name} has no real pointer hit box.`);
  }
  const viewport = page.viewportSize(), boxes = Object.values(controls);
  for (const [name, box] of Object.entries(controls)) {
    assert.ok(box.x >= -1 && box.y >= 0 && box.x + box.width <= viewport.width + 1 &&
      box.y + box.height <= viewport.height, `${label}: ${name} is clipped outside the viewport: ${JSON.stringify(box)}`);
  }
  const band = Math.max(...boxes.map((box) => box.y + box.height)) - Math.min(...boxes.map((box) => box.y));
  const rows = [];
  for (const y of boxes.map((box) => center(box).y).sort((a, b) => a - b)) {
    if (!rows.some((row) => Math.abs(row - y) <= 12)) rows.push(y);
  }
  assert.ok(Math.abs(center(controls.mode).y - center(controls.align).y) <= 2 &&
    controls.align.x >= controls.mode.x + controls.mode.width - 1 &&
    controls.align.x - controls.mode.x - controls.mode.width <= 12,
  `${label}: Align Everything is not immediately right of the mode control: ${JSON.stringify(controls)}`);
  const zoomWidth = controls.reset.x + controls.reset.width - controls.out.x;
  assert.ok(zoomWidth > 0 && zoomWidth <= 128 + 1,
    `${label}: zoom controls exceed their compact 128px group: ${zoomWidth}px.`);
  for (const [left, right] of [['out', 'in'], ['in', 'reset'], ['reset', 'search']]) {
    assert.ok(controls[left].x + controls[left].width <= controls[right].x + 1,
      `${label}: expected [-][+][percent] followed by the right-hand search field: ${JSON.stringify(controls)}`);
  }
  assert.ok(controls.search.width >= 48,
    `${label}: compact search has no usable text entry target (${controls.search.width}px).`);
  assert.ok(band <= 48 + 1 && rows.length === 1,
    `${label}: toolbar occupies ${round(band)}px/${rows.length} rows instead of one compact row.`);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), viewport.width,
    `${label}: compact tools caused document overflow.`);
  const evidence = { viewport, portrait, controls, controlBand: round(band), rows, zoomWidth: round(zoomWidth) };
  report.scenarios.push({ name: `${label}-compact-toolbar-real-hit-boxes`, ...evidence });
  return evidence;
}

async function assertCollapsedToolbar(page, label) {
  assert.equal(await toolbarToggle(page, false).count(), 1, `${label}: missing floating opener.`);
  assert.equal(await toolbarToggle(page, true).count(), 0, `${label}: old collapse control remained.`);
  for (const [name, locator] of [['search', treeSearch(page)], ['mode', trunkPicker(page)], ['align', alignAll(page)],
    ['out', zoomOut(page)], ['reset', zoomReset(page)], ['in', zoomIn(page)]]) {
    assert.equal(await locator.count(), 0, `${label}: collapse retained the actual ${name} control.`);
  }
  const semantics = await body(page);
  assert.doesNotMatch(semantics, /button[^\n]*(?:Сбросить масштаб|Увеличить масштаб|Уменьшить масштаб|\d+%)/,
    `${label}: hidden toolbar controls remain in accessibility semantics.`);
  await page.screenshot({ path: path.join(output, `${label}-entire-toolbar-collapsed.png`), animations: 'disabled' });
  return { opener: await toolbarToggle(page, false).boundingBox(), semantics };
}

async function toolbarSearchBrowse(page, seeded, label, name, picker = false, cardName = name) {
  await type(page, treeSearch(page), name);
  const option = searchOption(page, name);
  await option.waitFor();
  const box = await option.boundingBox();
  assert.ok(box && box.width > 0 && box.x >= 0 && box.x + box.width <= page.viewportSize().width + 1,
    `${label}: real search results are clipped/unusable.`);
  await page.screenshot({ path: path.join(output, `${label}-search-results.png`), animations: 'disabled' });
  await option.click();
  await settle(page);
  await assertNoGestureSelection(page, cardName);
  if (picker) {
    assert.equal(await page.getByRole('button', { name: 'Отмена выбора', exact: true }).count(), 1,
      'Search browsing accidentally committed the graphical picker.');
    assert.equal(await page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).isEnabled(), true,
      'A valid search result did not enable explicit picker confirmation.');
  } else {
    assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0,
      'Main toolbar search opened biography rather than browsing.');
  }
  report.scenarios.push({ name: `${label}-real-native-search-browses-without-commit`, target: name, picker, resultBox: box });
}

async function compactToolbarBrowsing(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  await compactToolbarGeometry(page, label, portrait);
  await page.screenshot({ path: path.join(output, `${label}-expanded.png`), animations: 'disabled' });
  await toolbarSearchBrowse(page, seeded, label, 'Недат05');
  await chooseTrunk(page, 'По матери');
  await zoomIn(page).click();
  await zoomIn(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 120);
  await toolbarToggle(page, true).click();
  await settle(page);
  const collapsed = await assertCollapsedToolbar(page, label);
  assert.deepEqual(await history(page, seeded), journal, 'Collapsing wrote to the whole immutable journal.');
  await toolbarToggle(page, false).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 120, 'Reopening lost the main tree zoom.');
  assert.match(await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText(), /По матери/);
  await assertNoGestureSelection(page, 'Недат05');
  await compactToolbarGeometry(page, `${label}-restored`, portrait);
  await page.screenshot({ path: path.join(output, `${label}-restored-settings.png`), animations: 'disabled' });
  await toolbarSearchBrowse(page, seeded, `${label}-restored`, 'Фокус');

  // The full-screen relative picker has an independent toolbar, but the exact
  // same compact layout and true-collapse contracts. Browse, never save an edge.
  await openBiography(page, null, true);
  const addRelative = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, addRelative);
  await addRelative.click();
  const dialog = page.getByRole('alertdialog');
  await useExistingRelative(page);
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
  const cancel = page.getByRole('button', { name: 'Отмена выбора', exact: true });
  await cancel.waitFor();
  await settle(page);
  assert.equal(await zoomPercent(page), 100, 'Picker inherited the main toolbar zoom.');
  await compactToolbarGeometry(page, `${label}-picker`, portrait);
  await toolbarSearchBrowse(page, seeded, `${label}-picker`, 'Недат05', true);
  await chooseTrunk(page, 'По отцу');
  await zoomIn(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 110);
  await toolbarToggle(page, true).click();
  await settle(page);
  const pickerCollapsed = await assertCollapsedToolbar(page, `${label}-picker`);
  assert.equal(await cancel.count(), 1, 'Toolbar collapse removed the independent picker cancellation.');
  assert.equal(await page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).count(), 1,
    'Toolbar collapse removed the independent floating confirmation.');
  await toolbarToggle(page, false).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 110);
  assert.match(await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText(), /По отцу/);
  await assertNoGestureSelection(page, 'Недат05');
  await page.screenshot({ path: path.join(output, `${label}-picker-restored.png`), animations: 'disabled' });
  assert.deepEqual(await history(page, seeded), journal, 'Picker search/mode/zoom/collapse wrote an immutable edit.');
  await cancel.click();
  await dialog.waitFor();
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(page);
  assert.equal(await zoomPercent(page), 120, 'Picker cancellation changed the main toolbar zoom.');
  assert.match(await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText(), /По матери/);
  await assertNoGestureSelection(page);
  assert.deepEqual(await history(page, seeded), journal, 'Toolbar/picker browsing changed the whole room journal.');
  report.scenarios.push({ name: `${label}-entire-toolbar-and-picker-collapse-restore`, collapsed, pickerCollapsed,
    main: { percent: 120, mode: 'По матери', selection: 'Фокус' },
    picker: { percent: 110, mode: 'По отцу', selection: 'Недат05' }, wholeJournalUnchanged: true });
  console.log(`PASS: ${label} compact expanded/search/picker controls, entire collapse, preserved settings/selection and whole journal.`);
}

async function bottomRightAction(page, locator, label) {
  const box = await locator.boundingBox(), viewport = page.viewportSize();
  assert.ok(box && box.width >= 56 && box.height >= 56,
    `${label}: enlarged floating action needs at least a 56px hit target: ${JSON.stringify(box)}`);
  assert.ok(box.x > viewport.width / 2 && box.y > viewport.height / 2 &&
    box.x + box.width <= viewport.width && box.y + box.height <= viewport.height &&
    viewport.width - box.x - box.width <= 32 && viewport.height - box.y - box.height <= 32,
  `${label}: enlarged action is not fully visible at the bottom right: ${JSON.stringify(box)}`);
  return box;
}

async function compactSearchFocus(page, seeded, label, mobile, name, picker = false) {
  const before = await compactToolbarGeometry(page, `${label}-idle`, mobile);
  await page.screenshot({ path: path.join(output, `${label}-idle.png`), animations: 'disabled' });
  await focusInput(page, treeSearch(page));
  await sleep(350);
  const focused = await treeSearch(page).boundingBox();
  assert.ok(focused, `${label}: focused search has no actual input target.`);
  const otherControls = [['mode', trunkPicker(page)], ['align', alignAll(page)],
    ['out', zoomOut(page)], ['in', zoomIn(page)], ['reset', zoomReset(page)]];
  if (mobile) {
    assert.ok(focused.width >= page.viewportSize().width * .75 && focused.width >= before.controls.search.width + 60,
      `${label}: mobile focus did not expand search across the toolbar: ${JSON.stringify({ before: before.controls.search, focused })}`);
    for (const [name, locator] of otherControls) assert.equal(await locator.count(), 0,
      `${label}: mobile expanded search retained the ${name} control.`);
  } else {
    for (const dimension of ['x', 'y', 'width', 'height']) assert.ok(
      Math.abs(focused[dimension] - before.controls.search[dimension]) <= 2,
      `${label}: desktop search changed ${dimension} on focus.`);
    for (const [name, locator] of otherControls) assert.equal(await locator.count(), 1,
      `${label}: desktop search focus hid the ${name} control.`);
  }
  await type(page, treeSearch(page), name);
  const option = searchOption(page, name);
  await option.waitFor();
  const resultBox = await option.boundingBox();
  assert.ok(resultBox && resultBox.x >= 0 && resultBox.x + resultBox.width <= page.viewportSize().width + 1,
    `${label}: search overlay is clipped horizontally.`);
  const expandedSemantics = await body(page);
  await page.screenshot({ path: path.join(output, `${label}-focused-results.png`), animations: 'disabled' });
  await option.click();
  await settle(page);
  await assertSelected(page, name);
  const restored = await compactToolbarGeometry(page, `${label}-after-result`, mobile);
  for (const [control, box] of Object.entries(before.controls)) for (const dimension of ['x', 'y', 'width', 'height']) {
    assert.ok(Math.abs(restored.controls[control][dimension] - box[dimension]) <= 2,
      `${label}: completing search did not restore ${control}.${dimension}.`);
  }
  if (picker) {
    assert.equal(await page.getByRole('button', { name: 'Отмена выбора', exact: true }).count(), 1);
    assert.equal(await page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ }).isEnabled(), true,
      'Search selection must browse until the separate floating confirmation.');
  } else assert.equal(await page.getByRole('button', { name: 'Закрыть биографию', exact: true }).count(), 0);
  await page.screenshot({ path: path.join(output, `${label}-restored.png`), animations: 'disabled' });
  report.scenarios.push({ name: `${label}-responsive-search-focus`, mobile, picker, before, focused, resultBox,
    restored, expandedSemantics, target: name, desktopNeverExpands: !mobile, mobileExpandsAndRestores: mobile });
}

async function compactSearchActions(page, seeded, label, mobile) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.match(await body(page), /Локальная копия · синхронизация не подтверждена/,
    'The isolated focused UI check must not claim confirmed network synchronization.');
  const biographyBox = await bottomRightAction(page, page.getByRole('button', { name: 'Биография', exact: true }), `${label}-biography`);
  report.scenarios.push({ name: `${label}-enlarged-biography-target`, biographyBox });
  await compactSearchFocus(page, seeded, `${label}-main`, mobile, 'Недат05');
  await zoomIn(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 110);
  await zoomOut(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 100);
  // Selection can leave the original root beyond this finite viewport. Return
  // through the real search rather than clicking an offscreen semantics node.
  await toolbarSearchBrowse(page, seeded, `${label}-return-to-root`, 'Фокус');
  await openBiography(page, null, true);
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add);
  await add.click();
  const dialog = page.getByRole('alertdialog');
  await useExistingRelative(page);
  await dialog.getByRole('button', { name: 'Выбрать', exact: true }).click();
  const cancel = page.getByRole('button', { name: 'Отмена выбора', exact: true });
  await cancel.waitFor();
  await settle(page);
  const confirm = page.getByRole('button', { name: /^Подтвердить выбор(?:\s|$)/ });
  const confirmationBox = await bottomRightAction(page, confirm, `${label}-pick-confirm`);
  report.scenarios.push({ name: `${label}-enlarged-picker-confirmation-target`, confirmationBox });
  assert.equal(await page.getByRole('button', { name: 'Биография', exact: true }).count(), 0);
  await compactSearchFocus(page, seeded, `${label}-picker`, mobile, 'Недат05', true);
  assert.deepEqual(await history(page, seeded), journal, 'Search, zoom, and picker browsing appended a hidden edit.');
  await cancel.click();
  await dialog.waitFor();
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
  await closeBiography(page);
  await compactToolbarGeometry(page, `${label}-main-after-picker-cancel`, mobile);
  assert.deepEqual(await history(page, seeded), journal, 'Cancelling the picker changed the immutable journal.');
  await fs.writeFile(path.join(output, `${label}-complete-journal.json`), JSON.stringify(await history(page, seeded), null, 2));
  report.scenarios.push({ name: `${label}-large-bottom-right-actions-and-read-only-navigation`, biographyBox,
    confirmationBox, exactJournalBefore: journal, wholeJournalUnchanged: true, networkIsolated: true });
  console.log(`PASS: ${label} one-row [-][+][%]/right search, ${mobile ? 'mobile focus expansion/restoration' : 'desktop non-expansion'}, normal/picker enlarged actions, exact unchanged journal.`);
}

async function compactSearchFocusDiagnostic(page, seeded) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), query = 'Недат05';
  await page.evaluate(() => {
    const ids = new WeakMap();
    let nextId = 0;
    const events = [];
    const describe = (node) => {
      if (!(node instanceof Element)) return node && { type: node.nodeType, name: node.nodeName };
      if (!ids.has(node)) ids.set(node, ++nextId);
      const input = node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement;
      const box = node.getBoundingClientRect();
      return { id: ids.get(node), tag: node.tagName, class: node.className, connected: node.isConnected,
        role: node.getAttribute('role'), label: node.getAttribute('aria-label'),
        ...(input ? { value: node.value, start: node.selectionStart, end: node.selectionEnd } : {}),
        box: { x: box.x, y: box.y, width: box.width, height: box.height }, outerHTML: node.outerHTML.slice(0, 1400) };
    };
    const state = () => ({ hasFocus: document.hasFocus(), active: describe(document.activeElement),
      tracked: describe(window.__searchFocusDiagnostic.tracked),
      inputs: [...document.querySelectorAll('input,textarea')].map(describe),
      viewport: { width: innerWidth, height: innerHeight, visualWidth: visualViewport?.width, visualHeight: visualViewport?.height },
      orientation: screen.orientation?.type });
    const record = (type, details = {}) => events.push({ time: performance.now(), type, ...details, state: state() });
    window.__searchFocusDiagnostic = { events, describe, state, record, tracked: null, resizing: false };
    for (const method of ['focus', 'blur']) {
      const native = HTMLElement.prototype[method];
      HTMLElement.prototype[method] = function (...args) {
        record(`method-${method}`, { target: describe(this), stack: new Error().stack });
        return Reflect.apply(native, this, args);
      };
    }
    for (const type of ['focusin', 'focusout', 'focus', 'blur', 'pointerdown', 'pointerup', 'mousedown', 'mouseup']) {
      document.addEventListener(type, (event) => record(type, { target: describe(event.target),
        relatedTarget: describe(event.relatedTarget), trusted: event.isTrusted,
        ...(event instanceof PointerEvent || event instanceof MouseEvent ? { x: event.clientX, y: event.clientY, button: event.button } : {}) }),
      { capture: true, passive: true });
    }
    for (const type of ['resize', 'orientationchange', 'focus', 'blur']) {
      window.addEventListener(type, (event) => record(`window-${type}`, { trusted: event.isTrusted }), { capture: true, passive: true });
    }
    new MutationObserver((mutations) => {
      const diagnostic = window.__searchFocusDiagnostic;
      if (!diagnostic.resizing) return;
      for (const mutation of mutations) {
        const relevant = (node) => node === diagnostic.tracked || node instanceof Element &&
          (node.contains(diagnostic.tracked) || node.matches('input,textarea,flt-text-editing-host') || node.querySelector('input,textarea,flt-text-editing-host'));
        const removed = [...mutation.removedNodes].filter(relevant), added = [...mutation.addedNodes].filter(relevant);
        if (removed.length || added.length) record('input-dom-mutation', { target: describe(mutation.target),
          removed: removed.map(describe), added: added.map(describe) });
      }
    }).observe(document.documentElement, { childList: true, subtree: true });
    record('observer-installed');
  });
  await type(page, treeSearch(page), query);
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowLeft');
  await searchOption(page, query).waitFor();
  const before = await page.evaluate(() => {
    const diagnostic = window.__searchFocusDiagnostic;
    diagnostic.tracked = document.activeElement;
    diagnostic.record('before-resize');
    return diagnostic.state();
  });
  assert.equal(before.active.value, query);
  assert.equal(before.active.start, query.length - 2);
  assert.equal(before.active.end, query.length - 2);
  await page.screenshot({ path: path.join(output, 'focus-diagnostic-before-resize.png'), animations: 'disabled' });
  await page.evaluate(() => { const diagnostic = window.__searchFocusDiagnostic; diagnostic.resizing = true; diagnostic.record('resize-requested'); });
  await page.setViewportSize({ width: 844, height: 390 });
  const observation = await page.evaluate(async () => {
    const diagnostic = window.__searchFocusDiagnostic;
    diagnostic.record('playwright-resize-returned');
    const started = performance.now(), samples = [];
    for (let index = 0; index <= 10; index++) {
      if (index) await new Promise((resolve) => setTimeout(resolve, Math.max(0, started + index * 100 - performance.now())));
      samples.push({ elapsed: performance.now() - started, ...diagnostic.state() });
    }
    diagnostic.record('observation-complete');
    return { samples, events: diagnostic.events, final: diagnostic.state() };
  });
  const semantics = await body(page);
  await page.screenshot({ path: path.join(output, 'focus-diagnostic-after-1000ms.png'), animations: 'disabled' });
  const after = await history(page, seeded);
  assert.deepEqual(after, journal, 'The passive rotation diagnostic changed the complete journal.');
  const evidence = { diagnosticOnly: true, viewportTransition: [{ width: 390, height: 844 }, { width: 844, height: 390 }],
    before, ...observation, semantics, wholeJournalUnchanged: true, completeJournal: after,
    pageErrors: report.pageErrors, consoleErrors: report.consoleErrors,
    note: 'Forwarding native focus/blur wrappers and passive observers only; no refocus, retyping or app APIs after resize.' };
  await fs.writeFile(path.join(output, 'focus-diagnostic.json'), JSON.stringify(evidence, null, 2));
  report.scenarios.push({ name: 'single-resize-passive-focus-diagnostic', ...evidence });
  assert.deepEqual(report.pageErrors, []);
  console.log('COMPLETED: one passive390×844→844×390 focus/DOM diagnostic; no functional rotation pass is implied.');
}

async function compactSearchRotation(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), query = 'Недат05';
  await type(page, treeSearch(page), query);
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowLeft');
  const caret = query.length - 2;
  const inputState = () => page.evaluate(() => {
    const input = document.activeElement;
    return { tag: input?.tagName, value: input?.value, start: input?.selectionStart, end: input?.selectionEnd };
  });
  await until(async () => {
    const state = await inputState();
    return state.value === query && state.start === caret && state.end === caret;
  }, 'Real typing did not establish the intended search caret.', 5000);
  const states = [];
  for (const [stage, viewport, mobile] of [
    ['phone-portrait', { width: 390, height: 844 }, true],
    ['phone-landscape', { width: 844, height: 390 }, true],
    ['desktop-landscape', { width: 1100, height: 700 }, false],
    ['phone-portrait-return', { width: 390, height: 844 }, true],
  ]) {
    await page.setViewportSize(viewport);
    // Do not refocus/retype after resize: that would conceal lifecycle loss.
    await until(async () => {
      const state = await inputState();
      return state.value === query && state.start === caret && state.end === caret;
    }, `${label}/${stage}: resizing lost the active native query/caret.`, 8000);
    await searchOption(page, query).waitFor();
    await sleep(500);
    const controls = {};
    for (const [name, locator] of [['toggle', toolbarToggle(page, true)], ['mode', trunkPicker(page)],
      ['align', alignAll(page)], ['out', zoomOut(page)], ['in', zoomIn(page)], ['reset', zoomReset(page)]]) {
      assert.equal(await locator.count(), mobile ? 0 : 1, `${label}/${stage}: wrong ${name} visibility during focused search.`);
      if (!mobile) controls[name] = await locator.boundingBox();
    }
    const search = await treeSearch(page).boundingBox();
    assert.ok(search && (mobile ? search.width >= viewport.width * .8 : search.width >= 230 && search.width <= 260),
      `${label}/${stage}: search is not ${mobile ? 'expanded across the mobile row' : 'fixed-width on desktop'}: ${JSON.stringify(search)}`);
    const result = await searchOption(page, query).boundingBox();
    assert.ok(result && result.x >= 0 && result.x + result.width <= viewport.width + 1,
      `${label}/${stage}: actual search result is clipped horizontally.`);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), viewport.width,
      `${label}/${stage}: resize caused horizontal document overflow.`);
    assert.deepEqual(await history(page, seeded), journal, `${label}/${stage}: view-only resizing changed the complete journal.`);
    assert.deepEqual(report.pageErrors, [], `${label}/${stage}: resize raised an uncaught application error.`);
    const state = { stage, viewport, mobile, input: await inputState(), search, result, controls, semantics: await body(page) };
    states.push(state);
    await page.screenshot({ path: path.join(output, `${label}-${stage}.png`), animations: 'disabled' });
  }
  await page.keyboard.press('Escape');
  await settle(page);
  await toolbarToggle(page, true).waitFor();
  assert.equal(await page.getByRole('button', { name: 'Закрыть поиск', exact: true }).count(), 0,
    'Returning to portrait did not restore the compact controls on real Escape.');
  assert.deepEqual(await history(page, seeded), journal);
  assert.deepEqual(report.pageErrors, []);
  assert.deepEqual(report.consoleErrors, [], 'The focused rotation emitted browser console errors.');
  await page.screenshot({ path: path.join(output, `${label}-portrait-after-blur.png`), animations: 'disabled' });
  await fs.writeFile(path.join(output, `${label}-complete-journal.json`), JSON.stringify(journal, null, 2));
  report.scenarios.push({ name: `${label}-focused-search-survives-rotation-and-breakpoints`, states,
    trustedKeyboardInput: true, noRefocusOrRetypeDuringResize: true, exactCaret: caret,
    completeJournal: journal, wholeJournalUnchanged: true, networkIsolated: true });
  console.log('PASS: phone portrait→landscape→desktop→portrait preserves real focused search query/caret/results; mobile expansion, desktop fixed controls, exact unchanged journal, no browser errors.');
}

async function linearToolbarWheel(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page), steps = [];
  const turn = async (delta, expected, reason, anchor = false) => {
    const beforePercent = await zoomPercent(page), beforeBox = await node(page, 'Фокус').boundingBox();
    assert.ok(beforeBox, 'Wheel focal witness disappeared.');
    const point = anchor ? { x: beforeBox.x + beforeBox.width * .7, y: beforeBox.y + beforeBox.height * .4 } : center(beforeBox);
    await controlWheel(page, point, delta);
    const actual = await zoomPercent(page), event = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
    assert.equal(actual, expected, `${label}: ${reason}; delta=${delta}, ${beforePercent}%→${actual}%, expected ${expected}%.`);
    assert.ok(event && event.trusted && event.ctrl && event.prevented && event.deltaY === delta,
      `${label}: expected an owned genuine native Ctrl+wheel, got ${JSON.stringify(event)}.`);
    const entry = { delta, before: beforePercent, percent: actual, reason, nativeWheel: event };
    if (anchor) {
      const box = await assertNodeScale(page, 'Фокус', expected), ratio = expected / beforePercent;
      const expectedCenter = { x: point.x + (center(beforeBox).x - point.x) * ratio,
        y: point.y + (center(beforeBox).y - point.y) * ratio };
      const observed = center(box);
      assert.ok(Math.abs(observed.x - expectedCenter.x) <= 2 && Math.abs(observed.y - expectedCenter.y) <= 2,
        `${label}: gentle Ctrl+wheel lost its off-center content anchor: ${JSON.stringify({ point, expectedCenter, observed })}`);
      entry.anchor = { point, expectedCenter, observed };
    }
    steps.push(entry);
  };
  const reset = async () => {
    if (await zoomPercent(page) !== 100) await zoomReset(page).click();
    await settle(page);
    assert.equal(await zoomPercent(page), 100);
  };
  await turn(-120, 105, 'a standard wheel notch is gentle, not the old exponential 127%', true);
  await turn(-40, 105, 'same-direction sub-grid residual is retained');
  await turn(-40, 110, '120+40+40 physical pixels produce exactly two 5pp steps', true);
  await turn(-60, 110, 'a fresh fractional step must not zoom early');
  await turn(40, 110, 'direction reversal discards the former 60px residual');
  await turn(60, 105, 'new-direction residual accumulates to exactly 100px', true);
  await reset();
  await turn(-1000, 150, '1000 wheel pixels mean +50pp, not exponential growth');
  await turn(1000, 100, 'opposite 1000 pixels mean -50pp without multiplicative drift');
  await turn(10000, 26, 'large wheel input saturates the nominal 4mm-avatar lower bound');
  await turn(60, 26, 'lower boundary does not store residual/overscroll debt');
  await turn(-100, 30, 'first reversed 100px immediately snaps from the off-grid floor to 30%');
  await turn(100, 26, 'return to lower bound before the exact-grid sequence');
  for (let index = 0; index < 15; index++) {
    await turn(-100, 30 + index * 5, `absolute five-point grid from 26% floor ${index + 1}/15`);
  }
  assert.equal(await zoomPercent(page), 100, 'The 26% floor must rejoin the absolute five-point grid and reach exactly 100%.');
  await turn(-10000, 200, 'large wheel input saturates the upper bound');
  await turn(-60, 200, 'upper boundary does not store residual/overscroll debt');
  await turn(100, 195, 'first reversed 100px responds immediately at the upper bound');
  await reset();
  await turn(-100, 105, 'prepare an off-ten-grid value for the buttons');
  await zoomIn(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 110, '+ snaps to the next 10pp grid, not 115%.');
  await reset();
  await turn(-100, 105, 'prepare the downward off-ten-grid button check');
  await zoomOut(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 100, '- snaps to the previous 10pp grid, not 95%.');
  await assertNoGestureSelection(page);
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Native Ctrl+wheel changed browser zoom/scroll.');
  assert.deepEqual(await history(page, seeded), journal, 'Native wheel/buttons wrote to the whole immutable journal.');
  await page.screenshot({ path: path.join(output, `${label}-linear-wheel-restored-100.png`), animations: 'disabled' });
  report.scenarios.push({ name: `${label}-native-linear-five-pp-wheel-residuals-grid-and-boundaries`, steps,
    buttonGrid: [105, 110, 105, 100], browserUnchanged: true, wholeJournalUnchanged: true });
  console.log(`PASS: ${label} trusted native Ctrl+wheel 5pp/100px, focal anchor, residual/reversal, 26/200 bounds, exact grids.`);
}

async function continuousToolbarPinch(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page);
  const focal = center(await assertNodeScale(page, 'Фокус', 100));
  const cdp = await page.context().newCDPSession(page);
  try {
    await pinch(page, cdp, focal, 40, 45.2);
    assert.equal(await zoomPercent(page), 113, 'Raw mobile pinch was incorrectly snapped to the wheel grid.');
    const box = await assertNodeScale(page, 'Фокус', 113);
    await assertNoGestureSelection(page);
    await page.screenshot({ path: path.join(output, `${label}-continuous-native-pinch-113.png`), animations: 'disabled' });
    await controlWheel(page, center(box), -100);
    assert.equal(await zoomPercent(page), 115, 'A wheel increase must snap a continuous pinch value to the next 5pp grid.');
    await zoomReset(page).click();
    await settle(page);
    await pinch(page, cdp, center(await node(page, 'Фокус').boundingBox()), 40, 45.2);
    assert.equal(await zoomPercent(page), 113);
    await controlWheel(page, center(await node(page, 'Фокус').boundingBox()), 100);
    assert.equal(await zoomPercent(page), 110, 'A wheel decrease must snap a continuous pinch value to the previous 5pp grid.');
    await zoomReset(page).click();
    await settle(page);
    await pinch(page, cdp, center(await node(page, 'Фокус').boundingBox()), 40, 45.2);
    assert.equal(await zoomPercent(page), 113);
    await zoomIn(page).click();
    await settle(page);
    assert.equal(await zoomPercent(page), 120, 'The + button must snap a continuous pinch value to the next 10pp grid.');
    await zoomReset(page).click();
    await settle(page);
    const touches = await page.evaluate(() => window.__canvasTouchEvents);
    assert.ok(touches.some((event) => event.type === 'touchmove' && event.touches === 2 && event.trusted),
      'Continuous pinch did not use real trusted two-contact browser input.');
    assert.deepEqual(await browserZoomState(page), browserBefore, 'Mobile pinch escaped into native browser zoom.');
    assert.deepEqual(await history(page, seeded), journal, 'Mobile pinch/buttons changed the immutable journal.');
    report.scenarios.push({ name: `${label}-raw-native-pinch-remains-continuous`, percent: 113, box,
      subsequentButton: 120, trustedTwoContacts: true, browserUnchanged: true, wholeJournalUnchanged: true });
    console.log(`PASS: ${label} raw native pinch remains continuous at 113%, next + grid is 120%.`);
  } finally {
    await cdp.detach();
  }
}

async function toolbarWashPixels(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  for (let index = 0; index < 5; index++) await zoomOut(page).click();
  await settle(page);
  assert.equal(await zoomPercent(page), 50);
  const state = await capture(page, seeded, `${label}-identical-avatars-context-washes`);
  const styles = [
    { name: 'Полный брат', type: 'normal', alpha: .24, saturation: 1 },
    ...['Кузен', 'Тётя', 'Племянник', 'Племянница'].map((name) => ({ name, type: 'cousin', alpha: .14, saturation: .35 })),
    { name: 'Дальняя сестра', type: 'distant', alpha: .24, saturation: 0 },
  ];
  for (const { name } of styles) assert.ok(state.nodes[name], `${label}: ${name} is clipped; do not sample hidden blocks.`);
  const png = await page.screenshot({ path: path.join(output, `${label}-painted-olive-14-normal-24-grey-24.png`),
    animations: 'disabled', scale: 'css' });
  const pixels = await page.evaluate(async ({ base64, boxes, styles }) => {
    const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    const background = pixel(2, image.height - 5);
    const blend = (rgb, alpha) => rgb.map((channel, c) => channel * alpha + background[c] * (1 - alpha));
    const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
    const evidence = styles.map((style) => {
      const box = boxes[style.name], scale = box.width / 108;
      const patch = [];
      for (const x of [1, 3, 8, 12, 16]) for (const y of [18, 24, 30, 42, 48, 54]) {
        patch.push(pixel(box.x + x * scale, box.y + y * scale));
      }
      const block = [0, 1, 2].map((c) => patch.map((rgb) => rgb[c]).sort((a, b) => a - b)[Math.floor(patch.length / 2)]);
      const photo = [];
      for (let y = 18; y < 53; y += 3) for (let x = 37; x < 72; x += 3) {
        photo.push(pixel(box.x + x * scale, box.y + y * scale));
      }
      return { ...style, box, block, patch, photo,
        expectedBlock: blend(style.type === 'distant' ? [104, 108, 101] : [133, 136, 74], style.alpha),
        oldOlive24: blend([133, 136, 74], .24),
        photoChroma: mean(photo.map((rgb) => Math.max(...rgb) - Math.min(...rgb))) };
    });
    const normalChroma = evidence.find((style) => style.type === 'normal').photoChroma;
    return { background, normalChroma, styles: evidence.map((style) => ({ ...style, chromaRatio: style.photoChroma / normalChroma })) };
  }, { base64: png.toString('base64'), boxes: state.nodes, styles });
  await fs.writeFile(path.join(output, `${label}-wash-pixels.json`), JSON.stringify(pixels, null, 2));
  report.scenarios.push({ name: `${label}-real-pixels-distinguish-context-and-normal-washes`, pixels,
    identicalColoredAvatarSource: true, wholeJournalUnchanged: true });
  assert.ok(pixels.normalChroma > 20, 'The same colorful real PNG did not actually paint.');
  for (const style of pixels.styles) {
    assert.ok(style.block.every((channel, c) => Math.abs(channel - style.expectedBlock[c]) <= 3),
      `${label}: ${style.name} has wrong ${style.type} wash alpha: ${JSON.stringify(style)}`);
    assert.ok(Math.abs(style.chromaRatio - style.saturation) <= .10,
      `${label}: ${style.name} changed the existing avatar saturation while lightening its block.`);
    if (style.type === 'cousin') {
      assert.ok(style.block.every((channel, c) => channel - style.oldOlive24[c] >= 7),
        `${label}: ${style.name} is not visibly lighter than the normal .24 olive wash.`);
    }
  }
  assert.deepEqual(await history(page, seeded), journal, 'Paint-only kinship evidence changed the whole journal.');
  console.log(`PASS: ${label} screenshot pixels: normal olive .24, cousin/aunt/nephew/niece olive .14, distant grey .24; same colorful avatars.`);
}

async function setTreeZoom(page, percent) {
  while (await zoomPercent(page) !== percent) {
    await (await zoomPercent(page) < percent ? zoomIn(page) : zoomOut(page)).click();
    await sleep(90);
  }
  await settle(page);
}

async function crossWheel(page, seeded, portrait, generation, delta, title) {
  const browserBefore = await browserZoomState(page);
  const before = await branchSnapshot(page, seeded, `${title}-before`);
  const candidates = Object.entries(before.nodes).filter(([, box]) => box.generation === generation);
  assert.ok(candidates.length, `${title}: no fully visible target in generation ${generation}.`);
  const [name, target] = candidates[Math.floor(candidates.length / 2)];
  const point = center(target), axis = portrait ? 'y' : 'x';
  await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(portrait ? 0 : delta, portrait ? delta : 0);
  await settle(page);
  let after = await branchSnapshot(page, seeded, `${title}-after`);
  assert.ok(after.nodes[name], `${title}: wheel hid its movement witness ${name}.`);
  let movement = after.nodes[name][axis] - target[axis], appliedDelta = delta;
  if (Math.abs(movement + delta) > 2 && Math.abs(movement) < Math.abs(delta) && movement * delta <= 0) {
    // The selected card may start at either legal scroll boundary. Restore that
    // trial and pan inward instead; do not mistake legitimate clamping for drift.
    await page.mouse.move(point.x, point.y);
    await page.mouse.wheel(portrait ? 0 : movement, portrait ? movement : 0);
    await settle(page);
    appliedDelta = -delta;
    await page.mouse.move(point.x, point.y);
    await page.mouse.wheel(portrait ? 0 : appliedDelta, portrait ? appliedDelta : 0);
    await settle(page);
    after = await branchSnapshot(page, seeded, `${title}-inward-after`);
    assert.ok(after.nodes[name], `${title}: inward wheel hid ${name}.`);
    movement = after.nodes[name][axis] - target[axis];
  }
  assert.ok(Math.abs(movement + appliedDelta) <= 2,
    `${title}: independent cross-axis travel is ${movement}px, not ${-appliedDelta}px.`);
  stable(before, after, Object.keys(before.nodes).filter((candidate) => before.nodes[candidate].generation !== generation),
    `${title}: wheel moved a different generation`);
  const event = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
  assert.ok(event.trusted && !event.ctrl && event.prevented, `${title}: ordinary wheel did not own a trusted browser event.`);
  assert.deepEqual(await browserZoomState(page), browserBefore, `${title}: ordinary wheel changed native browser scroll/scale.`);
  return { generation, requestedDelta: delta, appliedDelta, witness: name, movement, event, before, after };
}

function sceneCenter(state, portrait) {
  return portrait ? state.canvas.y + state.canvas.height / 2 : state.canvas.x + state.canvas.width / 2;
}

function groupCenter(state, names, portrait) {
  const axis = portrait ? 'y' : 'x', extent = portrait ? 'height' : 'width';
  const boxes = names.map((name) => {
    assert.ok(state.nodes[name], `${state.title}: required fully visible alignment node ${name} is missing.`);
    return state.nodes[name];
  });
  return (Math.min(...boxes.map((box) => box[axis])) + Math.max(...boxes.map((box) => box[axis] + box[extent]))) / 2;
}

async function alignmentToolbar(page, seeded, label, portrait) {
  await compactToolbarGeometry(page, label, portrait);
  const top = await canvasTop(page);
  for (const { name } of seeded.people) {
    const captions = page.getByText(name, { exact: true });
    for (let index = 0; index < await captions.count(); index++) {
      const box = await captions.nth(index).boundingBox();
      assert.ok(!box || box.y >= top, `${label}: removed selected-name caption remains in the toolbar (${name}).`);
    }
  }
  const modeText = await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText();
  for (const { name } of seeded.people) assert.ok(!modeText.includes(name), `${label}: mode label still includes selected name ${name}.`);
  const toolbarLabels = await page.locator('flt-semantics[aria-label]').evaluateAll((elements, top) => elements
    .filter((element) => { const box = element.getBoundingClientRect(); return box.width > 0 && box.height > 0 && box.bottom <= top; })
    .map((element) => element.getAttribute('aria-label')), top);
  for (const text of toolbarLabels) for (const { name } of seeded.people) assert.ok(!text.includes(name),
    `${label}: merged Flutter toolbar semantics still contain the removed selected-name caption (${text}).`);
  await alignAll(page).hover();
  await until(async () => await page.getByRole('tooltip').count() > 0 ||
    await page.getByText(/^Выровнять всё(?:\s|$)/).isVisible().catch(() => false) ||
    /(?:^|\n)\s*- (?:tooltip|text): Выровнять всё(?:\s|$)/.test(await body(page)),
  `${label}: real pointer hover did not display the Russian Align Everything tooltip.`);
  await page.screenshot({ path: path.join(output, `${label}-align-tooltip-no-name.png`), animations: 'disabled' });
  await settle(page);
}

function canonicalOrder(state, seeded, portrait, selectedName, mode) {
  const result = {};
  for (const generation of new Set(seeded.people.map((person) => person.generation))) {
    result[generation] = order(state, generation, portrait);
    assert.equal(result[generation].length, seeded.people.filter((person) => person.generation === generation).length,
      `${state.title}: canonical-order viewport must expose every node in generation ${generation}.`);
  }
  const parents = result[2];
  assert.equal(Math.abs(parents.indexOf('Вероника') - parents.indexOf('Наталья')), 1,
    `${state.title}: Natalia/Veronika full-sibling block was split: ${parents.join(', ')}.`);
  const pair = { 'Ольга': ['Наталья', 'Олег'], 'Никита': ['Вероника', 'Роман'] }[selectedName];
  if (mode === 'Обе линии' && pair) {
    const [mother, father] = pair;
    assert.equal(parents.indexOf(father), parents.indexOf(mother) + 1,
      `${state.title}: actual parent CARDS are not neighbors, mother then father: ${parents.join(', ')}.`);
  }
  return result;
}

async function canonicalAlignment(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  await alignmentToolbar(page, seeded, label, portrait);
  const evidence = [];
  for (const percent of [100, 150]) {
    await setTreeZoom(page, percent);
    const remembered = new Map();
    // Same current+mode is reached from parents, half-siblings, the other branch,
    // and both alternative mode paths, not just a single reversible two-click loop.
    for (const [modeIndex, mode] of ['Обе линии', 'По отцу', 'По матери', 'Обе линии', 'По матери', 'По отцу', 'Обе линии'].entries()) {
      await chooseTrunk(page, mode);
      const sequence = modeIndex === 0 || modeIndex === 6
        ? ['Никита', 'Ольга', 'Никита', 'Анастасия', 'Наталья', 'Вероника', 'Олег', 'Никита', 'Ольга']
        : ['Никита', 'Ольга', 'Никита'];
      for (const [selectionIndex, name] of sequence.entries()) {
        await select(page, name);
        const state = await branchSnapshot(page, seeded, `${label}-${percent}-${modeIndex}-${name}`);
        // View offsets are intentionally history-dependent. Explicit alignment
        // exposes the whole compact fixture so order/relative layout, not scroll,
        // is compared and no offscreen node can conceal an ordering regression.
        await alignAll(page).click();
        await settle(page);
        const aligned = await branchSnapshot(page, seeded, `${state.title}-aligned`);
        const actualOrder = canonicalOrder(aligned, seeded, portrait, name, mode), key = `${name}/${mode}`;
        if (name === 'Олег') {
          // Oleg has no ancestors: these lanes have no relevant candidates, so
          // manual Align Everything must center their real all-node fallback.
          for (const names of [['Тестовый отец'], ['Геннадий', 'Лидия'], ['Ольга']]) assert.ok(
            Math.abs(groupCenter(aligned, names, portrait) - sceneCenter(aligned, portrait)) <= 2,
            `${label}: manual empty-relevance fallback did not center ${names.join('/')}.`);
        }
        if (remembered.has(key)) {
          assert.deepEqual(actualOrder, remembered.get(key).order, `${label}/${percent}/${key}: order depends on route.`);
          sameCurrentLayout(remembered.get(key).state, aligned, portrait, `${label}/${percent}/${key}`);
        } else remembered.set(key, { order: actualOrder, state: aligned });
        evidence.push({ percent, mode, selected: name, order: actualOrder, nodes: aligned.nodes });
        if (modeIndex === 0 && selectionIndex < 3) await page.screenshot({
          path: path.join(output, `${label}-${percent}-nikita-olga-nikita-${selectionIndex + 1}-${name}.png`),
          animations: 'disabled', scale: 'css' });
      }
      if (modeIndex === 0 || modeIndex === 6) await branchCapture(page, seeded, `${label}-${percent}-mode-loop-${modeIndex}`);
    }
  }
  assert.deepEqual(await history(page, seeded), journal, 'Canonical selection/mode/alignment/zoom wrote a room edit.');
  report.scenarios.push({ name: `${label}-canonical-current-and-mode-independent-of-navigation`,
    fixture: { room: seeded.room, people: seeded.people, parentEdges: seeded.records.filter((record) => record.kind === 'tree')
      .map((record) => JSON.parse(record.text)).filter((operation) => operation.type === 'setValue' && /^(?:father|mother)Id$/.test(operation.field)) },
    evidence, trustedMouseClicks: true, percentages: [100, 150], selectedParentCardsAdjacentInBothMode: true, wholeJournalUnchanged: true });
  console.log(`PASS: ${label} canonical selection/mode paths at 100/150%, literal parent-card adjacency, new toolbar and unchanged journal.`);
}

function trunkConnectionCandidates(focus, seeded) {
  const connections = [];
  const add = (parent, target, endpoint, present, muted = false, members) => connections.push({
    parent, target, endpoint, present, muted, ...(members ? { members } : {}),
    rgb: ['test', 'patriarch', 'gennady', 'oleg', 'roman', 'nekto'].includes(parent) ? [174, 116, 44] : [51, 139, 100],
  });
  for (const [parent, target] of [['test', 'lydia'], ['patriarch', 'gennady']]) add(parent, target, 'avatar', true);
  const ancestor = focus === 'nikita' ? 'veronika' : 'natalia';
  for (const parent of ['gennady', 'lydia']) {
    for (const target of ['natalia', 'veronika']) add(parent, target, 'avatar', target === ancestor);
  }
  for (const [target, parents] of [['root', ['oleg', 'natalia']], ['anastasia', ['nekto', 'natalia']], ['nikita', ['roman', 'veronika']]]) {
    const immediate = target === focus || (target !== 'nikita' && focus !== 'nikita');
    // Non-immediate cousins retain ONE existing both-mode relevance fallback:
    // deterministic unknown-first/date/name/ID order, not a new bloodline-parent preference.
    const fallback = fixturePeopleByDisplay(seeded, parents)[0].id;
    for (const parent of parents) add(parent, target, target === focus ? 'avatar' : 'block',
      immediate || parent === fallback, !immediate);
  }
  return connections;
}

function trunkParentAdjacency(state, seeded, selectedId, portrait) {
  const row = order(state, 2, portrait), scale = state.zoom / 100, axis = portrait ? 'y' : 'x';
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${state.title}: ${person.name} is clipped.`);
  assert.equal(row.length, 5, `${state.title}: parent rank is incomplete.`);
  const natalia = row.indexOf('Наталья'), veronika = row.indexOf('Вероника');
  // Structural co-parent sides supersede the former whole-row snapshots: both
  // Natalia partners stay on her positive side, even when only one is adjacent.
  for (const [mother, father] of [['Наталья', 'Олег'], ['Наталья', 'Некто'], ['Вероника', 'Роман']]) {
    assert.ok(row.indexOf(mother) < row.indexOf(father),
      `${state.title}: structural mother/father side reversed for ${mother}/${father}: ${row.join(' – ')}.`);
  }
  assert.equal(Math.abs(veronika - natalia), 1, `${state.title}: full sisters were split into separate blocks.`);
  assert.ok(Math.abs(Math.abs(state.nodes['Вероника'][axis] - state.nodes['Наталья'][axis]) - 132 * scale) <= 1.5,
    `${state.title}: Natalia/Veronika no longer occupy one real full-sibling block.`);
  const mother = selectedId === 'nikita' ? 'Вероника' : 'Наталья';
  const father = { root: 'Олег', anastasia: 'Некто', nikita: 'Роман' }[selectedId];
  assert.equal(row.indexOf(father), row.indexOf(mother) + 1,
    `${state.title}: actual parent CARDS must be neighbors (no sibling between), mother before father: ${row.join(' – ')}.`);
  // These selected parents belong to distinct full-sibling blocks: the existing
  // 48px inter-block gap gives a 156px pitch, not the sisters' 132px inner pitch.
  assert.ok(Math.abs(state.nodes[father][axis] - state.nodes[mother][axis] - 156 * scale) <= 1.5,
    `${state.title}: neighboring parent cards lost the existing inter-block spacing or positive-axis order.`);
  // Internal full-sibling order may change at the boundary to satisfy literal
  // parent-card adjacency. The block remains contiguous; birth order is not an
  // oracle that can override the user's selected-parent contract.
  return { cards: row, selectedMother: mother, selectedFather: father,
    parentCardsAdjacent: true, fatherOnPositiveCrossAxis: true, fullSiblingsContiguous: true };
}

async function paintedTrunkConnections(page, seeded, state, focus, mode, portrait) {
  const connections = trunkConnectionCandidates(focus, seeded);
  const boxes = Object.fromEntries(seeded.people.map((person) => {
    assert.ok(state.nodes[person.name], `${state.title}: hidden ${person.name} is not pixel evidence.`);
    return [person.id, state.nodes[person.name]];
  }));
  const png = await fs.readFile(path.join(output, `${state.title}.png`));
  const lines = await page.evaluate(parentCurvePixels, { base64: png.toString('base64'), boxes, connections, portrait });
  await fs.writeFile(path.join(output, `${state.title}-pixels.json`), JSON.stringify(lines, null, 2));
  const signature = (items) => items.map(({ parent, target, endpoint }) => `${parent}->${target}:${endpoint}`).sort();
  const actual = signature(lines.filter((line) => line.matching >= 3));
  const expected = signature(connections.filter((line) => line.present));
  const entry = { name: state.title, focus, mode, state, actual, expected, lines };
  // Retain raw evidence BEFORE assertions. Occluded/coincident samples are a
  // harness limitation, not permission to skip an edge or call the run a pass.
  report.scenarios.push(entry);
  for (const line of lines) assert.ok(line.samples.length >= 3,
    `${state.title}: insufficient unique exposed pixels for ${line.parent}->${line.target}:${line.endpoint}; this does NOT prove presence/absence.`);
  assert.deepEqual(actual, expected, `${state.title}: the painted connection set differs from fixed both-mode relevance.`);
  return entry;
}

async function trunkModes(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), evidence = [], signatures = new Map();
  const hash = (records) => crypto.createHash('sha256').update(JSON.stringify(records)).digest('hex');
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  report.scenarios.push({ name: `${label}-trunk-fixture`, room: seeded.room, people: seeded.people,
    parentEdges: seeded.records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
      .filter((operation) => operation.type === 'setValue' && /^(?:father|mother)Id$/.test(operation.field)) });
  await setTreeZoom(page, 100);
  for (const focus of ['anastasia', 'root', 'nikita']) {
    await select(page, seeded.names[focus]);
    let firstBoth;
    for (const [index, [mode, title]] of [['both', 'Обе линии'], ['mother', 'По матери'], ['father', 'По отцу'], ['both', 'Обе линии']].entries()) {
      await chooseTrunk(page, title);
      await assertSelected(page, seeded.names[focus]);
      await alignAll(page).click();
      await settle(page);
      const artifact = `${label}-100-${focus}-${index}-${mode}`;
      const state = await branchCapture(page, seeded, artifact);
      const parentOrder = mode === 'both' ? trunkParentAdjacency(state, seeded, focus, portrait) : null;
      if (mode === 'both') {
        if (firstBoth) sameCurrentLayout(firstBoth, state, portrait, `${artifact}: return from other trunk modes`);
        else firstBoth = state;
      }
      const entry = await paintedTrunkConnections(page, seeded, state, focus, mode, portrait);
      entry.parentOrder = parentOrder;
      const { actual } = entry;
      if (signatures.has(focus)) assert.deepEqual(actual, signatures.get(focus), `${artifact}: mode switch changed painted connections.`);
      else signatures.set(focus, actual);
      assert.deepEqual(await history(page, seeded), journal, `${artifact}: a view-only gesture changed the complete room journal.`);
      evidence.push({ focus, mode, parentOrder, actual });
    }
  }

  // Force alignment centers one preferred-parent chain at EVERY ancestor rank,
  // rather than averaging all ancestry in the chosen immediate branch.
  await setTreeZoom(page, 150);
  const centering = [];
  for (const [focus, title, chain, rejectedPairs] of [
    ['anastasia', 'По матери', ['anastasia', 'natalia', 'lydia', 'test'], [['lydia', 'gennady'], ['test', 'patriarch']]],
    ['natalia', 'По отцу', ['natalia', 'gennady', 'patriarch'], [['lydia', 'gennady'], ['test', 'patriarch']]],
  ]) {
    await select(page, seeded.names[focus]);
    await chooseTrunk(page, title);
    await alignAll(page).click();
    await settle(page);
    const artifact = `${label}-150-${focus}-${title === 'По матери' ? 'mother' : 'father'}-chain`;
    const centered = await branchCapture(page, seeded, artifact), desired = sceneCenter(centered, portrait);
    const offsets = chain.map((id) => ({ id, name: seeded.names[id],
      offset: round(groupCenter(centered, [seeded.names[id]], portrait) - desired) }));
    const rejected = rejectedPairs.map((ids) => ({ ids,
      offset: round(groupCenter(centered, ids.map((id) => seeded.names[id]), portrait) - desired) }));
    const entry = { name: artifact, focus, mode: title, offsets, rejectedMidpoints: rejected, centered };
    report.scenarios.push(entry);
    for (const target of offsets) assert.ok(Math.abs(target.offset) <= 2,
      `${artifact}: preferred-chain ${target.name} is ${target.offset}px from viewport center.`);
    for (const midpoint of rejected) assert.ok(Math.abs(midpoint.offset) > 24,
      `${artifact}: fixture did not distinguish chain-person centering from the broad-ancestry midpoint.`);
    if (focus === 'anastasia') {
      const pans = [];
      for (const generation of [0, 1, 2, 3]) pans.push(await crossWheel(page, seeded, portrait, generation,
        generation % 2 ? 32 : -38, `${artifact}-visible-independent-pan-${generation}`));
      const displaced = await branchSnapshot(page, seeded, `${artifact}-visible-displaced`);
      for (const id of chain) assert.ok(Math.abs(groupCenter(displaced, [seeded.names[id]], portrait) - sceneCenter(displaced, portrait)) > 20,
        `${artifact}: ${seeded.names[id]} was not genuinely displaced before the auto-alignment check.`);
      await chooseTrunk(page, 'По отцу');
      await chooseTrunk(page, 'По матери');
      const automatic = await branchCapture(page, seeded, `${artifact}-visible-auto-preserved`);
      stable(displaced, automatic, chain.map((id) => seeded.names[id]),
        `${artifact}: automatic mode switching recentered an already fully visible chain target`);
      await alignAll(page).click();
      await settle(page);
      const forced = await branchCapture(page, seeded, `${artifact}-forced-after-visible`);
      for (const id of chain) assert.ok(Math.abs(groupCenter(forced, [seeded.names[id]], portrait) - sceneCenter(forced, portrait)) <= 2,
        `${artifact}: forced alignment failed to center displaced but visible ${seeded.names[id]}.`);
      entry.visibleAutoAndForced = { pans, displaced, automatic, forced };
    }
    centering.push(entry);
  }

  const trusted = await page.evaluate(() => ({
    mouseUps: window.__canvasPrimaryEvents.filter((event) => event.type === 'mouseup').length,
    allPrimaryTrusted: window.__canvasPrimaryEvents.every((event) => event.trusted),
    allWheelTrusted: window.__canvasWheelEvents.every((event) => event.trusted),
  }));
  assert.ok(trusted.mouseUps >= 20 && trusted.allPrimaryTrusted && trusted.allWheelTrusted,
    `${label}: trunk-mode checks did not use trusted real browser input: ${JSON.stringify(trusted)}`);
  const finalJournal = await history(page, seeded);
  assert.deepEqual(finalJournal, journal, 'Trunk-mode browsing/alignment/zoom changed the immutable room journal.');
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(finalJournal, null, 2));
  // Reload uses the actual persisted journal, not tab-close saving.
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, 'Reload changed or lost a complete immutable operation.');
  report.scenarios.push({ name: `${label}-trunk-modes-summary`, evidence, centering,
    input: 'real toolbar/menu and trusted mouse clicks', trusted,
    completeJournal: { beforeSha256: hash(journal), afterSha256: hash(finalJournal), records: journal.length },
    reloadUnchanged: true, limitation: 'Local rendering only; finite fixture candidate routes/pixel witnesses, not exhaustive graph or public-network coverage.' });
  console.log(`PASS: ${label} actual parent-card neighbors/father-positive, unchanged painted edge sets across trunk switches, every preferred ancestor centered, complete journal/reload equality.`);
}

function unchangedRowViewports(before, after, names, message) {
  assert.deepEqual(after.viewport, before.viewport, `${message}: browser viewport changed.`);
  for (const dimension of ['x', 'y', 'width', 'height']) {
    assert.ok(Math.abs(after.canvas[dimension] - before.canvas[dimension]) <= .5,
      `${message}: tree viewport ${dimension} drifted.`);
    for (const name of names) {
      assert.ok(after.clips[name] && before.clips[name], `${message}: missing real clipped row viewport for ${name}.`);
      assert.ok(Math.abs(after.clips[name][dimension] - before.clips[name][dimension]) <= .5,
        `${message}: ${name}'s row viewport ${dimension} drifted.`);
    }
  }
}

async function unchangedCardPixels(page, before, after, names, label, region = 'card') {
  const [first, second] = await Promise.all([before, after].map((state) => fs.readFile(path.join(output, `${state.title}.png`))));
  const pixels = await page.evaluate(async ({ first, second, boxes, names, region }) => {
    const decode = async (png) => {
      const image = new Image(); image.src = `data:image/png;base64,${png}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      return context;
    };
    const [a, b] = await Promise.all([decode(first), decode(second)]);
    return names.map((name) => {
      const card = boxes[name], scale = card.width / 108;
      // Connections start at the avatar's bottom/right edge and are painted
      // behind the transparent semantic card. During a focus change those
      // routes legitimately move; compare opaque avatar content, not that
      // background. A same-focus return still compares the ENTIRE card.
      const box = region === 'avatar' ? { x: card.x + 24 * scale, y: card.y + 6 * scale,
        width: 60 * scale, height: 60 * scale } : card;
      const x = Math.ceil(box.x), y = Math.ceil(box.y);
      const width = Math.floor(box.x + box.width) - x, height = Math.floor(box.y + box.height) - y;
      const one = a.getImageData(x, y, width, height).data, two = b.getImageData(x, y, width, height).data;
      let changed = 0, error = 0;
      for (let index = 0; index < one.length; index += 4) {
        const difference = [0, 1, 2].map((channel) => Math.abs(one[index + channel] - two[index + channel]));
        if (Math.max(...difference) > 8) changed++;
        error += difference.reduce((total, value) => total + value, 0);
      }
      return { name, region, bounds: { x, y, width, height }, sampledPixels: width * height, changedPixels: changed,
        changedFraction: changed / (width * height), meanChannelError: error / (width * height * 3) };
    });
  }, { first: first.toString('base64'), second: second.toString('base64'), boxes: before.nodes, names, region });
  await fs.writeFile(path.join(output, `${label}-card-pixel-diff.json`), JSON.stringify(pixels, null, 2));
  report.scenarios.push({ name: `${label}-unchanged-card-pixels`, before: before.title, after: after.title, pixels });
  for (const card of pixels) assert.ok(card.changedFraction <= .01 && card.meanChannelError <= .35,
    `${label}: supposedly unchanged ${card.name} changed its actual painted card: ${JSON.stringify(card)}.`);
  return pixels;
}

// Shared by the two finite adjacency suites; no toolbar/input-geometry guard
// belongs in an exact tree-layout regression.
async function exactParentExchange(page, seeded, label, portrait, percent, journal) {
  const names = seeded.people.map((person) => person.name);
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, `${label}-${percent}-cold-olga`, 'Ольга');
  await alignAll(page).click();
  await settle(page);
  const cold = await branchCapture(page, seeded, `${label}-${percent}-cold-olga-aligned`);
  const coldOrder = trunkParentAdjacency(cold, seeded, 'root', portrait);
  // The shared oracle checks structural sides and actual-card adjacency;
  // unrelated whole-row order is not an additional immutable fixture contract.
  const browserBefore = await browserZoomState(page);
  await toolbarSearchBrowse(page, seeded, `${label}-${percent}-search-anastasia`, 'Анастасия');
  const switched = await branchCapture(page, seeded, `${label}-${percent}-anastasia-only-fathers-swap`);
  const switchedOrder = trunkParentAdjacency(switched, seeded, 'anastasia', portrait);
  const expectedSwap = { ...cold, nodes: { ...cold.nodes, 'Олег': cold.nodes['Некто'], 'Некто': cold.nodes['Олег'] } };
  stable(expectedSwap, switched, names, `${label}/${percent}: Olga to Anastasia must exchange ONLY Oleg/Nekto slots`);
  unchangedRowViewports(cold, switched, names, `${label}/${percent}: selection changed a row viewport`);
  // Both sisters, Nikita, and every other unmoved card retain actual opaque
  // avatar paint. Do not compare the legitimate rerouted outgoing curves in
  // transparent card backgrounds, or the two changing selection surfaces.
  const unchanged = names.filter((name) => !['Олег', 'Некто', 'Ольга', 'Анастасия'].includes(name));
  const switchedPixels = await unchangedCardPixels(page, cold, switched, unchanged, `${label}-${percent}-anastasia`, 'avatar');
  await select(page, 'Ольга');
  const restored = await branchCapture(page, seeded, `${label}-${percent}-olga-restored-without-align`);
  trunkParentAdjacency(restored, seeded, 'root', portrait);
  stable(cold, restored, names, `${label}/${percent}: returning to Olga did not restore cold absolute geometry`);
  unchangedRowViewports(cold, restored, names, `${label}/${percent}: returning to Olga changed row viewports`);
  const restoredPixels = await unchangedCardPixels(page, cold, restored, names, `${label}-${percent}-olga-restored`);
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Parent selection changed native browser scroll or scale.');
  assert.deepEqual(await history(page, seeded), journal, 'Exact parent selection changed the complete immutable journal.');
  return { percent, cold, switched, restored, coldOrder, switchedOrder, switchedPixels, restoredPixels };
}

async function fixedParentConnectionModes(page, seeded, label, portrait, percent, journal) {
  // Reuse the established child-focus route oracle; a partner-placement check
  // must not invent new Roman/Veronika connection relevance expectations.
  const evidence = [];
  for (const focus of ['root', 'anastasia']) {
    await select(page, seeded.names[focus]);
    await alignAll(page).click();
    await settle(page);
    let firstBoth, signature;
    for (const [index, [mode, title]] of [['both', 'Обе линии'], ['mother', 'По матери'], ['father', 'По отцу'], ['both', 'Обе линии']].entries()) {
      await chooseTrunk(page, title);
      await assertSelected(page, seeded.names[focus]);
      const state = await branchCapture(page, seeded, `${label}-${percent}-${focus}-links-${index}-${mode}`);
      const parentOrder = mode === 'both' ? trunkParentAdjacency(state, seeded, focus, portrait) : null;
      const entry = await paintedTrunkConnections(page, seeded, state, focus, mode, portrait);
      entry.parentOrder = parentOrder;
      if (signature) assert.deepEqual(entry.actual, signature, `${state.title}: a mode switch changed the painted link set.`);
      else signature = entry.actual;
      if (mode === 'both') {
        if (firstBoth) sameCurrentLayout(firstBoth, state, portrait,
          `${state.title}: returning to both lines changed same-current relative geometry`);
        else firstBoth = state;
      }
      assert.deepEqual(await history(page, seeded), journal, `${state.title}: view-only mode switch changed the complete journal.`);
      evidence.push({ focus, mode, actual: entry.actual, parentOrder });
    }
  }
  return evidence;
}

async function parentAdjacency(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), evidence = [];
  const hash = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  report.scenarios.push({ name: `${label}-exact-parent-fixture`, people: seeded.people,
    parentEdges: seeded.records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
      .filter((operation) => operation.type === 'setValue' && /^(?:father|mother)Id$/.test(operation.field)) });
  for (const percent of [100, 150]) {
    // Each scale starts with a real journal reload and Olga's actual initial
    // focus. No application state/layout hook supplies the cold reference.
    if (percent !== 100) await loadRoom(page, seeded);
    await setTreeZoom(page, percent);
    evidence.push(await exactParentExchange(page, seeded, label, portrait, percent, journal));

    await fixedParentConnectionModes(page, seeded, label, portrait, percent, journal);
  }
  const trusted = await page.evaluate(() => ({
    mouseUps: window.__canvasPrimaryEvents.filter((event) => event.type === 'mouseup').length,
    allPrimaryTrusted: window.__canvasPrimaryEvents.every((event) => event.trusted),
  }));
  assert.ok(trusted.mouseUps >= 20 && trusted.allPrimaryTrusted, 'Parent adjacency did not use trusted real browser input.');
  const finalJournal = await history(page, seeded);
  assert.deepEqual(finalJournal, journal, 'Parent-adjacency browsing changed or lost a complete immutable operation.');
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(finalJournal, null, 2));
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, 'Parent-adjacency reload changed the complete journal.');
  report.scenarios.push({ name: `${label}-parent-adjacency-summary`, evidence, trusted, wholeJournalUnchanged: true,
    completeJournal: { beforeSha256: hash(journal), afterSha256: hash(finalJournal), records: journal.length },
    reloadUnchanged: true, networkIsolated: true,
    limitation: 'Finite local rendering fixture at 100/150%; not arbitrary graphs, hardware phones, or public-network verification.' });
  console.log(`PASS: ${label} 100/150% real parent-card neighbors; only Oleg/Nekto swap, exact cold return, fixed row viewports/pixels, mode-independent painted links and complete journal.`);
}

function trunkPartnerBlocks(state, seeded, portrait) {
  const row = order(state, 2, portrait), axis = portrait ? 'y' : 'x', scale = state.zoom / 100;
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${state.title}: ${person.name} is clipped.`);
  const canonical = fixturePeopleByDisplay(seeded, ['natalia', 'veronika']).map((person) => person.name);
  const actual = row.filter((name) => canonical.includes(name));
  assert.deepEqual(actual, canonical, `${state.title}: selected partner proximity reordered canonical sibling members.`);
  for (const [mother, father] of [['Наталья', 'Олег'], ['Наталья', 'Некто'], ['Вероника', 'Роман']]) {
    assert.ok(row.indexOf(mother) < row.indexOf(father), `${state.title}: structural co-parent block sides reversed.`);
  }
  const first = row.indexOf(actual[0]), last = row.indexOf(actual[1]), father = row.indexOf('Роман');
  assert.equal(last, first + 1, `${state.title}: partner full-sibling block was split.`);
  assert.equal(father, last + 1, `${state.title}: partner blocks are not neighboring whole blocks, mother block before father.`);
  assert.ok(Math.abs(state.nodes[actual[1]][axis] - state.nodes[actual[0]][axis] - 132 * scale) <= 1.5,
    `${state.title}: partner siblings lost their internal pitch.`);
  assert.ok(Math.abs(state.nodes['Роман'][axis] - state.nodes[actual[1]][axis] - 156 * scale) <= 1.5,
    `${state.title}: neighboring whole partner blocks lost their existing inter-block pitch.`);
  return { cards: row, canonicalSiblingMembers: canonical, motherBlock: actual, fatherBlock: ['Роман'],
    actualPartnerCardsAdjacent: row.indexOf('Роман') === row.indexOf('Вероника') + 1,
    neighboringWholeBlocks: true, noMemberReorderingForSelectedPartner: true };
}

function ownPartnerPriorityGeometry(state, selected) {
  const names = ['Наталья', 'Вероника', 'Олег', 'Некто', 'Роман'];
  for (const name of names) assert.ok(state.nodes[name], `${state.title}: required partner-priority card ${name} clipped.`);
  const row = names.slice().sort((a, b) => state.nodes[a].x - state.nodes[b].x);
  for (const name of names) assert.ok(Math.abs(state.nodes[name].y - state.nodes['Наталья'].y) <= 1.5,
    `${state.title}: partner/sibling cards no longer share their actual generation.`);
  const sisters = row.filter((name) => ['Наталья', 'Вероника'].includes(name));
  assert.deepEqual(sisters, ['Наталья', 'Вероника'], `${state.title}: partner priority reordered canonical sibling members.`);
  assert.equal(row.indexOf('Вероника'), row.indexOf('Наталья') + 1, `${state.title}: sibling block interleaved.`);
  assert.ok(Math.abs(state.nodes['Вероника'].x - state.nodes['Наталья'].x - 132) <= 1.5,
    `${state.title}: canonical sibling member pitch changed.`);
  const block = (name) => ['Наталья', 'Вероника'].includes(name) ? 'sisters' : name;
  const blocks = row.map(block).filter((name, index, all) => index === 0 || name !== all[index - 1]);
  for (let index = 1; index < row.length; index++) if (block(row[index - 1]) !== block(row[index])) assert.ok(
    state.nodes[row[index]].x - state.nodes[row[index - 1]].x >= 156 - 1.5,
    `${state.title}: separate partner blocks overlap or lost their minimum pitch.`);
  if (selected === 'Наталья') {
    const own = ['sisters', 'Олег', 'Некто'].map((name) => blocks.indexOf(name));
    assert.equal(Math.max(...own) - Math.min(...own), 2,
      `${state.title}: sibling's Roman block interleaves Natalia's own partner cluster.`);
    const roman = blocks.indexOf('Роман');
    assert.ok(roman < Math.min(...own) || roman > Math.max(...own), `${state.title}: Roman must remain outside the higher-priority own cluster.`);
  } else {
    assert.equal(selected, 'Вероника');
    assert.equal(Math.abs(blocks.indexOf('sisters') - blocks.indexOf('Роман')), 1,
      `${state.title}: a sibling's Oleg/Nekto block displaced Veronika's own Roman partner.`);
  }
  const origin = Math.min(...names.map((name) => state.nodes[name].x));
  return { cards: row, blocks, canonicalSisters: sisters, selected,
    relativeRow: Object.fromEntries(names.map((name) => [name, round(state.nodes[name].x - origin)])),
    ownPartnersBeforeSiblingPartners: true, literalSelectedCardSeamRequired: false,
    scope: 'Whole-block priority only; structural ancestor locks may widen/restrict placement. No impossible card seam or arbitrary global row order asserted.' };
}

async function renderedCardClip(page, name) {
  return node(page, name).evaluate((element) => {
    const rect = (element) => { const box = element.getBoundingClientRect();
      return { x: box.x, y: box.y, width: box.width, height: box.height }; };
    const intersect = (a, b) => { const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
      return { x, y, width: Math.min(a.x + a.width, b.x + b.width) - x,
        height: Math.min(a.y + a.height, b.y + b.height) - y }; };
    let clip = { x: 0, y: 0, width: innerWidth, height: innerHeight };
    const clippingAncestors = [];
    for (let parent = element.parentElement; parent; parent = parent.parentElement) {
      const style = getComputedStyle(parent), box = rect(parent);
      if (/(hidden|clip|scroll|auto)/.test(`${style.overflowX} ${style.overflowY}`) && box.width > 0 && box.height > 0) {
        clip = intersect(clip, box);
        clippingAncestors.push({ tag: parent.tagName, bounds: box, overflowX: style.overflowX, overflowY: style.overflowY,
          scrollLeft: parent.scrollLeft, scrollTop: parent.scrollTop });
      }
    }
    const card = rect(element);
    return { label: element.getAttribute('aria-label'), selected: element.getAttribute('aria-selected'), card, clip,
      visiblePart: intersect(card, clip), clippingAncestors };
  });
}

async function clippedRomanOrientation(page, seeded, label, portrait, journal) {
  const cross = portrait ? 'y' : 'x', extent = portrait ? 'height' : 'width';
  await chooseTrunk(page, 'Обе линии'); await setTreeZoom(page, 100);
  await select(page, 'Некто'); await alignAll(page).click(); await settle(page);
  const aligned = await branchSnapshot(page, seeded, `${label}-nekto-aligned`);
  const initial = await renderedCardClip(page, 'Роман'), native = await browserZoomState(page);
  assert.ok(initial.card.width > 100 && initial.visiblePart.width > 0 && initial.visiblePart.height > 0,
    `${label}: initial Roman card is not exposed for the finite row-pan fixture.`);
  const desiredStart = initial.clip[cross] + initial.clip[extent] - initial.card[extent] + 30;
  const delta = initial.card[cross] - desiredStart;
  // Real ordinary wheel over a fully visible card in this generation. Negative
  // delta moves the row right/down; never change a ScrollController or DOM CSS.
  const witness = Object.entries(aligned.nodes).find(([, box]) => box.generation === 2);
  assert.ok(witness, `${label}: no fully visible same-row wheel witness.`);
  const point = center(witness[1]); await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(portrait ? 0 : delta, portrait ? delta : 0); await settle(page);
  const before = await renderedCardClip(page, 'Роман'), panned = await branchSnapshot(page, seeded, `${label}-roman-preclick-clipped`);
  const wheel = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
  const entry = { name: label, portrait, crossAxis: cross, selectedBefore: 'Некто', intendedClippingPixels: 30,
    requestedWheelDelta: delta, actualWheel: wheel, aligned, before, panned,
    preselectionNativeScroll: native, unaffectedOtherGenerationWitnesses: [] };
  report.scenarios.push(entry);
  await page.screenshot({ path: path.join(output, `${label}-preclick-clipped.png`), scale: 'css' });
  await fs.writeFile(path.join(output, `${label}-geometry.json`), JSON.stringify(entry, null, 2));
  assert.ok(wheel?.trusted && !wheel.ctrl && wheel.prevented, `${label}: row pan did not use owned trusted ordinary wheel.`);
  await assertSelected(page, 'Некто');
  entry.actualClippingPixels = before.card[cross] + before.card[extent] - before.clip[cross] - before.clip[extent];
  assert.ok(entry.actualClippingPixels >= 20 && entry.actualClippingPixels <= 40,
    `${label}: Roman was not genuinely clipped by 20–40 CSS px before the tap (${entry.actualClippingPixels}).`);
  assert.ok(before.visiblePart.width > 40 && before.visiblePart.height > 40, `${label}: no adequate real visible pointer target.`);
  for (const [name, box] of Object.entries(aligned.nodes)) if (box.generation !== 2 && panned.nodes[name]) {
    stable(aligned, panned, [name], `${label}: independent cross-row pan moved another generation`);
    entry.unaffectedOtherGenerationWitnesses.push(name);
  }
  assert.ok(entry.unaffectedOtherGenerationWitnesses.length >= 2, `${label}: missing independent-row evidence.`);
  assert.deepEqual(await browserZoomState(page), native, `${label}: row pan changed native browser scroll/scale.`);
  entry.clickPoint = center(before.visiblePart);
  await page.mouse.click(entry.clickPoint.x, entry.clickPoint.y); await settle(page);
  await assertSelected(page, 'Роман');
  entry.after = await renderedCardClip(page, 'Роман');
  entry.afterState = await branchCapture(page, seeded, `${label}-roman-after-selection`);
  entry.postselectionNativeScroll = await browserZoomState(page);
  entry.targetCenter = entry.after.card[cross] + entry.after.card[extent] / 2;
  entry.expectedCanvasCrossCenter = entry.after.clip[cross] + entry.after.clip[extent] / 2;
  entry.centerDelta = round(entry.targetCenter - entry.expectedCanvasCrossCenter);
  entry.completeHistoryUnchanged = true;
  assert.deepEqual(await history(page, seeded), journal, `${label}: pan/selection appended a journal operation.`);
  assert.deepEqual(entry.postselectionNativeScroll, native, `${label}: selection escaped into native scroll/scale.`);
  await refinementCheckpoint(page, `${label}-errors`);
  await fs.writeFile(path.join(output, `${label}-geometry.json`), JSON.stringify(entry, null, 2));
  return entry;
}

async function clippedSelectionCentering(page, seeded, deadline) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'clipped-selection-journal-before.json'), JSON.stringify(journal, null, 2));
  const entries = [await clippedRomanOrientation(page, seeded, 'clipped-selection-landscape', false, journal)];
  const portrait = { name: 'clipped-selection-portrait-scope', remainingMilliseconds: deadline - Date.now() };
  report.scenarios.push(portrait);
  if (portrait.remainingMilliseconds >= 42000) {
    await page.setViewportSize({ width: 1800, height: 2400 });
    entries.push(await clippedRomanOrientation(page, seeded, 'clipped-selection-portrait', true, journal)); portrait.status = 'captured';
  } else { portrait.status = 'unrun'; portrait.reason = 'Reserve the real ~30s durable reload gate inside the single 90s attempt.'; }
  const after = await history(page, seeded); assert.deepEqual(after, journal);
  await fs.writeFile(path.join(output, 'clipped-selection-journal-after.json'), JSON.stringify(after, null, 2));
  // Complete durable replay before strict centering verdict, not on tab closure.
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded); assert.deepEqual(reloaded, journal);
  await fs.writeFile(path.join(output, 'clipped-selection-journal-reloaded.json'), JSON.stringify(reloaded, null, 2));
  await refinementCheckpoint(page, 'clipped-selection-reloaded-errors', true);
  for (const entry of entries) {
    assert.ok(entry.afterState.nodes['Роман'], `${entry.name}: selected Roman is not fully visible.`);
    assert.ok(Math.abs(entry.centerDelta) <= 1.5,
      `${entry.name}: pre-click clipped Roman was only revealed, not centered (${entry.centerDelta}px from actual canvas cross-center).`);
    entry.centeringPassed = true;
  }
  report.scenarios.push({ name: 'clipped-selection-centering-summary', orientationStatuses: { landscape: 'passed', portrait: portrait.status === 'captured' ? 'passed' : 'unrun' },
    preClickClippingWinsOverLaterPartnerReorder: true, centerDeltas: entries.map((entry) => ({ orientation: entry.portrait ? 'portrait' : 'landscape', delta: entry.centerDelta })),
    fullImmutableBeforeAfterReloadEqual: true, records: journal.length,
    journalSha256: crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex'),
    scope: 'Actual visible-part pointer selection, BOTH100%, real independent row pan; no old matrix, public network, every-painted-frame or physical-phone guarantee.' });
  if (portrait.status !== 'captured') throw new Error('Clipped Roman landscape/reload passed; portrait explicitly unrun, overall partial.');
}

async function ownPartnerPriority(page, seeded, deadline) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'own-partner-priority-journal-before.json'), JSON.stringify(journal, null, 2));
  await desktopToolbarHints(page, seeded, journal, 'own-partner-priority');
  await setTreeZoom(page, 100);
  const evidence = [], cycles = [];
  const inspect = async (title, selected, mode) => {
    const entry = { name: title, selected, mode, state: await branchCapture(page, seeded, title) };
    report.scenarios.push(entry); evidence.push(entry);
    await refinementCheckpoint(page, `${title}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${title}: read-only partner/mode browsing changed immutable history.`);
    return entry;
  };
  for (const [label, mode] of [['father', 'По отцу'], ['mother', 'По матери'], ['both', 'Обе линии']]) {
    await chooseTrunk(page, mode);
    await select(page, 'Наталья'); await alignAll(page).click(); await settle(page);
    const cold = await inspect(`own-partner-priority-${label}-natalia-cold`, 'Наталья', mode);
    await select(page, 'Вероника');
    const other = await inspect(`own-partner-priority-${label}-veronika`, 'Вероника', mode);
    await select(page, 'Наталья');
    const returned = await inspect(`own-partner-priority-${label}-natalia-return`, 'Наталья', mode);
    cycles.push({ mode, cold, other, returned });
  }
  const after = await history(page, seeded);
  assert.deepEqual(after, journal);
  await fs.writeFile(path.join(output, 'own-partner-priority-journal-after.json'), JSON.stringify(after, null, 2));
  // Preserve complete durable reload before any strict ordering assertion can
  // hide otherwise useful states. Closing a tab is never treated as saving.
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded); assert.deepEqual(reloaded, journal);
  await fs.writeFile(path.join(output, 'own-partner-priority-journal-reloaded.json'), JSON.stringify(reloaded, null, 2));
  await chooseTrunk(page, 'Обе линии'); await select(page, 'Наталья'); await alignAll(page).click(); await settle(page);
  const reloadEntry = await inspect('own-partner-priority-reloaded-natalia', 'Наталья', 'Обе линии');
  for (const entry of evidence) entry.priority = ownPartnerPriorityGeometry(entry.state, entry.selected);
  for (const cycle of cycles) {
    assert.deepEqual(cycle.returned.priority.cards, cycle.cold.priority.cards, `${cycle.mode}: Natalia return changed same-focus canonical card order.`);
    for (const name of cycle.cold.priority.cards) assert.ok(
      Math.abs(cycle.returned.priority.relativeRow[name] - cycle.cold.priority.relativeRow[name]) <= 1.5,
      `${cycle.mode}: Natalia return changed same-focus relative partner geometry.`);
  }
  assert.deepEqual(reloadEntry.priority.cards, cycles.at(-1).cold.priority.cards, 'Durable replay changed same-focus BOTH partner order.');
  report.scenarios.push({ name: 'own-partner-priority-summary', modes: cycles.map((cycle) => cycle.mode),
    actualGeometryStates: evidence.length, canonicalSiblingMembersUnchanged: true,
    nataliaOwnClusterExcludesRoman: true, veronikaOwnRomanNeighborsWholeSisterBlock: true,
    coldReturnRelativeGeometryConsistent: true, completeBeforeAfterReloadEqual: true,
    records: journal.length, journalSha256: crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex'),
    jitterPaintScope: 'unrun: the eleven-person priority fixture has no Shrek; optional old fixture/matrix is not started.',
    scope: 'One desktop profile, three modes, same family and 100%; no sibling mutation, networking, route pixels, arbitrary-graph or physical-phone guarantee.' });
  const optional = { name: 'own-partner-priority-occupied-options-scope', remainingMilliseconds: deadline - Date.now() };
  report.scenarios.push(optional);
  if (optional.remainingMilliseconds >= 8000) { await occupiedParentDropdown(page, seeded, journal); optional.status = 'captured-for-visual-inspection'; }
  else { optional.status = 'unrun'; optional.reason = 'Tooltip/partner-priority/journal-reload core takes priority.'; }
  console.log('PASS: actual desktop tooltips and all-three-mode selected-own partner priority, canonical sister members, return consistency and complete journal/reload.');
}

async function partnerProximity(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), names = seeded.people.map((person) => person.name), evidence = [];
  const hash = (records) => crypto.createHash('sha256').update(JSON.stringify(records)).digest('hex');
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  report.scenarios.push({ name: `${label}-partner-fixture`, people: seeded.people,
    parentEdges: seeded.records.filter((record) => record.kind === 'tree').map((record) => JSON.parse(record.text))
      .filter((operation) => operation.type === 'setValue' && /^(?:father|mother)Id$/.test(operation.field)) });
  for (const percent of [100, 150]) {
    if (percent !== 100) await loadRoom(page, seeded);
    await setTreeZoom(page, percent);
    const parentExchange = await exactParentExchange(page, seeded, label, portrait, percent, journal);
    const browserBefore = await browserZoomState(page), partners = [];
    let firstRoman;
    for (const [index, focus] of ['roman', 'veronika', 'roman'].entries()) {
      await toolbarSearchBrowse(page, seeded, `${label}-${percent}-${index}-${focus}`, seeded.names[focus]);
      // Only the first Roman view is explicitly aligned. Selected partner
      // proximity compacts whole blocks, never their canonical member order.
      if (index === 0) {
        await alignAll(page).click();
        await settle(page);
      }
      const state = await branchCapture(page, seeded, `${label}-${percent}-${index}-${focus}-partners-neighbors`);
      // Roman/Veronika focus is NOT actual Nikita-parent adjacency. The
      // complete mother's block must neighbor Roman without crossing canonical
      // order; a canonical sister may legitimately sit between those people.
      const proximity = trunkPartnerBlocks(state, seeded, portrait);
      if (focus === 'roman') {
        if (firstRoman) {
          assert.deepEqual(proximity.cards, firstRoman.proximity.cards, `${state.title}: returning to Roman changed the canonical rank order.`);
          sameCurrentLayout(firstRoman.state, state, portrait, `${state.title}: returning to Roman changed same-focus relative geometry`);
          unchangedRowViewports(firstRoman.state, state, names, `${state.title}: returning to Roman changed a row viewport`);
        } else firstRoman = { state, proximity };
      }
      assert.deepEqual(await browserZoomState(page), browserBefore, `${state.title}: partner browsing changed native browser scroll or scale.`);
      assert.deepEqual(await history(page, seeded), journal, `${state.title}: partner browsing changed a complete immutable operation.`);
      const entry = { name: state.title, percent, selected: focus, state, proximity, commonChild: 'nikita', nektoOutsidePartnerGap: true };
      report.scenarios.push(entry);
      partners.push(entry);
    }
    const connections = await fixedParentConnectionModes(page, seeded, label, portrait, percent, journal);
    evidence.push({ percent, parentExchange, partners, connections });
  }
  const trusted = await page.evaluate(() => ({
    mouseUps: window.__canvasPrimaryEvents.filter((event) => event.type === 'mouseup').length,
    allPrimaryTrusted: window.__canvasPrimaryEvents.every((event) => event.trusted),
  }));
  assert.ok(trusted.mouseUps >= 20 && trusted.allPrimaryTrusted, 'Partner proximity did not use trusted real browser input.');
  const finalJournal = await history(page, seeded);
  assert.deepEqual(finalJournal, journal, 'Partner-proximity browsing changed or lost a complete immutable operation.');
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(finalJournal, null, 2));
  // Durable replay is checked before closing the context; tab closure is not a
  // saving mechanism. Retain a fresh Roman-selected production screenshot too.
  await loadRoom(page, seeded);
  const reloadedJournal = await history(page, seeded);
  assert.deepEqual(reloadedJournal, journal, 'Partner-proximity reload changed the complete immutable journal.');
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(reloadedJournal, null, 2));
  await setTreeZoom(page, 150);
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, `${label}-reloaded-roman`, 'Роман');
  await alignAll(page).click();
  await settle(page);
  const reloaded = await branchCapture(page, seeded, `${label}-150-reloaded-roman-partners-neighbors`);
  const reloadedProximity = trunkPartnerBlocks(reloaded, seeded, portrait);
  assert.deepEqual(reloadedProximity.cards, evidence.at(-1).partners[0].proximity.cards,
    `${reloaded.title}: durable reload changed the same-focus Roman rank order.`);
  assert.deepEqual(await history(page, seeded), journal, 'Browsing after reload wrote a room operation.');
  report.scenarios.push({ name: `${label}-partner-proximity-summary`, evidence, trusted, reloaded, reloadedProximity,
    wholeJournalUnchanged: true, reloadUnchanged: true, networkIsolated: true,
    completeJournal: { beforeSha256: hash(journal), afterSha256: hash(finalJournal), reloadSha256: hash(reloadedJournal), records: journal.length },
    connectionPixels: 'Established Olga/Anastasia child-focus oracle across both/maternal/paternal modes; no invented Roman route oracle.',
    limitation: 'Finite local fixture at 100/150% in both orientations, not arbitrary graphs, physical phones, or public-network synchronization.' });
  console.log(`PASS: ${label} whole partner blocks neighboring at 100/150%, canonical siblings, prior exact father-only exchange/painted links and complete journal/reload equality.`);
}

// Actual semantic card positions, not a second production layout. The finite
// corridor fixture supplies ancestor identities, context sides and real family
// blocks; only geometric invariants are asserted, never exact whole-row slots.
function ancestorCorridorOrder(state, seeded, portrait, mode) {
  const axis = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${state.title}: ${person.name} clipped.`);
  for (const generation of new Set(seeded.people.map((person) => person.generation))) {
    const row = seeded.people.filter((person) => person.generation === generation);
    const anchor = state.nodes[row[0].name][main];
    for (const person of row) assert.ok(Math.abs(state.nodes[person.name][main] - anchor) <= 1.5,
      `${state.title}: fixture ${person.name} is not on its actual physical generation row.`);
  }
  const contract = seeded.corridor, evidence = { mode, rows: [], seams: [], siblings: [] };
  for (const ids of contract.siblings) {
    const canonical = fixturePeopleByDisplay(seeded, ids).map((person) => person.name);
    const actual = canonical.slice().sort((a, b) => state.nodes[a][axis] - state.nodes[b][axis]);
    const row = order(state, state.nodes[canonical[0]].generation, portrait);
    const indices = actual.map((name) => row.indexOf(name));
    assert.ok(indices.every((index, offset) => !offset || index === indices[offset - 1] + 1),
      `${state.title}: an indivisible full-sibling block was split.`);
    if (mode !== 'both' || !ids.some((id) => contract.seams.some(([mother, father]) => id === mother || id === father))) {
      assert.deepEqual(actual, canonical, `${state.title}: context/single-mode siblings lost canonical date/name order.`);
    }
    evidence.siblings.push({ ids, canonical, actual });
  }
  if (mode !== 'both') return evidence; // No corridor guarantee is invented for single modes.
  for (const generation of new Set(contract.ancestors.map((id) => seeded.people.find((person) => person.id === id).generation))) {
    const ancestors = contract.ancestors.filter((id) => seeded.people.find((person) => person.id === id).generation === generation);
    const positions = ancestors.map((id) => state.nodes[seeded.names[id]][axis]);
    const first = Math.min(...positions), last = Math.max(...positions);
    const contexts = seeded.people.filter((person) => person.generation === generation && !contract.ancestors.includes(person.id));
    const rowEvidence = { generation, ancestors, first, last, contexts: [] };
    for (const context of contexts) {
      // A nonancestor full sibling is part of its ancestor's indivisible block,
      // not a separately movable context block. Skip only those real members.
      if (contract.siblings.some((ids) => ids.includes(context.id) && ids.some((id) => ancestors.includes(id)))) continue;
      const coordinate = state.nodes[context.name][axis];
      const side = contract.sides[context.id] || (contract.neutral.includes(context.id) ? 'neutral' : 'unforced');
      assert.ok(coordinate < first - 1 || coordinate > last + 1,
        `${state.title}: nonancestor context ${context.name} interleaves the actual ancestor corridor.`);
      if (side === 'maternal') assert.ok(coordinate < first - 1, `${state.title}: maternal-only context is not outside the left/top corridor edge.`);
      if (side === 'paternal') assert.ok(coordinate > last + 1, `${state.title}: paternal-only context is not outside the right/bottom corridor edge.`);
      rowEvidence.contexts.push({ id: context.id, name: context.name, side, coordinate });
    }
    evidence.rows.push(rowEvidence);
  }
  for (const [mother, father] of contract.seams) {
    const a = state.nodes[seeded.names[mother]], b = state.nodes[seeded.names[father]];
    const row = order(state, a.generation, portrait);
    assert.ok(Math.abs(a[main] - b[main]) <= 1.5, `${state.title}: ancestral parent pair has incompatible physical ranks.`);
    assert.equal(row.indexOf(seeded.names[father]), row.indexOf(seeded.names[mother]) + 1,
      `${state.title}: actual ancestral parent cards are not neighboring mother→father.`);
    evidence.seams.push({ mother, father, row });
  }
  return evidence;
}

async function nataliaChildrenAndNephew(page, seeded, label, portrait, journal) {
  await select(page, 'Наталья');
  await chooseTrunk(page, 'Обе линии');
  await alignAll(page).click();
  await settle(page);
  const state = await branchCapture(page, seeded, `${label}-natalia-children-nephew`);
  const row = order(state, 3, portrait), own = ['Анастасия', 'Ольга'];
  for (const name of [...own, 'Наталья', 'Никита', 'Вероника', 'Роман']) assert.ok(state.nodes[name], `${state.title}: ${name} clipped.`);
  assert.equal(Math.abs(row.indexOf(own[0]) - row.indexOf(own[1])), 1,
    `${state.title}: nephew/cousin context interleaves Natalia's two direct-child blocks.`);
  const ownOrder = row.filter((name) => own.includes(name));
  assert.deepEqual(ownOrder, own, `${state.title}: direct-child blocks lost their existing incoming order.`);
  const axis = portrait ? 'y' : 'x';
  assert.ok(state.nodes['Вероника'][axis] > state.nodes['Наталья'][axis] + 1,
    `${state.title}: the actual selected-row sister is not on Natalia's right/bottom side.`);
  assert.ok(row.indexOf('Никита') > Math.max(...own.map((name) => row.indexOf(name))),
    `${state.title}: nephew must follow actual sister Veronika outside the right/bottom cohort edge.`);

  const lines = await nataliaNephewPixels(page, seeded, state, portrait);
  const entry = { name: state.title, selected: 'Наталья', state, row, directChildren: ownOrder,
    nephew: 'Никита', lines, journalUnchanged: true };
  report.scenarios.push(entry);
  for (const line of lines.filter((line) => line.witness)) {
    assert.ok(line.samples.length >= 3, `${state.title}: insufficient uniquely exposed nephew-route pixels; report harness partial.`);
    assert.equal(line.matching >= 3, line.present,
      `${state.title}: Natalia's nephew edge must use actual sister Veronika, not unrelated undated Roman.`);
  }
  await refinementCheckpoint(page, `${state.title}-errors`);
  assert.deepEqual(await history(page, seeded), journal, 'Natalia child/painted-nephew inspection wrote domain history.');
  return entry;
}

async function nataliaNephewPixels(page, seeded, state, portrait) {
  // Reuse the actual PNG curve sampler. Other known outgoing curves are used
  // only as occlusion exclusions, not extra asserted route/colour contracts.
  const connections = [
    { parent: 'veronika', target: 'root', endpoint: 'block', muted: true, present: true, witness: true },
    { parent: 'roman', target: 'root', endpoint: 'block', muted: true, present: false, witness: true },
    { parent: 'natalia', target: 'anastasia', endpoint: 'block', present: true },
    { parent: 'nekto', target: 'anastasia', endpoint: 'block', present: true },
    { parent: 'natalia', target: 'olga', endpoint: 'block', present: true },
    { parent: 'oleg', target: 'olga', endpoint: 'block', present: true },
    { parent: 'veronika', target: 'both-maternal-child', endpoint: 'block', muted: true, present: true },
    { parent: 'roman', target: 'paternal-context-child', endpoint: 'block', present: true },
    { parent: 'both-context', target: 'both-paternal-child', endpoint: 'block', present: true },
  ].filter((link) => seeded.names[link.parent] && seeded.names[link.target])
    .map((link) => ({ ...link, rgb: { male: [174, 116, 44], female: [51, 139, 100], unknown: [138, 144, 135] }[
      seeded.people.find((person) => person.id === link.parent).sex] }));
  const boxes = Object.fromEntries(seeded.people.filter((person) => state.nodes[person.name])
    .map((person) => [person.id, state.nodes[person.name]]));
  for (const link of connections) for (const id of [link.parent, link.target]) {
    assert.ok(boxes[id], `${state.title}: required painted-route/occlusion endpoint ${seeded.names[id]} clipped.`);
  }
  const png = await fs.readFile(path.join(output, `${state.title}.png`));
  const lines = await page.evaluate(parentCurvePixels, { base64: png.toString('base64'), boxes, connections, portrait });
  await fs.writeFile(path.join(output, `${state.title}-pixels.json`), JSON.stringify(lines, null, 2));
  return lines;
}

// Observe only public rendered DOM scroll/clipping state, never Flutter
// controllers or an internal layout API. Raw values may legitimately reconcile.
async function parentRowScrollSnapshot(page) {
  const native = await browserZoomState(page);
  const cards = await page.getByRole('button', { name: /^Выбрать / }).evaluateAll((elements) => {
    const rect = (element) => {
      const r = element.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    };
    return elements.map((element) => {
      const ancestors = [];
      for (let parent = element.parentElement; parent; parent = parent.parentElement) {
        const style = getComputedStyle(parent);
        if (!/(hidden|clip|scroll|auto)/.test(`${style.overflowX} ${style.overflowY}`) &&
            parent.scrollWidth <= parent.clientWidth && parent.scrollHeight <= parent.clientHeight) continue;
        ancestors.push({ tag: parent.tagName, role: parent.getAttribute('role'), bounds: rect(parent),
          overflowX: style.overflowX, overflowY: style.overflowY, scrollLeft: parent.scrollLeft, scrollTop: parent.scrollTop,
          clientWidth: parent.clientWidth, clientHeight: parent.clientHeight,
          scrollWidth: parent.scrollWidth, scrollHeight: parent.scrollHeight });
      }
      return { label: element.getAttribute('aria-label') || element.textContent || '', bounds: rect(element), ancestors };
    });
  });
  return { native, cards };
}

async function parentRowPaintedRects(page, state, names) {
  const png = await fs.readFile(path.join(output, `${state.title}.png`));
  const measured = await page.evaluate(async ({ base64, boxes, names }) => {
    const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    const pixel = (x, y) => [...context.getImageData(Math.round(x), Math.round(y), 1, 1).data].slice(0, 3);
    return names.map((name) => {
      const box = boxes[name], scale = box.width / 108;
      const at = (x, y) => pixel(box.x + x * scale, box.y + y * scale);
      const borders = [[25, 36], [82, 36], [54, 7], [54, 64]].map(([x, y]) => at(x, y));
      const ring = [0, 1, 2].map((c) => borders.map((rgb) => rgb[c]).sort((a, b) => a - b)[1]);
      const matches = (rgb) => Math.max(...rgb.map((channel, c) => Math.abs(channel - ring[c]))) <= 14;
      const xs = [], ys = [];
      for (let x = 18; x <= 89; x++) if ([30, 36, 42].filter((y) => matches(at(x, y))).length >= 2) xs.push(x);
      for (let y = 0; y <= 72; y++) if ([48, 54, 60].filter((x) => matches(at(x, y))).length >= 2) ys.push(y);
      const rect = xs.length && ys.length ? { x: box.x + Math.min(...xs) * scale,
        y: box.y + Math.min(...ys) * scale, width: (Math.max(...xs) - Math.min(...xs) + 1) * scale,
        height: (Math.max(...ys) - Math.min(...ys) + 1) * scale } : null;
      return { name, semanticCard: box, observedRing: ring, borders, paintedAvatarRect: rect,
        expectedAvatarRect: { x: box.x + 24 * scale, y: box.y + 6 * scale, width: 60 * scale, height: 60 * scale } };
    });
  }, { base64: png.toString('base64'), boxes: state.nodes, names });
  await fs.writeFile(path.join(output, `${state.title}-painted-rects.json`), JSON.stringify(measured, null, 2));
  return measured;
}

// Screenshot 24 needs only the common-parent cohort and its nephew witness,
// not every remote card or either unrelated single-mode centering behavior.
function sharedParentCohortOrder(state, portrait) {
  const cross = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  const own = ['Анастасия', 'Ольга'], required = [...own, 'Никита'];
  for (const name of required) assert.ok(state.nodes[name], `${state.title}: required cohort card ${name} clipped.`);
  const anchor = state.nodes['Никита'][main];
  for (const name of own) assert.ok(Math.abs(state.nodes[name][main] - anchor) <= 1.5,
    `${state.title}: Natalia's children and Nikita no longer share their actual generation.`);
  const row = order(state, 3, portrait), indices = own.map((name) => row.indexOf(name));
  assert.equal(Math.abs(indices[0] - indices[1]), 1,
    `${state.title}: selecting another person split Natalia's shared-parent child cohort.`);
  const pitch = Math.abs(state.nodes[own[0]][cross] - state.nodes[own[1]][cross]);
  assert.ok(Math.abs(pitch - 156 * state.zoom / 100) <= 1.5,
    `${state.title}: an unseen block/gap separates Natalia's child blocks.`);
  assert.ok(row.indexOf('Никита') < Math.min(...indices) || row.indexOf('Никита') > Math.max(...indices),
    `${state.title}: nephew Nikita interleaves Natalia's direct children.`);
  return { row, directChildren: row.filter((name) => own.includes(name)), nephewOutside: true, pitch };
}

function parentRowSelectionOrder(state, portrait, selected) {
  const cross = portrait ? 'y' : 'x', main = portrait ? 'x' : 'y';
  const row = order(state, 2, portrait), siblings = ['Прикол', 'Наталья', 'Вероника'];
  const members = row.filter((name) => siblings.includes(name));
  const indices = members.map((name) => row.indexOf(name));
  assert.equal(members.length, 3, `${state.title}: immediate full-sibling block is incomplete.`);
  assert.ok(indices.every((index, offset) => !offset || index === indices[offset - 1] + 1),
    `${state.title}: the full-sibling block split during selection.`);
  const mother = selected === 'Никита' ? 'Вероника' : 'Наталья';
  const father = { 'Никита': 'Роман', 'Ольга': 'Олег', 'Анастасия': 'Некто' }[selected];
  assert.ok(father, `${state.title}: unsupported selected-parent seam ${selected}.`);
  assert.equal(row.indexOf(father), row.indexOf(mother) + 1,
    `${state.title}: legitimate actual-parent seam was lost while preserving the row origin.`);
  for (const name of row) assert.ok(Math.abs(state.nodes[name][main] - state.nodes[mother][main]) <= 1.5,
    `${state.title}: immediate-row card ${name} changed physical generation.`);
  const start = Math.min(...siblings.map((name) => state.nodes[name][cross]));
  const end = Math.max(...siblings.map((name) => state.nodes[name][cross] + state.nodes[name].width));
  const rowStart = Math.min(...row.map((name) => state.nodes[name][cross]));
  const rowEnd = Math.max(...row.map((name) => state.nodes[name][cross] + state.nodes[name].width));
  return { row, siblingMembers: members, siblingStart: start, siblingEnd: end, rowStart, rowEnd,
    siblingPackedOffset: start - rowStart, rowSpan: rowEnd - rowStart, mother, father };
}

function parentRowPreservedOrigin(before, after, portrait) {
  const a = before.order, b = after.order;
  assert.ok(Math.abs(a.rowSpan - b.rowSpan) <= 1.5,
    `${after.name}: fixture row span changed; packed-origin stability precondition is not established.`);
  assert.ok(Math.abs(a.siblingPackedOffset - b.siblingPackedOffset) <= 1.5,
    `${after.name}: sister block moved to another packed slot; cannot claim a pure unwanted row-pan witness.`);
  assert.ok(Math.abs(a.siblingStart - b.siblingStart) <= 1.5 && Math.abs(a.siblingEnd - b.siblingEnd) <= 1.5,
    `${after.name}: the unchanged sister block/background panned with a legitimately moving father cohort.`);
  stable(before.state, after.state, ['Прикол'], `${after.name}: unaffected Prikol anchor jumped`);
  return { crossAxis: portrait ? 'y' : 'x', sisterStartDelta: round(b.siblingStart - a.siblingStart),
    sisterEndDelta: round(b.siblingEnd - a.siblingEnd), rowStartDelta: round(b.rowStart - a.rowStart),
    rowEndDelta: round(b.rowEnd - a.rowEnd), legitimateOtherCardReorderingAllowed: true };
}

async function visibleParentTargetAnchors(page, seeded, label, portrait, journal, initial) {
  const evidence = [];
  let previous = initial;
  for (const [index, target] of ['Олег', 'Шрек', 'Олег'].entries()) {
    const before = previous.state, box = before.nodes[target];
    assert.ok(box, `${label}: ${target} is not fully visible before selection; clipped-target auto-alignment belongs to widget coverage.`);
    const entry = { name: `${label}-visible-target-${index}-${target === 'Олег' ? 'oleg' : 'shrek'}`,
      selected: target, portrait, beforeFrame: before.title, preselectionRect: { ...box },
      preselectionClip: before.clips[target], preselectionScroll: previous.scroll,
      otherCardReorderingAllowed: true, paintedNames: [target] };
    report.scenarios.push(entry); evidence.push(entry);
    await select(page, target); // No alignment, scroll reset or internal focus call.
    entry.state = await branchCapture(page, seeded, entry.name);
    entry.scroll = await parentRowScrollSnapshot(page);
    await fs.writeFile(path.join(output, `${entry.name}-scroll.json`), JSON.stringify(entry.scroll, null, 2));
    entry.actualRect = entry.state.nodes[target];
    entry.deltas = entry.actualRect ? Object.fromEntries(['x', 'y', 'width', 'height']
      .map((dimension) => [dimension, round(entry.actualRect[dimension] - box[dimension])])) : null;
    stable(before, entry.state, [target], `${entry.name}: a visible selected card moved from its PRECLICK physical rectangle`);
    unchangedRowViewports(before, entry.state, [target], `${entry.name}: visible selected target's row viewport changed`);
    assert.deepEqual(entry.scroll.native, previous.scroll.native, `${entry.name}: selection changed native scroll/scale.`);
    await refinementCheckpoint(page, `${entry.name}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${entry.name}: target selection wrote immutable history.`);
    entry.passed = true;
    previous = entry;
  }
  console.log(`PASS: ${label} visible Oleg→Shrek→Oleg target rectangles stay at their actual pre-click positions.`);
  return evidence;
}

// CDP captures the compositor's real PNGs; the separate passive DOM trace is
// semantics evidence only. Neither observer moves cards or calls Flutter APIs.
async function selectionPaintTransition(page, seeded, target, label) {
  const before = await branchCapture(page, seeded, `${label}-preclick`);
  const box = before.nodes[target];
  assert.ok(box, `${label}: target must be fully visible on both axes before input.`);
  const entry = { name: label, target, preselectionRect: box, preselectionClip: before.clips[target],
    before, frames: [], captureErrors: [], otherCardReorderingAllowed: true,
    captureContract: 'CDP Page.startScreencast everyNthFrame=1, PNG; no screenshot animation disabling or injected repaint. CDP does not guarantee delivery of every physical display refresh.' };
  report.scenarios.push(entry);
  const session = await page.context().newCDPSession(page), writes = [];
  session.on('Page.screencastFrame', (frame) => {
    void session.send('Page.screencastFrameAck', { sessionId: frame.sessionId })
      .catch((error) => entry.captureErrors.push(String(error)));
    if (entry.frames.length >= 160) { entry.captureErrors.push('Finite compositor frame limit exceeded.'); return; }
    const file = `${label}-paint-${String(entry.frames.length).padStart(3, '0')}.png`;
    entry.frames.push({ file, metadata: frame.metadata, receivedEpochMilliseconds: Date.now(),
      sha256: crypto.createHash('sha256').update(Buffer.from(frame.data, 'base64')).digest('hex') });
    writes.push(fs.writeFile(path.join(output, file), Buffer.from(frame.data, 'base64')));
  });
  try {
    await page.evaluate(() => {
      const trace = { startedEpochMilliseconds: Date.now(), timeOrigin: performance.timeOrigin, inputs: [], samples: [] };
      window.__selectionPaintTrace = trace;
      const sample = (source) => {
        const cards = [...document.querySelectorAll('[role="button"][aria-label^="Выбрать "]')].map((element) => {
          const rect = element.getBoundingClientRect();
          return { label: element.getAttribute('aria-label'), selected: element.getAttribute('aria-selected'),
            x: rect.x, y: rect.y, width: rect.width, height: rect.height };
        });
        trace.samples.push({ source, epochMilliseconds: performance.timeOrigin + performance.now(), cards,
          scroll: { x: scrollX, y: scrollY, visualScale: visualViewport?.scale ?? 1 } });
      };
      const input = (event) => {
        trace.inputs.push({ type: event.type, trusted: event.isTrusted, x: event.clientX, y: event.clientY,
          epochMilliseconds: performance.timeOrigin + performance.now() });
        sample(event.type);
      };
      for (const type of ['pointerdown', 'pointerup', 'click']) document.addEventListener(type, input, { capture: true, passive: true });
      const observer = new MutationObserver(() => { if (trace.samples.length < 500) sample('mutation'); });
      observer.observe(document.body, { subtree: true, attributes: true, childList: true });
      let raf;
      const tick = () => { if (trace.samples.length < 500) sample('raf'); raf = requestAnimationFrame(tick); };
      raf = requestAnimationFrame(tick); sample('start');
      trace.stop = () => {
        cancelAnimationFrame(raf); observer.disconnect();
        for (const type of ['pointerdown', 'pointerup', 'click']) document.removeEventListener(type, input, true);
        sample('stop');
      };
    });
    await session.send('Page.enable');
    await session.send('Page.startScreencast', { format: 'png', everyNthFrame: 1,
      maxWidth: page.viewportSize().width, maxHeight: page.viewportSize().height });
    await sleep(150);
    // Actual trusted pointer at the PRECLICK card center; no locator auto-scroll.
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await sleep(900);
  } finally {
    entry.domTrace = await page.evaluate(() => {
      const trace = window.__selectionPaintTrace;
      if (!trace) return null;
      trace.stop(); delete trace.stop; return trace;
    }).catch(() => null);
    await session.send('Page.stopScreencast').catch((error) => entry.captureErrors.push(String(error)));
    await Promise.all(writes);
    await session.detach();
    await fs.writeFile(path.join(output, `${label}-trace.json`), JSON.stringify(entry, null, 2));
  }
  const finalFile = `${label}-settled.png`;
  // Do not use animations:'disabled': that could conceal the transient at issue.
  await page.screenshot({ path: path.join(output, finalFile), scale: 'css' });
  entry.finalFile = finalFile;
  await assertSelected(page, target);
  entry.after = await branchSnapshot(page, seeded, `${label}-settled`);
  entry.finalDeltas = entry.after.nodes[target] ? Object.fromEntries(['x', 'y', 'width', 'height']
    .map((key) => [key, round(entry.after.nodes[target][key] - box[key])])) : null;
  const tap = entry.domTrace?.inputs.find((event) => event.type === 'pointerup' && event.trusted);
  assert.ok(tap, `${label}: no trusted completed pointer tap was observed.`);
  entry.tapEpochMilliseconds = tap.epochMilliseconds;
  entry.semanticDeltas = entry.domTrace.samples.filter((sample) => sample.epochMilliseconds >= tap.epochMilliseconds)
    .map((sample) => {
      const card = sample.cards.find((card) => card.label === `Выбрать ${target}`);
      return { source: sample.source, millisecondsAfterTap: round(sample.epochMilliseconds - tap.epochMilliseconds),
        missing: !card, deltas: card ? Object.fromEntries(['x', 'y', 'width', 'height']
          .map((key) => [key, round(card[key] - box[key])])) : null };
    });
  entry.semanticMotionObserved = entry.semanticDeltas.some((sample) => sample.missing || Object.values(sample.deltas).some((delta) => Math.abs(delta) > 1.5));
  await fs.writeFile(path.join(output, `${label}-trace.json`), JSON.stringify(entry, null, 2));
  return entry;
}

async function selectionPaintPixels(page, entry) {
  const read = async (file) => ({ file, base64: (await fs.readFile(path.join(output, file))).toString('base64') });
  const references = await Promise.all([read(`${entry.before.title}.png`), read(entry.finalFile)]);
  const frames = await Promise.all(entry.frames.map(async (frame) => ({ ...frame, ...(await read(frame.file)) })));
  const evidence = await page.evaluate(async ({ references, frames, box, viewport, tap }) => {
    const decode = async ({ base64 }) => {
      const image = new Image(); image.src = `data:image/png;base64,${base64}`; await image.decode();
      const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d', { willReadFrequently: true }); context.drawImage(image, 0, 0);
      return { width: image.width, height: image.height, pixels: context.getImageData(0, 0, image.width, image.height).data };
    };
    // Dark foreground masks ignore legitimate branch saturation/background/ink
    // changes. Avatar initials AND complete name glyphs identify the target;
    // a same-color selected outline alone is deliberately insufficient.
    const ink = (image, x, y) => {
      x = Math.round(x); y = Math.round(y);
      if (x < 0 || y < 0 || x >= image.width || y >= image.height) return false;
      const at = (y * image.width + x) * 4, p = image.pixels;
      return .2126 * p[at] + .7152 * p[at + 1] + .0722 * p[at + 2] < 170;
    };
    const patches = [{ x: 38, y: 18, width: 32, height: 36 }, { x: 22, y: 75, width: 64, height: 24 }];
    const mask = (image, card, patch) => {
      const bits = [];
      for (let y = 0; y < patch.height; y++) for (let x = 0; x < patch.width; x++) bits.push(ink(image, card.x + patch.x + x, card.y + patch.y + y));
      return bits;
    };
    const referenceImages = await Promise.all(references.map(decode));
    if (referenceImages.some((image) => image.width !== viewport.width || image.height !== viewport.height)) return { status: 'unverified', reason: 'Reference PNG was not a 1:1 CSS raster.' };
    const templates = referenceImages.map((image) => patches.map((patch) => mask(image, box, patch)));
    if (templates.some((parts) => parts.some((bits) => bits.filter(Boolean).length < 12))) return { status: 'unverified', reason: 'Insufficient actual avatar/name ink for target identity.' };
    const score = (actual, expected) => {
      let intersection = 0, union = 0;
      for (let i = 0; i < actual.length; i++) { if (actual[i] && expected[i]) intersection++; if (actual[i] || expected[i]) union++; }
      return union ? intersection / union : 0;
    };
    const locate = (image) => {
      const candidates = [], nearInk = (x, y) => ink(image, x, y) || ink(image, x + 1, y) || ink(image, x, y + 1);
      const expectedCenterY = box.y + 36;
      // Full horizontal viewport, +/- one generation vertically. Movement
      // outside this finite search becomes UNVERIFIED, never a stable pass.
      for (let cy = Math.max(30, Math.floor(expectedCenterY - 200)); cy < Math.min(image.height - 30, expectedCenterY + 200); cy += 2) {
        for (let cx = 30; cx < image.width - 30; cx += 2) {
          if (!nearInk(cx - 29, cy) || !nearInk(cx + 29, cy) || !nearInk(cx, cy - 29) || !nearInk(cx, cy + 29)) continue;
          if (!nearInk(cx - 29, cy - 6) || !nearInk(cx + 29, cy + 6)) continue;
          const card = { x: cx - 54, y: cy - 36 };
          let best = 0;
          for (const template of templates) {
            const glyph = score(mask(image, card, patches[0]), template[0]);
            if (glyph < .48) continue;
            const name = score(mask(image, card, patches[1]), template[1]);
            if (name >= .48) best = Math.max(best, .4 * glyph + .6 * name);
          }
          if (best >= .60) candidates.push({ ...card, score: best });
        }
      }
      candidates.sort((a, b) => b.score - a.score);
      const distinct = [];
      for (const candidate of candidates) if (!distinct.some((old) => Math.hypot(candidate.x - old.x, candidate.y - old.y) <= 5)) distinct.push(candidate);
      const best = distinct[0], runnerUp = distinct[1];
      if (!best || runnerUp && best.score - runnerUp.score < .08) return { status: 'unverified', reason: 'Target ink missing or ambiguous.', candidates: distinct.slice(0, 4) };
      return { status: 'located', paintedCardOrigin: { x: best.x, y: best.y }, confidence: best.score,
        deltas: { x: best.x - box.x, y: best.y - box.y }, candidates: distinct.slice(0, 3) };
    };
    const results = [];
    for (const frame of frames) {
      const image = await decode(frame), timestamp = frame.metadata.timestamp * 1000;
      if (!Number.isFinite(timestamp) || Math.abs(timestamp - tap) > 60000 || image.width !== viewport.width || image.height !== viewport.height) {
        results.push({ file: frame.file, status: 'unverified', reason: 'CDP timestamp/raster could not be correlated 1:1 with trusted tap.' }); continue;
      }
      results.push({ file: frame.file, millisecondsAfterTap: timestamp - tap, afterTap: timestamp >= tap,
        width: image.width, height: image.height, ...locate(image) });
    }
    return { status: 'decoded', results, search: 'entire horizontal viewport, target generation +/-200 CSS px; actual initial+name masks, selected/unselected references' };
  }, { references, frames, box: entry.preselectionRect, viewport: entry.before.viewport, tap: entry.tapEpochMilliseconds });
  entry.paintEvidence = evidence;
  const after = evidence.results?.filter((frame) => frame.afterTap) ?? [];
  entry.paintedMotionObserved = after.some((frame) => frame.status === 'located' &&
    (Math.abs(frame.deltas.x) > 1.5 || Math.abs(frame.deltas.y) > 1.5));
  const times = after.map((frame) => frame.millisecondsAfterTap).sort((a, b) => a - b);
  entry.captureTiming = { capturedFrames: entry.frames.length, capturedAfterTap: after.length,
    firstPostTapMilliseconds: times[0] ?? null, lastPostTapMilliseconds: times.at(-1) ?? null,
    largestCapturedGapMilliseconds: times.length > 1 ? Math.max(...times.slice(1).map((time, index) => time - times[index])) : null,
    everyPhysicalRefreshGuaranteed: false };
  entry.paintStatus = entry.paintedMotionObserved ? 'failed' : evidence.status !== 'decoded' ||
    after.length < 2 || after.some((frame) => frame.status !== 'located') || !after.some((frame) => frame.millisecondsAfterTap <= 100) ||
    entry.captureErrors.length ? 'unverified' : 'passed-for-captured-compositor-frames';
  await fs.writeFile(path.join(output, `${entry.name}-trace.json`), JSON.stringify(entry, null, 2));
  return entry.paintStatus;
}

async function occupiedParentDropdown(page, seeded, journal) {
  await openBiography(page, 'Никита', true); // Both parents already occupied, no mutation.
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add); await add.click();
  const dialog = page.getByRole('alertdialog');
  await dialog.getByRole('button', { name: /^Кого добавить/ }).click();
  const options = await page.getByRole('menuitem').evaluateAll((elements) => elements.map((element) => {
    const rect = element.getBoundingClientRect();
    return { label: element.getAttribute('aria-label') || element.textContent || '', disabled: element.getAttribute('aria-disabled'),
      bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
  }));
  const sibling = options.findIndex((option) => option.label.trim() === 'Брат/сестра');
  const child = options.findIndex((option) => option.label.trim() === 'Ребёнка');
  assert.ok(sibling >= 0 && child > sibling, 'Combined sibling option must precede Child.');
  await page.screenshot({ path: path.join(output, 'selection-frame-occupied-parent-options.png'), animations: 'disabled' });
  report.scenarios.push({ name: 'selection-frame-occupied-parent-options', options,
    screenshot: 'selection-frame-occupied-parent-options.png', mutedColorVerification: 'Retained actual PNG requires visual inspection; semantics/CSS do not prove Flutter canvas text color.' });
  await page.getByRole('menuitem', { name: 'Брат/сестра', exact: true }).click();
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click(); await closeBiography(page);
  assert.deepEqual(await history(page, seeded), journal, 'Occupied parent dropdown/cancel wrote history.');
  await refinementCheckpoint(page, 'selection-frame-occupied-parent-options-errors');
}

async function combinedSiblingForm(page, seeded, journal) {
  await openBiography(page, 'Тест', true); // Actual parentless person in the same 16-person fixture.
  const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
  await revealBiography(page, add); await add.click();
  const dialog = page.getByRole('alertdialog');
  await dialog.getByRole('button', { name: /^Кого добавить/ }).click();
  const options = await page.getByRole('menuitem').evaluateAll((elements) => elements.map((element) => element.getAttribute('aria-label') || element.textContent || ''));
  const siblingIndex = options.findIndex((label) => label.trim() === 'Брат/сестра');
  const childIndex = options.findIndex((label) => label.trim() === 'Ребёнка');
  assert.ok(siblingIndex >= 0 && childIndex > siblingIndex, 'Combined sibling option must precede child.');
  assert.equal(options.filter((label) => ['Брат', 'Сестра'].includes(label.trim())).length, 0);
  await page.getByRole('menuitem', { name: 'Брат/сестра', exact: true }).click();
  await dialog.getByRole('textbox', { name: 'Имя нового человека', exact: true }).waitFor();
  const fromTree = dialog.getByRole('checkbox', { name: 'Из дерева', exact: true });
  const fresh = dialog.getByRole('checkbox', { name: 'Новый человек', exact: true });
  assert.equal(await fromTree.count(), 1);
  assert.equal(await fresh.count(), 1);
  assert.equal(await fresh.isChecked(), true);
  assert.equal(await fromTree.isDisabled(), true);
  assert.equal(await dialog.getByRole('button', { name: 'Выбрать', exact: true }).count(), 0);
  await dialog.getByRole('button', { name: 'Дата рождения (необязательно)', exact: true }).waitFor();
  assert.match(await dialog.getByRole('button', { name: /^Пол(?:\s|$)/ }).getAttribute('aria-label') || '', /Пол не указан/);
  for (const sex of ['Женский', 'Мужской', 'Пол не указан']) await chooseNewPersonSex(page, sex);
  await page.screenshot({ path: path.join(output, 'selection-frame-combined-sibling-form.png'), animations: 'disabled' });
  await dialog.getByRole('button', { name: 'Отмена', exact: true }).click(); await closeBiography(page);
  assert.deepEqual(await history(page, seeded), journal, 'Combined sibling form/sex/cancel wrote history.');
  await refinementCheckpoint(page, 'selection-frame-combined-sibling-form-errors');
  report.scenarios.push({ name: 'selection-frame-combined-sibling-form', options, defaultSex: 'unknown', editableSexChoices: ['Женский', 'Мужской', 'Пол не указан'],
    newOnly: true, optionalBirthDate: true, cancelledWithoutWrite: true });
}

async function desktopToolbarHints(page, seeded, journal, prefix = 'selection-frame') {
  const hints = [], startedAt = Date.now();
  for (const [name, control, patterns] of [
    ['mode', trunkPicker(page), [/1[\s\S]*отцу/i, /2[\s\S]*матери/i, /3[\s\S]*обе/i]],
    ['align', alignAll(page), [/Пробел/i]],
    ['zoom-in', zoomIn(page), [/Ctrl/i, /колес/i]],
    ['zoom-out', zoomOut(page), [/Ctrl/i, /колес/i]],
  ]) {
    if (name.startsWith('zoom-') && Date.now() - startedAt >= 5000) {
      hints.push({ control: name, status: 'unrun', reason: 'Mode/Align verified first; slow hover capture cannot consume the transition/reload budget.' });
      continue;
    }
    await page.mouse.move(1, 1); await sleep(150); await control.hover();
    let text = '';
    await until(async () => {
      const tooltips = await page.getByRole('tooltip').evaluateAll((elements) => elements.map((element) => element.getAttribute('aria-label') || element.textContent || ''));
      text = tooltips.join('\n');
      if (patterns.every((pattern) => pattern.test(text))) return true;
      const visible = await page.getByText(patterns[0]).allTextContents();
      text = visible.join('\n');
      return patterns.every((pattern) => pattern.test(text)) && await page.getByText(patterns[0]).first().isVisible().catch(() => false);
    }, `Desktop ${name} hover did not expose actual keyboard/gesture hint.`, 2500);
    const file = `${prefix}-toolbar-${name}-hint.png`;
    await page.screenshot({ path: path.join(output, file) });
    hints.push({ control: name, actualTooltipText: text, screenshot: file });
  }
  await page.mouse.move(1, 1);
  assert.deepEqual(await history(page, seeded), journal, 'Read-only toolbar hover wrote history.');
  await refinementCheckpoint(page, `${prefix}-desktop-toolbar-hints-errors`);
  report.scenarios.push({ name: `${prefix}-desktop-toolbar-hints`, hints, priority: 'Immediately after canvas entry, before focus scenarios',
    platform: 'Actual Windows desktop browser', historyUnchanged: true });
}

async function selectionFrameStability(page, seeded, deadline) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'selection-frame-journal-before.json'), JSON.stringify(journal, null, 2));
  await desktopToolbarHints(page, seeded, journal);
  await chooseTrunk(page, 'Обе линии'); await setTreeZoom(page, 100);
  await select(page, 'Никита'); await alignAll(page).click(); await settle(page);
  await select(page, 'Олег'); // Establish initial focus; only the next two transitions are traced.
  const transitions = [];
  for (const [target, label] of [['Шрек', 'selection-frame-oleg-to-shrek'], ['Олег', 'selection-frame-shrek-to-oleg']]) {
    transitions.push(await selectionPaintTransition(page, seeded, target, label));
    await refinementCheckpoint(page, `${label}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${label}: view-only transition wrote history.`);
  }
  const after = await history(page, seeded);
  await fs.writeFile(path.join(output, 'selection-frame-journal-after.json'), JSON.stringify(after, null, 2));
  // Durable storage/reload is core, before any ambiguous pixel matcher can stop it.
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, 'Frame trace/reload changed immutable history.');
  await fs.writeFile(path.join(output, 'selection-frame-journal-reloaded.json'), JSON.stringify(await history(page, seeded), null, 2));
  await refinementCheckpoint(page, 'selection-frame-reloaded-errors');
  const statuses = [];
  for (const transition of transitions) statuses.push(await selectionPaintPixels(page, transition));
  const core = { name: 'selection-frame-core', orientations: ['landscape-2600x1900'], zoom: 100, transitions: 2,
    immutableBeforeAfterReloadEqual: true, journalSha256: crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex'),
    semanticMotionObserved: transitions.map((entry) => ({ target: entry.target, observed: entry.semanticMotionObserved })),
    paintStatuses: statuses, everyPhysicalRefreshGuaranteed: false };
  report.scenarios.push(core);
  // A semantic jump and a painted jump are different findings, retained above.
  // Correct final geometry alone cannot make an incomplete/failed paint trace pass.
  for (const transition of transitions) {
    stable(transition.before, transition.after, [transition.target], `${transition.name}: final target moved`);
    assert.equal(transition.paintStatus, 'passed-for-captured-compositor-frames',
      `${transition.name}: actual paint ${transition.paintStatus}; final semantic rectangles are not a substitute.`);
  }
  const occupied = { name: 'selection-frame-occupied-options-scope', remainingMilliseconds: deadline - Date.now() };
  report.scenarios.push(occupied);
  if (occupied.remainingMilliseconds >= 8000) { await occupiedParentDropdown(page, seeded, journal); occupied.status = 'captured-for-visual-inspection'; }
  else { occupied.status = 'unrun'; occupied.reason = 'Paint transitions and durable reload take priority.'; }
  const optional = { name: 'selection-frame-combined-form-scope', remainingMilliseconds: deadline - Date.now() };
  report.scenarios.push(optional);
  if (optional.remainingMilliseconds >= 12000) { await combinedSiblingForm(page, seeded, journal); optional.status = 'passed'; }
  else { optional.status = 'unrun'; optional.reason = 'Two real paint transitions, durable journal reload and occupied-options screenshot take priority.'; }
}

async function parentRowKeyboard(page, seeded, journal, names) {
  const label = 'parent-row-stability-keyboard', mappings = [];
  await select(page, 'Никита'); // Actual canvas input, not a focus/shortcut hook.
  for (const [key, title] of [['1', 'По отцу'], ['2', 'По матери'], ['3', 'Обе линии']]) {
    await page.keyboard.press(key);
    await settle(page);
    const actual = await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText();
    mappings.push({ key, expected: title, actual });
    report.scenarios.push({ name: `${label}-${key}-mode`, key, expected: title, actual });
    assert.match(actual, new RegExp(title), `${label}: real key ${key} did not select ${title}.`);
  }
  await page.screenshot({ path: path.join(output, `${label}-123-both.png`), animations: 'disabled', scale: 'css' });
  const pan = await crossWheel(page, seeded, true, 2, 72, `${label}-before-space`);
  await page.keyboard.press('Space');
  await settle(page);
  const aligned = await branchCapture(page, seeded, `${label}-space-aligned`);
  assert.ok(Math.abs(aligned.nodes[pan.witness].y - pan.after.nodes[pan.witness].y) > 20,
    `${label}: Space did not visibly undo the real independent-row pan.`);
  await alignAll(page).click();
  await settle(page);
  const buttonAligned = await branchCapture(page, seeded, `${label}-button-aligned-reference`);
  stable(aligned, buttonAligned, [...names, 'Никита'], `${label}: Space differs from the actual Align All button`);

  // Keep a genuine row displacement while typing so an accidental Space align
  // is observable, not masked by an already aligned canvas.
  await crossWheel(page, seeded, true, 2, 72, `${label}-before-typing`);
  const beforeTyping = await branchCapture(page, seeded, `${label}-before-typing-guard`);
  const modeBeforeTyping = await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText();
  await focusInput(page, treeSearch(page).first(), '');
  const typingCheckpoints = [];
  let expected = '';
  for (const character of ['1', ' ', '2', ' ', '3']) {
    expected += character;
    await page.keyboard.type(character);
    await until(async () => await activeInputValue(page) === expected,
      `${label}: shortcuts swallowed/reordered actual search typing.`, 5000);
    await sleep(90);
    const actualMode = await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText();
    assert.equal(actualMode, modeBeforeTyping, `${label}: typed ${JSON.stringify(expected)} changed the trunk mode.`);
    const frame = await branchSnapshot(page, seeded, `${label}-typing-${typingCheckpoints.length}`);
    stable(beforeTyping, frame, names, `${label}: typed ${JSON.stringify(expected)} triggered alignment`);
    typingCheckpoints.push({ typed: expected, actualMode, requiredRowUnchanged: true });
  }
  await settle(page);
  const afterTyping = await branchCapture(page, seeded, `${label}-focused-search-digits-spaces`);
  const typed = await activeInputValue(page);
  const modeAfterTyping = await trunkPicker(page).getAttribute('aria-label') || await trunkPicker(page).innerText();
  assert.equal(modeAfterTyping, modeBeforeTyping, `${label}: typing digits changed the trunk mode.`);
  stable(beforeTyping, afterTyping, names, `${label}: typing a space aligned/panned the canvas`);
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.press('Escape');
  await settle(page);
  await refinementCheckpoint(page, `${label}-errors`);
  assert.deepEqual(await history(page, seeded), journal, 'Keyboard modes/alignment/search typing wrote domain history.');
  const entry = { name: `${label}-summary`, mappings, spaceMatchesActualAlignAll: true,
    observedSearchValue: typed, typingCheckpoints, typingPreservesModeAndRow: true, completeJournalUnchanged: true };
  report.scenarios.push(entry);
  console.log('PASS: real 1/2/3 mode keys, Space matches Align All, focused search digits/spaces do not trigger shortcuts.');
  return entry;
}

async function parentRowStability(page, seeded) {
  const startedAt = Date.now();
  await fs.writeFile(path.join(output, 'parent-row-stability-stored-fixture.json'), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'parent-row-stability-journal-before.json'), JSON.stringify(journal, null, 2));
  await setTreeZoom(page, 100);
  const names = ['Прикол', 'Наталья', 'Вероника', 'Роман', 'Некто', 'Олег', 'Шрек'];
  const evidence = [];
  const inspect = async (title, selected, portrait) => {
    const state = await branchCapture(page, seeded, title);
    const entry = { name: title, selected, portrait, state, scroll: await parentRowScrollSnapshot(page) };
    report.scenarios.push(entry); evidence.push(entry);
    await fs.writeFile(path.join(output, `${title}-scroll.json`), JSON.stringify(entry.scroll, null, 2));
    for (const name of [...names, 'Никита', 'Ольга', 'Анастасия']) assert.ok(state.nodes[name], `${title}: required immediate-row/selection card ${name} clipped.`);
    entry.order = parentRowSelectionOrder(state, portrait, selected);
    await refinementCheckpoint(page, `${title}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${title}: selection wrote immutable history.`);
    return entry;
  };
  const targetBaseline = async (title, portrait, required = ['Олег', 'Шрек']) => {
    const state = await branchCapture(page, seeded, title);
    const entry = { name: title, selected: 'Никита', portrait, state,
      scroll: await parentRowScrollSnapshot(page), paintedNames: required.filter((name) => name !== 'Никита') };
    report.scenarios.push(entry); evidence.push(entry);
    await fs.writeFile(path.join(output, `${title}-scroll.json`), JSON.stringify(entry.scroll, null, 2));
    for (const name of required) assert.ok(state.nodes[name], `${title}: required pre-click target ${name} clipped.`);
    await refinementCheckpoint(page, `${title}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${title}: preparing targets changed immutable history.`);
    entry.passed = true;
    return entry;
  };
  // Latest user requirement first. Older Nikita/Olga path checks cannot prevent
  // observing Oleg/Shrek's own pre-click anchors in either orientation/reload.
  for (const [label, viewport, portrait] of [
    ['parent-row-stability-landscape', { width: 2600, height: 1900 }, false],
    ['parent-row-stability-portrait', { width: 1900, height: 2600 }, true],
  ]) {
    await page.setViewportSize(viewport);
    await chooseTrunk(page, 'Обе линии');
    await select(page, 'Никита');
    await alignAll(page).click();
    await settle(page);
    const baseline = await targetBaseline(`${label}-visible-target-baseline`, portrait);
    evidence.push(...await visibleParentTargetAnchors(page, seeded, label, portrait, journal, baseline));
    const orientationJournal = await history(page, seeded);
    assert.deepEqual(orientationJournal, journal, `${label}: visible-target cycle changed the full journal.`);
    await fs.writeFile(path.join(output, `${label}-journal-after-targets.json`), JSON.stringify(orientationJournal, null, 2));
  }
  const after = await history(page, seeded);
  assert.deepEqual(after, journal, 'Visible-target selection changed the complete journal.');
  await fs.writeFile(path.join(output, 'parent-row-stability-journal-after.json'), JSON.stringify(after, null, 2));
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded);
  assert.deepEqual(reloaded, journal, 'Visible-target persisted reload changed the complete journal.');
  await fs.writeFile(path.join(output, 'parent-row-stability-journal-reloaded.json'), JSON.stringify(reloaded, null, 2));
  await chooseTrunk(page, 'Обе линии');
  await select(page, 'Никита');
  await alignAll(page).click();
  await settle(page);
  await targetBaseline('parent-row-stability-portrait-reloaded-nikita', true, ['Никита']);
  report.scenarios.push({ name: 'parent-row-stability-core-completed', geometryStates: evidence.length,
    visibleOlegShrekTargetAnchorsPassed: true, completeBeforeAfterReloadEqual: true, coreGeometryPassed: true });
  console.log('PASS: visible Oleg/Shrek pre-click target anchors, two orientations and complete journal/reload.');
  const paths = { name: 'parent-row-stability-secondary-direct-via-paths',
    remainingMilliseconds: 90000 - (Date.now() - startedAt), optional: true };
  report.scenarios.push(paths);
  if (paths.remainingMilliseconds >= 30000) {
    const label = 'parent-row-stability-secondary-portrait', portrait = true;
    await select(page, 'Никита');
    await alignAll(page).click(); // One cold reference; no alignment on transitions.
    await settle(page);
    const before = await inspect(`${label}-nikita-before`, 'Никита', portrait);
    await select(page, 'Ольга');
    const switched = await inspect(`${label}-olga-without-align`, 'Ольга', portrait);
    await select(page, 'Никита');
    const restored = await inspect(`${label}-nikita-return-without-align`, 'Никита', portrait);
    const cross = portrait ? 'y' : 'x';
    const deltas = names.map((name) => ({ name, before: before.state.nodes[name][cross],
      switched: switched.state.nodes[name][cross], restored: restored.state.nodes[name][cross],
      switchDelta: round(switched.state.nodes[name][cross] - before.state.nodes[name][cross]),
      returnDelta: round(restored.state.nodes[name][cross] - before.state.nodes[name][cross]) }));
    const comparison = { name: `${label}-immediate-parent-row-deltas`, crossAxis: cross, deltas };
    report.scenarios.push(comparison);
    comparison.preservedOrigin = parentRowPreservedOrigin(before, switched, portrait);
    stable(before.state, restored.state, names, `${label}: Nikita return did not restore canonical parent-row card slots`);
    comparison.sameFocusReturnExact = true;
    before.passed = switched.passed = restored.passed = true;
    assert.deepEqual(switched.scroll.native, before.scroll.native, `${label}: selection changed native browser scroll/scale.`);
    assert.deepEqual(restored.scroll.native, before.scroll.native, `${label}: returning selection changed native browser scroll/scale.`);
    unchangedRowViewports(before.state, switched.state, names, `${label}: parent-row viewport changed`);
    unchangedRowViewports(before.state, restored.state, names, `${label}: return parent-row viewport changed`);
    // The indirect path starts from that exact same live Nikita baseline, not
    // another alignment/reload with a conveniently different row pan.
    const required = [...names, 'Никита', 'Ольга', 'Анастасия'];
    stable(before.state, restored.state, required, `${label}: via path did not start from the same cold baseline`);
    await select(page, 'Анастасия');
    const viaAnastasia = await inspect(`${label}-via-anastasia-without-align`, 'Анастасия', portrait);
    await select(page, 'Ольга');
    const viaOlga = await inspect(`${label}-olga-via-anastasia-without-align`, 'Ольга', portrait);
    const pathComparison = { name: `${label}-direct-versus-via-anastasia`,
      baseline: before.name, direct: switched.name, restoredBaseline: restored.name,
      via: [viaAnastasia.name, viaOlga.name], sameBaselineWithoutRealignment: true,
      requiredCardDeltas: required.map((name) => ({ name,
        x: round(viaOlga.state.nodes[name].x - switched.state.nodes[name].x),
        y: round(viaOlga.state.nodes[name].y - switched.state.nodes[name].y) })) };
    report.scenarios.push(pathComparison);
    stable(switched.state, viaOlga.state, required,
      `${label}: final Olga geometry differs for direct Nikita→Olga versus Nikita→Anastasia→Olga`);
    unchangedRowViewports(switched.state, viaOlga.state, required, `${label}: final Olga path changed row viewports`);
    assert.deepEqual(viaAnastasia.scroll.native, before.scroll.native, `${label}: Anastasia path changed native scroll/scale.`);
    assert.deepEqual(viaOlga.scroll.native, switched.scroll.native, `${label}: final Olga path changed native scroll/scale.`);
    viaAnastasia.passed = viaOlga.passed = pathComparison.passed = true;
    const orientationJournal = await history(page, seeded);
    assert.deepEqual(orientationJournal, journal, `${label}: completed direct/via cycle changed the full journal.`);
    await fs.writeFile(path.join(output, `${label}-journal-after-paths.json`), JSON.stringify(orientationJournal, null, 2));
    paths.status = 'passed';
    console.log(`PASS: ${label} direct/via Olga paths have identical final geometry from the same baseline.`);
  } else {
    paths.status = 'unrun';
    paths.reason = 'Latest Oleg/Shrek core and complete reload take priority; insufficient remaining budget for the older direct/via regression.';
  }
  const remainingMilliseconds = 90000 - (Date.now() - startedAt);
  const keyboard = remainingMilliseconds >= 18000 ? await parentRowKeyboard(page, seeded, journal, names) : {
    name: 'parent-row-stability-keyboard-unrun', status: 'unrun', remainingMilliseconds,
    reason: 'Core direct/via geometry and reload take priority; insufficient remaining finite budget for optional keyboard checks.' };
  if (keyboard.status === 'unrun') report.scenarios.push(keyboard);
  for (const entry of evidence) {
    entry.paintedRects = await parentRowPaintedRects(page, entry.state, entry.paintedNames || names);
    for (const card of entry.paintedRects) {
      assert.ok(card.paintedAvatarRect, `${entry.name}: ${card.name} has no actual painted avatar bounds.`);
      for (const dimension of ['x', 'y', 'width', 'height']) assert.ok(
        Math.abs(card.paintedAvatarRect[dimension] - card.expectedAvatarRect[dimension]) <= 2.5,
        `${entry.name}: painted ${card.name} ${dimension} disagrees with its physical semantic rectangle.`);
    }
  }
  await refinementCheckpoint(page, 'parent-row-stability-after-painted-rects-errors');
  assert.deepEqual(await history(page, seeded), journal, 'Passive painted-rect inspection changed history.');
  report.scenarios.push({ name: 'parent-row-stability-summary', evidence: evidence.map((entry) => entry.name),
    selected: ['Олег', 'Шрек', 'Олег'], records: journal.length,
    journalSha256: crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex'),
    completeBeforeAfterReloadEqual: true, oneInitialAlignPerOrientation: true,
    secondaryDirectViaStatus: paths.status,
    directAndViaAnastasiaOlgaGeometryEqual: paths.status === 'passed',
    sameColdBaselineBeforeEachPath: paths.status === 'passed',
    visibleOlegShrekPreselectionTargetRectsPreserved: true,
    packedRowOriginAndSisterBlockStable: paths.status === 'passed', legitimateSeamAndFatherBlockReorderingAllowed: true,
    paintedAvatarRectsVerified: true, keyboard: keyboard.name, keyboardOptional: true,
    keyboardStatus: keyboard.status || 'passed',
    scope: 'Visible Oleg/Shrek pre-click target anchoring in BOTH100%/two orientations; optional older direct/via Olga and keyboard guards only if budget remains. Not an ancestor, route, zoom, broad mode or network matrix.' });
  console.log('PASS: actual painted parent-row avatar bounds agree with retained physical card rectangles.');
}

async function sharedParentCohorts(page, seeded) {
  await fs.writeFile(path.join(output, 'shared-parent-cohorts-stored-fixture.json'), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'shared-parent-cohorts-journal-before.json'), JSON.stringify(journal, null, 2));
  await setTreeZoom(page, 100);
  const evidence = [], nataliaFrames = [];
  const inspect = async (title, selected, portrait) => {
    const state = await branchCapture(page, seeded, title), entry = { name: title, selected, state };
    report.scenarios.push(entry); // Preserve target geometry before strict assertions.
    entry.cohort = sharedParentCohortOrder(state, portrait);
    await refinementCheckpoint(page, `${title}-errors`);
    assert.deepEqual(await history(page, seeded), journal, `${title}: read-only cohort browsing wrote domain history.`);
    entry.passed = true; evidence.push(entry);
    return entry;
  };
  for (const [label, viewport, portrait] of [
    ['shared-parent-cohorts-landscape', { width: 2400, height: 1800 }, false],
    ['shared-parent-cohorts-portrait', { width: 1800, height: 2400 }, true],
  ]) {
    await page.setViewportSize(viewport);
    // Core geometry/reload comes before every pixel precondition. Retain this
    // real Natalia PNG now and decode its route only after core coverage.
    await chooseTrunk(page, 'Обе линии');
    await select(page, 'Наталья');
    await alignAll(page).click();
    await settle(page);
    const natalia = await inspect(`${label}-natalia-children-nephew`, 'Наталья', portrait);
    nataliaFrames.push({ entry: natalia, portrait });
    await select(page, 'Никита');
    await alignAll(page).click();
    await settle(page);
    await inspect(`${label}-nikita`, 'Никита', portrait);
    await select(page, 'Наталья');
    await alignAll(page).click();
    await settle(page);
    await inspect(`${label}-natalia-return`, 'Наталья', portrait);
  }
  const after = await history(page, seeded);
  assert.deepEqual(after, journal, 'Shared-parent cohort browsing changed the complete immutable journal.');
  await fs.writeFile(path.join(output, 'shared-parent-cohorts-journal-after.json'), JSON.stringify(after, null, 2));
  await loadRoom(page, seeded);
  const reloaded = await history(page, seeded);
  assert.deepEqual(reloaded, journal, 'Shared-parent cohort persisted reload changed the complete journal.');
  await fs.writeFile(path.join(output, 'shared-parent-cohorts-journal-reloaded.json'), JSON.stringify(reloaded, null, 2));
  await chooseTrunk(page, 'Обе линии');
  await select(page, 'Никита');
  await alignAll(page).click();
  await settle(page);
  await inspect('shared-parent-cohorts-portrait-reloaded-nikita', 'Никита', true);
  const hash = crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex');
  const summary = { name: 'shared-parent-cohorts-summary', selected: ['Наталья', 'Никита', 'Наталья'],
    evidence: evidence.map((entry) => entry.name), records: journal.length, journalSha256: hash,
    completeBeforeAfterReloadEqual: true, childCohortContiguousIndependentOfFocus: true,
    coreGeometryPassed: true, paintedRoutes: [],
    scope: 'Only the compact screenshot family, BOTH mode, two generous orientations; required cards only, no single-mode/remote-ancestor matrix or networking.' };
  report.scenarios.push(summary);
  console.log('PASS: core shared Natalia child cohort under Natalia/Nikita selection, two orientations and complete journal/reload.');
  for (const { entry: frame, portrait } of nataliaFrames) {
    const painted = { name: `${frame.name}-painted-nephew-route`, sourceScreenshot: `${frame.name}.png` };
    report.scenarios.push(painted);
    try {
      painted.lines = await nataliaNephewPixels(page, seeded, frame.state, portrait);
      const witnesses = painted.lines.filter((line) => line.witness);
      if (witnesses.length !== 2 || witnesses.some((line) => line.samples.length < 3)) {
        painted.status = 'unverified';
        painted.reason = 'Insufficient uniquely exposed nephew-route pixels; never counted as a route pass.';
      } else {
        painted.status = witnesses.every((line) => (line.matching >= 3) === line.present) ? 'passed' : 'failed';
        if (painted.status === 'failed') painted.reason = 'Painted nephew route does not prove actual sister Veronika present and unrelated Roman absent.';
      }
    } catch (error) {
      painted.status = 'unverified';
      painted.reason = error.stack || String(error);
    }
    summary.paintedRoutes.push({ name: painted.name, status: painted.status, reason: painted.reason });
  }
  await refinementCheckpoint(page, 'shared-parent-cohorts-after-painted-route-errors');
  assert.deepEqual(await history(page, seeded), journal, 'Painted-route decoding changed the complete immutable journal.');
  summary.nataliaNephewUsesVeronikaNotRoman = summary.paintedRoutes.every((entry) => entry.status === 'passed');
  if (!summary.nataliaNephewUsesVeronikaNotRoman) {
    throw new Error('Core cohort geometry and complete reload passed; painted nephew route failed or remains explicitly unverified. Report partial, not a complete pass.');
  }
  console.log('PASS: actual Veronika-not-Roman nephew route in both retained Natalia screenshots.');
}

async function ancestorCorridor(page, seeded) {
  await fs.writeFile(path.join(output, 'ancestor-corridor-stored-fixture.json'), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)));
  await fs.writeFile(path.join(output, 'ancestor-corridor-journal-before.json'), JSON.stringify(journal, null, 2));
  await setTreeZoom(page, 100);
  await toolbarSearchBrowse(page, seeded, 'ancestor-corridor-current-nikita', 'Никита');
  const evidence = [];
  const inspect = async (label, portrait, mode) => {
    await alignAll(page).click();
    await settle(page);
    const state = await branchCapture(page, seeded, label), entry = { name: label, mode, state };
    report.scenarios.push(entry);
    await refinementCheckpoint(page, `${label}-errors`);
    entry.order = ancestorCorridorOrder(state, seeded, portrait, mode);
    assert.deepEqual(await history(page, seeded), journal, `${label}: view-only corridor checks wrote immutable history.`);
    evidence.push(entry); entry.passed = true;
  };
  for (const [label, viewport, portrait] of [
    ['ancestor-corridor-landscape', { width: 2400, height: 1800 }, false],
    ['ancestor-corridor-portrait', { width: 1800, height: 2400 }, true],
  ]) {
    await page.setViewportSize(viewport);
    await select(page, 'Никита');
    for (const [index, [mode, title]] of [
      ['both', 'Обе линии'], ['mother', 'По матери'], ['father', 'По отцу'],
    ].entries()) {
      await chooseTrunk(page, title);
      await inspect(`${label}-${index}-${mode}`, portrait, mode);
    }
    evidence.push(await nataliaChildrenAndNephew(page, seeded, label, portrait, journal));
  }
  await fs.writeFile(path.join(output, 'ancestor-corridor-journal-after.json'), JSON.stringify(await history(page, seeded), null, 2));
  await loadRoom(page, seeded);
  assert.deepEqual(await history(page, seeded), journal, 'Corridor persisted reload changed the complete journal.');
  await fs.writeFile(path.join(output, 'ancestor-corridor-journal-reloaded.json'), JSON.stringify(await history(page, seeded), null, 2));
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, 'ancestor-corridor-reload-nikita', 'Никита');
  await inspect('ancestor-corridor-portrait-reloaded-both', true, 'both');
  const hash = crypto.createHash('sha256').update(JSON.stringify(journal)).digest('hex');
  report.scenarios.push({ name: 'ancestor-corridor-summary', evidence: evidence.map((entry) => entry.name),
    selected: ['Никита', 'Наталья'], records: journal.length, journalSha256: hash, completeBeforeAfterReloadEqual: true,
    nataliaDirectChildrenContiguous: true, nephewUsesRelatedVeronikaNotRoman: true,
    scope: 'Finite BOTH ancestor corridor, canonical siblings, Natalia child grouping and one painted-nephew route; not phone or networking.' });
  console.log('PASS: finite ancestor corridor plus Natalia direct-child grouping/Veronika nephew route, two orientations and complete journal/reload.');
}

// A finite screenshot-family oracle. Modes may reorder/center other cards;
// only maternal-before-paternal inequalities are shared across mode paths.
function descendantBranchOrder(state, seeded, selectedId, portrait, mode) {
  const axis = portrait ? 'y' : 'x', along = portrait ? 'x' : 'y';
  for (const person of seeded.people) assert.ok(state.nodes[person.name], `${state.title}: ${person.name} is clipped.`);
  const rows = Object.fromEntries([1, 2, 3].map((generation) => [generation, order(state, generation, portrait)]));
  for (const generation of [1, 2, 3]) assert.equal(rows[generation].length,
    seeded.people.filter((person) => person.generation === generation).length,
    `${state.title}: incomplete generation ${generation}.`);
  const pairs = [
    ['lydia', 'valentina', 'nikita'],
    ['gennady', 'valentina', 'nikita'],
    ['lydia', 'gennady', 'natalia/veronika'],
    ['natalia', 'oleg', 'root'],
    ['natalia', 'nekto', 'anastasia'],
    ['veronika', 'roman', 'nikita'],
  ];
  const inequalities = pairs.map(([maternal, paternal, commonDescendant]) => {
    const mother = state.nodes[seeded.names[maternal]], father = state.nodes[seeded.names[paternal]];
    assert.ok(Math.abs(mother[along] - father[along]) <= 1.5,
      `${state.title}: ${maternal}/${paternal} are not on their common generation row.`);
    assert.ok(mother[axis] < father[axis] - 1.5,
      `${state.title}: maternal ${seeded.names[maternal]} must precede paternal ${seeded.names[paternal]} on physical ${axis}, via ${commonDescendant}.`);
    return { maternal, paternal, commonDescendant, maternalCoordinate: mother[axis], paternalCoordinate: father[axis] };
  });
  let adjacency = null;
  if (mode === 'both') {
    // Only an actual selected child's parent seam may change member order.
    // Roman focus instead compacts canonical whole partner blocks.
    const child = { root: 'root', anastasia: 'anastasia', nikita: 'nikita' }[selectedId];
    if (child) adjacency = { commonChild: child, ...trunkParentAdjacency(state, seeded, child, portrait) };
    if (selectedId === 'roman') adjacency = { commonChild: 'nikita', ...trunkPartnerBlocks(state, seeded, portrait) };
    if (selectedId === 'gennady') {
      assert.equal(rows[1].indexOf('Геннадий'), rows[1].indexOf('Лидия') + 1,
        `${state.title}: selected parent Gennady is not immediately after co-parent Lydia.`);
      adjacency = { commonChildren: ['natalia', 'veronika'], mother: 'lydia', father: 'gennady', parentCardsAdjacent: true };
    }
  }
  return { physicalCrossAxis: axis, rows, inequalities, bothModeAdjacency: adjacency };
}

async function descendantBranches(page, seeded, label, portrait) {
  await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(seeded, null, 2));
  await loadRoom(page, seeded);
  const journal = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-before.json`), JSON.stringify(journal, null, 2));
  assert.deepEqual(journal, [...seeded.records].sort((a, b) => a.id.localeCompare(b.id)),
    `${label}: the complete loaded journal differs from the explicit stored fixture.`);
  await refinementCheckpoint(page, `${label}-loaded-errors`);
  await setTreeZoom(page, 100);
  await chooseTrunk(page, 'Обе линии');
  await alignAll(page).click();
  await settle(page);
  const evidence = [];
  const inspect = async (focus, mode, title) => {
    await assertSelected(page, seeded.names[focus]);
    const state = await branchCapture(page, seeded, title);
    const entry = { name: title, selected: focus, mode, state };
    report.scenarios.push(entry); // Preserve raw geometry even when its oracle fails.
    await refinementCheckpoint(page, `${title}-errors`);
    entry.order = descendantBranchOrder(state, seeded, focus, portrait, mode);
    assert.deepEqual(await history(page, seeded), journal, `${title}: browsing changed a complete immutable record or parent link.`);
    entry.passed = true;
    evidence.push(entry);
  };
  for (const focus of ['valentina', 'gennady', 'roman', 'nikita']) {
    await toolbarSearchBrowse(page, seeded, `${label}-${focus}`, seeded.names[focus]);
    for (const [index, [mode, title]] of [
      ['both', 'Обе линии'], ['mother', 'По матери'], ['father', 'По отцу'], ['both', 'Обе линии'],
    ].entries()) {
      await chooseTrunk(page, title);
      await inspect(focus, mode, `${label}-${focus}-${index}-${mode}`);
    }
  }
  // Both-mode parent adjacency is feasible separately for each selected child;
  // never require Natalia to be adjacent to both fathers simultaneously.
  for (const focus of ['root', 'anastasia']) {
    await toolbarSearchBrowse(page, seeded, `${label}-both-${focus}`, seeded.names[focus]);
    await inspect(focus, 'both', `${label}-both-${focus}-parent-adjacency`);
  }
  const trusted = await page.evaluate(() => ({
    mouseUps: window.__canvasPrimaryEvents.filter((event) => event.type === 'mouseup').length,
    allPrimaryTrusted: window.__canvasPrimaryEvents.every((event) => event.trusted),
  }));
  assert.ok(trusted.mouseUps >= 30 && trusted.allPrimaryTrusted,
    `${label}: search and mode cycles did not use trusted real browser input.`);
  const finalJournal = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-after.json`), JSON.stringify(finalJournal, null, 2));
  assert.deepEqual(finalJournal, journal, `${label}: the complete journal changed after view-only browsing.`);
  // Reload persisted records before closing the tab; never rely on closure to save.
  await loadRoom(page, seeded);
  const reloadedJournal = await history(page, seeded);
  await fs.writeFile(path.join(output, `${label}-journal-reloaded.json`), JSON.stringify(reloadedJournal, null, 2));
  assert.deepEqual(reloadedJournal, journal, `${label}: durable reload changed a complete record or parent link.`);
  await setTreeZoom(page, 100);
  await chooseTrunk(page, 'Обе линии');
  await toolbarSearchBrowse(page, seeded, `${label}-reloaded-nikita`, 'Никита');
  await alignAll(page).click();
  await settle(page);
  await inspect('nikita', 'both', `${label}-reloaded-nikita-both`);
  const hash = (records) => crypto.createHash('sha256').update(JSON.stringify(records)).digest('hex');
  report.scenarios.push({ name: `${label}-descendant-branches-summary`, evidence: evidence.map((entry) => entry.name), trusted,
    nearestCommonDescendant: 'nikita', maternalAncestors: ['lydia', 'gennady'], paternalAncestor: 'valentina',
    completeJournal: { records: journal.length, beforeSha256: hash(journal), afterSha256: hash(finalJournal), reloadSha256: hash(reloadedJournal) },
    wholeJournalUnchanged: true, linksAndDomainRecordsUnchanged: true, reloadUnchanged: true, networkIsolated: true,
    modeContract: 'Pair inequalities only; unrelated order and centering may change between modes.',
    limitation: 'Finite 100% local screenshot-family geometry, not arbitrary graphs, painted-route coverage, phone hardware, or network synchronization.' });
  console.log(`PASS: ${label} descendant maternal/paternal inequalities through real search/mode cycles, compatible both-mode parent adjacency and complete journal/reload equality.`);
}

async function viewportAlignment(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), cross = portrait ? 'y' : 'x';
  const evidence = [];
  for (const percent of [100, 150]) {
    await setTreeZoom(page, percent);
    await chooseTrunk(page, 'Обе линии');
    await select(page, 'Ольга');
    await alignAll(page).click();
    await settle(page);
    const centered = await branchSnapshot(page, seeded, `${label}-${percent}-manual-centered`);
    // Separate generation scroll histories: selected and ancestor lanes are
    // intentionally displaced by different real wheel amounts before selection.
    await crossWheel(page, seeded, portrait, 3, 78, `${label}-${percent}-selected-pan`);
    await crossWheel(page, seeded, portrait, 2, -48, `${label}-${percent}-parents-pan`);
    const displaced = await branchSnapshot(page, seeded, `${label}-${percent}-visible-displaced`);
    assert.ok(Math.abs(groupCenter(displaced, ['Ольга'], portrait) - sceneCenter(displaced, portrait)) > 55,
      'The selected person must genuinely be away from viewport center for this regression.');
    await select(page, 'Сестра Ольги');
    await select(page, 'Ольга');
    const visible = await branchSnapshot(page, seeded, `${label}-${percent}-visible-selection-unchanged`);
    stable(displaced, visible, Object.keys(displaced.nodes), 'Selecting fully visible candidates realigned a lane unnecessarily');
    await alignAll(page).click();
    await settle(page);
    const manual = await branchCapture(page, seeded, `${label}-${percent}-manual-align-even-visible`);
    assert.ok(Math.abs(groupCenter(manual, ['Ольга'], portrait) - sceneCenter(manual, portrait)) <= 2,
      'Align Everything did not center a visible selected person.');
    assert.ok(Math.abs(groupCenter(manual, ['Олег', 'Наталья'], portrait) - sceneCenter(manual, portrait)) <= 2,
      'Align Everything did not center the visible preferred-parent pair.');
    for (const names of [['Тестовый отец'], ['Геннадий', 'Лидия']]) assert.ok(
      Math.abs(groupCenter(manual, names, portrait) - sceneCenter(manual, portrait)) <= 2,
      `Align Everything did not center the relevant ancestor lane ${names.join('/')}.`);
    assert.ok(Math.abs(manual.nodes['Ольга'][cross] - displaced.nodes['Ольга'][cross]) > 55 &&
      Math.abs(manual.nodes['Олег'][cross] - displaced.nodes['Олег'][cross]) > 30,
    'Manual alignment did not actually undo both independent lane pans.');

    await crossWheel(page, seeded, portrait, 3, 78, `${label}-${percent}-offscreen-focus-pan`);
    await select(page, 'Сестра Ольги'); // The subsequent Olga click must change focus while keeping the same parents/layout.
    const offscreenBefore = await branchSnapshot(page, seeded, `${label}-${percent}-before-hiding-parent-candidates`);
    const target = center(offscreenBefore.nodes['Наталья']);
    const distance = (portrait ? offscreenBefore.canvas.height : offscreenBefore.canvas.width) + 400;
    await page.mouse.move(target.x, target.y);
    await page.mouse.wheel(portrait ? 0 : distance, portrait ? distance : 0);
    await settle(page);
    let hidden = await branchSnapshot(page, seeded, `${label}-${percent}-parent-candidates-offscreen`);
    if (hidden.nodes['Олег'] || hidden.nodes['Наталья']) {
      // If the canonical family is at the far end of this long lane, use the
      // opposite native scroll boundary instead of accepting clipped evidence.
      await page.mouse.wheel(portrait ? 0 : -distance * 2, portrait ? -distance * 2 : 0);
      await settle(page);
    }
    hidden = await branchCapture(page, seeded, `${label}-${percent}-parent-candidates-offscreen`);
    assert.ok(!hidden.nodes['Олег'] && !hidden.nodes['Наталья'], 'Fixture did not hide both preferred-parent candidates.');
    await select(page, 'Ольга');
    const restored = await branchCapture(page, seeded, `${label}-${percent}-offscreen-candidates-viewport-centered`);
    assert.ok(Math.abs(groupCenter(restored, ['Олег', 'Наталья'], portrait) - sceneCenter(restored, portrait)) <= 2,
      'Offscreen parent pair followed displaced selected node instead of viewport center.');
    stable(hidden, restored, Object.keys(hidden.nodes).filter((name) => hidden.nodes[name].generation !== 2),
      'Automatic parent reveal disturbed an already-visible independent generation');
    assert.ok(Math.abs(groupCenter(restored, ['Ольга'], portrait) - sceneCenter(restored, portrait)) > 55,
      'Auto reveal incorrectly recentered the already-visible selected person.');
    evidence.push({ percent, centered, displaced, visible, manual, hidden, restored });
  }
  assert.deepEqual(await history(page, seeded), journal, 'Viewport/manual alignment wrote the room journal.');
  report.scenarios.push({ name: `${label}-viewport-center-auto-only-offscreen-and-manual-force`, evidence, wholeJournalUnchanged: true });
  console.log(`PASS: ${label} offscreen candidates center on viewport, visible lanes unchanged, manual alignment forces both lanes.`);
}

function assertFocalTransform(before, after, focal, ratio, message, requiredGenerations = 3) {
  const witnesses = Object.keys(before.nodes).filter((name) => {
    const box = before.nodes[name], transformed = {
      x: focal.x + (box.x - focal.x) * ratio, y: focal.y + (box.y - focal.y) * ratio,
      width: box.width * ratio, height: box.height * ratio,
    };
    const canvas = after.canvas;
    return transformed.x >= canvas.x + 2 && transformed.y >= canvas.y + 2 &&
      transformed.x + transformed.width <= canvas.x + canvas.width - 2 &&
      transformed.y + transformed.height <= canvas.y + canvas.height - 2;
  });
  assert.ok(new Set(witnesses.map((name) => before.nodes[name].generation)).size >= requiredGenerations,
    `${message}: need ${requiredGenerations} independently positioned generation witnesses, got ${witnesses.join(', ')}.`);
  const errors = {};
  for (const name of witnesses) {
    assert.ok(after.nodes[name], `${message}: transformed fully-visible witness ${name} disappeared.`);
    errors[name] = {};
    for (const axis of ['x', 'y']) {
      const expected = focal[axis] + (before.nodes[name][axis] - focal[axis]) * ratio;
      errors[name][axis] = round(after.nodes[name][axis] - expected);
      assert.ok(Math.abs(errors[name][axis]) <= 2,
        `${message}: ${name}.${axis} has extra lane/bounds drift ${errors[name][axis]}px after independently panned zoom.`);
    }
    for (const extent of ['width', 'height']) assert.ok(Math.abs(after.nodes[name][extent] - before.nodes[name][extent] * ratio) <= 1.5,
      `${message}: ${name}.${extent} did not scale uniformly.`);
  }
  return { witnesses, errors };
}

async function independentLaneZoom(page, seeded, label, portrait) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page);
  await alignAll(page).click();
  await settle(page);
  const pans = [];
  for (const [generation, delta] of [[1, 34], [2, -76], [3, 58]]) {
    pans.push(await crossWheel(page, seeded, portrait, generation, delta, `${label}-g${generation}-independent-pan`));
  }
  const before = await branchCapture(page, seeded, `${label}-independently-panned-100`);
  const focal = { x: before.canvas.x + before.canvas.width / 2, y: before.canvas.y + before.canvas.height / 2 };
  await controlWheel(page, focal, -1000);
  assert.equal(await zoomPercent(page), 150);
  const enlarged = await branchCapture(page, seeded, `${label}-independently-panned-150`);
  const enlargement = assertFocalTransform(before, enlarged, focal, 1.5, `${label}: 100→150%`, 4);
  assert.ok(enlargement.witnesses.includes('Тестовый отец'), 'Singleton/boundary row was omitted from zoom-drift assertions.');
  await controlWheel(page, focal, 1000);
  assert.equal(await zoomPercent(page), 100);
  const reduced = await branchCapture(page, seeded, `${label}-independently-panned-back-100`);
  const reduction = assertFocalTransform(enlarged, reduced, focal, 1 / 1.5, `${label}: 150→100%`, 4);
  stable(before, reduced, Object.keys(before.nodes), `${label}: reversible zoom lost independent lane offsets`);
  await setTreeZoom(page, 150);
  const toolbarEnlarged = await branchCapture(page, seeded, `${label}-independently-panned-toolbar-150`);
  const toolbarExpansion = assertFocalTransform(reduced, toolbarEnlarged, focal, 1.5, `${label}: toolbar 100→150%`, 4);
  await zoomReset(page).click();
  await settle(page);
  const toolbarReset = await branchSnapshot(page, seeded, `${label}-independently-panned-toolbar-reset`);
  stable(before, toolbarReset, Object.keys(before.nodes), `${label}: toolbar zoom/reset lost independent lane offsets`);
  await assertNoGestureSelection(page, 'Ольга');
  const ordinary = await crossWheel(page, seeded, portrait, 2, 28, `${label}-ordinary-wheel-after-zoom`);
  const event = await page.evaluate(() => window.__canvasWheelEvents.at(-1));
  assert.ok(event.trusted && !event.ctrl && event.prevented, 'Ordinary wheel no longer belongs to the tree after zoom.');
  assert.deepEqual(await browserZoomState(page), browserBefore, 'Independent lane zoom altered native browser zoom/scroll.');
  assert.deepEqual(await history(page, seeded), journal, 'Independent lane zoom/pan wrote view state to the journal.');
  report.scenarios.push({ name: `${label}-independent-lane-focal-transform-no-bounds-drift`, pans, before, enlarged, reduced,
    focal, enlargement, reduction, toolbarEnlarged, toolbarExpansion, toolbarReset, ordinary,
    wholeJournalUnchanged: true, nativeBrowserUnchanged: true });
  console.log(`PASS: ${label} independently panned levels + singleton retain exact 100→150→100% focal transforms; ordinary wheel intact.`);
}

async function occupiedParentGuard(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), evidence = [];
  for (const [name, disabled, enabled] of [['Ольга', ['Отца', 'Мать'], null], ['Анастасия', ['Мать'], 'Отца']]) {
    await openBiography(page, name, true);
    const add = page.getByRole('button', { name: 'Добавить родственника', exact: true });
    await revealBiography(page, add);
    await add.click();
    const dialog = page.getByRole('alertdialog'), kind = dialog.getByRole('button', { name: /^Кого добавить/ });
    const initialKind = await kind.ariaSnapshot();
    await kind.click();
    const options = {};
    for (const role of disabled) {
      const option = page.getByRole('menuitem', { name: role, exact: true });
      await option.waitFor();
      options[role] = await option.ariaSnapshot();
      const box = await option.boundingBox();
      assert.ok(box, `${label}: occupied ${role} is not visible in the initial Add menu.`);
      await page.mouse.click(center(box).x, center(box).y);
      await sleep(180);
      assert.ok(await option.isVisible(), `${label}: occupied ${role} accepted a pointer click and closed the role menu.`);
    }
    await page.screenshot({ path: path.join(output, `${label}-${name}-occupied-parent-options.png`), animations: 'disabled' });
    if (enabled) {
      const option = page.getByRole('menuitem', { name: enabled, exact: true });
      options[enabled] = await option.ariaSnapshot();
      await option.click();
      assert.match(await kind.ariaSnapshot(), new RegExp(enabled), 'The empty father slot became unavailable together with the occupied mother.');
    } else {
      // On mobile Flutter's popup need not handle desktop Escape. Dismiss its
      // real modal barrier by pointer instead, without choosing an enabled role.
      await page.mouse.click(3, 3);
      await page.getByRole('menuitem').first().waitFor({ state: 'hidden' });
      assert.equal(await kind.ariaSnapshot(), initialKind, `${label}: an occupied role changed the dialog's current kind.`);
    }
    await page.screenshot({ path: path.join(output, `${label}-${name}-occupied-parent-guard.png`), animations: 'disabled' });
    await dialog.getByRole('button', { name: 'Отмена', exact: true }).click();
    await closeBiography(page);
    assert.deepEqual(await history(page, seeded), journal, 'Inspecting/cancelling occupied-parent options wrote the journal.');
    evidence.push({ person: name, initialKind, options, disabled, enabled });
  }
  report.scenarios.push({ name: `${label}-occupied-parent-options-blocked-immediately`, evidence, wholeJournalUnchanged: true });
  console.log(`PASS: ${label} occupied parent menu entries reject real clicks immediately; missing father remains selectable.`);
}

async function independentlyPannedPinch(page, seeded, label) {
  await loadRoom(page, seeded);
  const journal = await history(page, seeded), browserBefore = await browserZoomState(page);
  await crossWheel(page, seeded, true, 2, -36, `${label}-parent-pan-before-pinch`);
  await crossWheel(page, seeded, true, 3, 42, `${label}-focus-pan-before-pinch`);
  const before = await branchCapture(page, seeded, `${label}-independently-panned-pinch-100`);
  const focal = center(before.nodes['Ольга']);
  const cdp = await page.context().newCDPSession(page);
  try {
    await pinch(page, cdp, focal, 40, 60, true);
    assert.equal(await zoomPercent(page), 150, 'Trusted pinch stopped working after independent lane pans.');
    const enlarged = await branchCapture(page, seeded, `${label}-independently-panned-pinch-150`);
    const expansion = assertFocalTransform(before, enlarged, focal, 1.5, `${label}: independent pinch`, 1);
    await assertNoGestureSelection(page, 'Ольга');
    await pinch(page, cdp, focal, 60, 40);
    assert.equal(await zoomPercent(page), 100);
    const reduced = await branchCapture(page, seeded, `${label}-independently-panned-pinch-restored-100`);
    stable(before, reduced, Object.keys(before.nodes), 'Pinch round trip lost independently panned generation positions');
    const events = await page.evaluate(() => window.__canvasTouchEvents);
    assert.ok(events.some((event) => event.trusted && event.touches === 2 && event.type === 'touchmove'));
    assert.deepEqual(await browserZoomState(page), browserBefore);
    assert.deepEqual(await history(page, seeded), journal, 'Pinch/row panning wrote a view-state journal edit.');
    report.scenarios.push({ name: `${label}-trusted-pinch-after-independent-row-panning`, before, enlarged, reduced,
      focal, expansion, trustedTwoContactEvents: true, remainingFingerFrozen: true, wholeJournalUnchanged: true });
  } finally { await cdp.detach(); }
}

async function roomPage(browser, seeded, viewport, mobile = false, isolated = ['compact-search', 'compact-search-mobile', 'compact-search-rotation', 'compact-search-focus-diagnostic', 'parent-adjacency', 'partner-proximity', 'own-partner-priority', 'clipped-selection-centering', 'descendant-branches', 'ancestor-corridor', 'shared-parent-cohorts', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship', 'collateral-child-ranks', 'personal-family-controls', 'ordering-guest-controls', 'editor-refinements', 'editor-refinements-desktop'].includes(suite)) {
  const context = await browser.newContext({ viewport,
    deviceScaleFactor: suite === 'minimum-avatar-zoom' && mobile ? 3 : 1,
    isMobile: mobile, hasTouch: mobile,
    reducedMotion: ['selection-frame-stability', 'own-partner-priority', 'clipped-selection-centering'].includes(suite) ? 'no-preference' : 'reduce', serviceWorkers: 'block' });
  if (isolated) {
    // Explicit local UI fixture: public transport is not part of this focused run.
    await context.route('**/*', (route) => {
      const url = new URL(route.request().url());
      // These finite suites require the existing local release build, including
      // its renderer/fonts: do not make even asset requests to public services.
      const localAssetsOnly = ['partner-proximity', 'own-partner-priority', 'clipped-selection-centering', 'descendant-branches', 'ancestor-corridor', 'shared-parent-cohorts', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship', 'collateral-child-ranks', 'personal-family-controls', 'ordering-guest-controls', 'editor-refinements', 'editor-refinements-desktop'].includes(suite);
      const renderer = !localAssetsOnly && url.hostname === 'www.gstatic.com' && url.pathname.startsWith('/flutter-canvaskit/');
      const font = !localAssetsOnly && ['fonts.gstatic.com', 'fonts.googleapis.com'].includes(url.hostname);
      const allowed = url.origin === origin || renderer || font;
      if (tracedLocalLayout) report.network.http.push({ url: url.href, allowed,
        method: route.request().method(), resourceType: route.request().resourceType() });
      return allowed ? route.continue() : route.abort('internetdisconnected');
    });
    await context.routeWebSocket('**/*', (socket) => {
      if (tracedLocalLayout) report.network.webSockets.push({ url: socket.url(), blocked: true });
      socket.close({ code: 1000, reason: 'Isolated canvas UI fixture' });
    });
  }
  await context.addInitScript(({ expectedOrigin, entries, membership }) => {
    window.__canvasFirstFrame = false;
    window.addEventListener('flutter-first-frame', () => { window.__canvasFirstFrame = true; }, { once: true });
    window.__canvasContextMenus = [];
    window.__canvasMiddleEvents = [];
    window.__canvasPrimaryEvents = [];
    window.__canvasWheelEvents = [];
    window.__canvasTouchEvents = [];
    // Passive observers never cancel input or synthesize app events.
    document.addEventListener('wheel', (event) => {
      const entry = { x: event.clientX, y: event.clientY, deltaY: event.deltaY,
        ctrl: event.ctrlKey, trusted: event.isTrusted, prevented: null };
      window.__canvasWheelEvents.push(entry);
      setTimeout(() => { entry.prevented = event.defaultPrevented; }, 0);
    }, { capture: true, passive: true });
    for (const type of ['touchstart', 'touchmove', 'touchend', 'touchcancel']) {
      document.addEventListener(type, (event) => window.__canvasTouchEvents.push({ type,
        touches: event.touches.length, trusted: event.isTrusted,
        points: [...event.touches].map((point) => ({ id: point.identifier, x: point.clientX, y: point.clientY })) }),
      { capture: true, passive: true });
    }
    for (const type of ['pointerdown', 'pointermove', 'pointerup', 'mousedown', 'mouseup']) {
      document.addEventListener(type, (event) => {
        if (event.button !== 0 && event.buttons !== 1) return;
        window.__canvasPrimaryEvents.push({ type, x: event.clientX, y: event.clientY,
          button: event.button, buttons: event.buttons, trusted: event.isTrusted, time: event.timeStamp });
      }, { capture: true, passive: true });
    }
    for (const type of ['pointerdown', 'pointermove', 'pointerup', 'mousedown', 'auxclick']) {
      document.addEventListener(type, (event) => {
        if (event.button !== 1 && event.buttons !== 4) return;
        const entry = { type, x: event.clientX, y: event.clientY, button: event.button,
          buttons: event.buttons, trusted: event.isTrusted, prevented: null };
        window.__canvasMiddleEvents.push(entry);
        setTimeout(() => { entry.prevented = event.defaultPrevented; }, 0);
      }, { capture: true, passive: true });
    }
    // Passive observation only: the app, not this driver, must suppress the node menu.
    document.addEventListener('contextmenu', (event) => {
      const entry = { x: event.clientX, y: event.clientY, trusted: event.isTrusted,
        cancelable: event.cancelable, prevented: null, target: event.target?.tagName || null };
      window.__canvasContextMenus.push(entry);
      setTimeout(() => { entry.prevented = event.defaultPrevented; }, 0);
    }, { capture: true, passive: true });
    if (location.origin === expectedOrigin && localStorage.getItem(membership) === null) {
      for (const [key, value] of entries) localStorage.setItem(key, value);
    }
  }, { expectedOrigin: origin, entries: seeded.entries, membership: `${seeded.roomPrefix}membership` });
  const page = await context.newPage();
  page.on('pageerror', (error) => report.pageErrors.push(error.message));
  page.on('console', (message) => {
    if (message.type() === 'error') report.consoleErrors.push(message.text());
    if (tracedLocalLayout) report.consoleMessages.push({ type: message.type(), text: message.text(), location: message.location() });
    if ((suite.startsWith('editor-refinements') || tracedLocalLayout) && flutterFailure.test(message.text())) {
      (report.flutterErrors ??= []).push({ type: message.type(), text: message.text() });
    }
  });
  return page;
}

(async () => {
  await fs.mkdir(output, { recursive: true });
  if (tracedLocalLayout) {
    assert.deepEqual(await fs.readdir(output), [], 'Use a new empty artifacts directory; finite layout suites never overwrite failed evidence.');
  } else {
    await fs.rm(path.join(output, 'failure.png'), { force: true });
  }
  const seed = fixture();
  seed.operation({ type: 'addPhoto', personId: 'root', itemId: 'canvas-avatar',
    dataUrl: `data:image/png;base64,${(await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'))).toString('base64')}`,
    caption: 'Real PNG avatar regression', afterId: null, beforeId: null });
  seed.value('root', 'avatarPhotoId', 'canvas-avatar');
  const seeded = seed.finish();
  report.fixture = { room: seeded.room, actor: seeded.actor, people: seeded.people, immutableOperations: seeded.records.length };
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  let page;
  try {
    if (!['own-partner-priority', 'clipped-selection-centering', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship'].includes(suite)) page = await roomPage(browser, seeded, { width: 1440, height: 900 });
    for (const [label, viewport, portrait] of ['all', 'canvas'].includes(suite) ? [
      ['landscape', { width: 1440, height: 900 }, false],
      ['portrait', { width: 1000, height: 1300 }, true],
    ] : []) {
      await page.setViewportSize(viewport);
      await loadRoom(page, seeded);
      await capture(page, seeded, `${label}-canvas-links-and-blocks`);
      await avatarVisual(page, seeded, label);
      await directChildConnections(page, seeded, label, portrait);
      await mouseNavigation(page, seeded, label, portrait);
      await wheelOwnership(page, seeded, label, portrait, 3);
      await wheelOwnership(page, seeded, label, portrait, 4);
      await repeatedSelections(page, seeded, label, portrait);
      await biographyBySecondaryClick(page, seeded, label);
      await wheelAtBoundary(page, seeded, label, portrait);
      console.log(`PASS: ${label} real wheel ownership/edge isolation; 18 selections return canonical same-current orders; correct secondary-click biography/menu; avatar pixels.`);
    }
    const establishedPage = page;
    if (suite === 'middle-pan-portrait') {
      const paddingFixture = fixture({ family: 'canonical-alignment' }).finish();
      page = await roomPage(browser, paddingFixture, { width: 1700, height: 2100 });
      await middlePaddingAndBounds(page, paddingFixture, 'portrait-padding-singleton', true);
      await page.context().close();
      const navigationFixture = fixture().finish();
      page = await roomPage(browser, navigationFixture, { width: 1000, height: 1300 });
      await desktopZoom(page, navigationFixture, 'portrait', true);
      await page.context().close();
    }
    if (['all', 'middle-pan'].includes(suite)) {
      for (const [label, viewport, portrait] of [
        ['landscape', { width: 1440, height: 900 }, false],
        ['portrait', { width: 1000, height: 1300 }, true],
      ]) {
        if (suite === 'middle-pan') {
          const navigationFixture = fixture().finish();
          page = await roomPage(browser, navigationFixture, viewport);
          await mouseNavigation(page, navigationFixture, label, portrait);
          const ordinary = await crossWheel(page, navigationFixture, portrait, 3, 24, `${label}-100-percent-independent-cross-wheel`);
          await crossWheel(page, navigationFixture, portrait, 3, -ordinary.appliedDelta, `${label}-100-percent-cross-wheel-restored`);
          await wheelOwnership(page, navigationFixture, label, portrait, 3);
          await wheelOwnership(page, navigationFixture, label, portrait, 4);
          await desktopZoom(page, navigationFixture, label, portrait);
          await page.context().close();
        }
        const paddingFixture = fixture({ family: 'canonical-alignment' }).finish();
        page = await roomPage(browser, paddingFixture, portrait ? { width: 1700, height: 2100 } : { width: 2100, height: 1700 });
        await middlePaddingAndBounds(page, paddingFixture, `${label}-padding-singleton`, portrait);
        await page.context().close();
      }
    }
    if (suite.startsWith('editor-refinements')) {
      for (const [label, viewport, mobile] of [
        ['editor-phone-390x844', { width: 390, height: 844 }, true],
        ['editor-desktop-1440x900', { width: 1440, height: 900 }, false],
      ].filter(([, , mobile]) => suite !== 'editor-refinements-desktop' || !mobile)) {
        const refinementFixture = editorRefinementFixture();
        page = await roomPage(browser, refinementFixture, viewport, mobile, true);
        await editorRefinements(page, refinementFixture, label, mobile);
        await page.context().close();
      }
    }
    if (suite === 'personal-family-controls') {
      report.fixture = { profiles: [] };
      for (const [label, viewport, mobile] of [
        ['personal-desktop-1440x900', { width: 1440, height: 900 }, false],
        ['personal-phone-390x844', { width: 390, height: 844 }, true],
      ]) {
        const controls = fixture({ family: 'personal-family-controls' }).finish();
        report.fixture.profiles.push({ label, family: 'personal-family-controls', room: controls.room, actor: controls.actor });
        await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(controls, null, 2));
        page = await roomPage(browser, controls, viewport, mobile, true);
        await personalFamilyControls(page, controls, label);
        await page.context().close();
      }
    }
    if (suite === 'ordering-guest-controls') {
      report.fixture = { profiles: [] };
      // Keep five generations and the finite mixed-DOB sibling witnesses fully
      // visible; phone coverage below is the actual roster and Add Parent form.
      for (const [label, viewport, portrait] of [
        ['ordering-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['ordering-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const ancestry = fixture({ family: 'personal-ancestry-order' }).finish();
        report.fixture.profiles.push({ label, family: 'personal-ancestry-order', room: ancestry.room, actor: ancestry.actor });
        await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(ancestry, null, 2));
        page = await roomPage(browser, ancestry, viewport, false, true);
        await personalAncestryOrder(page, ancestry, label, portrait);
        await page.context().close();
      }
      const phone = fixture({ family: 'ordering-phone' }).finish(), label = 'ordering-phone-390x844';
      report.fixture.profiles.push({ label, family: 'ordering-phone', room: phone.room, actor: phone.actor });
      await fs.writeFile(path.join(output, `${label}-stored-fixture.json`), JSON.stringify(phone, null, 2));
      page = await roomPage(browser, phone, { width: 390, height: 844 }, true, true);
      await orderingPhoneControls(page, phone, label);
      await page.context().close();
    }
    if (suite === 'collateral-child-ranks') {
      report.fixture = { family: 'trunk-modes', orientations: [] };
      for (const [label, viewport, portrait] of [
        ['collateral-child-ranks-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['collateral-child-ranks-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const rankFixture = fixture({ family: 'trunk-modes' }).finish();
        report.fixture.orientations.push({ label, room: rankFixture.room, actor: rankFixture.actor,
          people: rankFixture.people.map((person) => ({ ...person })), immutableOperations: rankFixture.records.length });
        page = await roomPage(browser, rankFixture, viewport, false, true);
        await collateralChildRanks(page, rankFixture, label, portrait);
        await page.context().close();
      }
    }
    if (suite === 'clipped-selection-centering') {
      const clippedSeed = fixture({ family: 'shared-parent-cohorts' }).finish();
      report.fixture = { family: 'shared-parent-cohorts', room: clippedSeed.room, actor: clippedSeed.actor,
        people: clippedSeed.people, immutableOperations: clippedSeed.records.length };
      await fs.writeFile(path.join(output, 'clipped-selection-stored-fixture.json'), JSON.stringify(clippedSeed, null, 2));
      let timer;
      const deadline = Date.now() + 90000;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, clippedSeed, { width: 2400, height: 1800 }, false, true);
          await clippedSelectionCentering(page, clippedSeed, deadline);
        })(), new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Finite clipped-selection-centering exceeded its 90-second budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(timer); }
    }
    if (suite === 'own-partner-priority') {
      const partnerSeed = fixture({ family: 'shared-parent-cohorts' }).finish();
      report.fixture = { family: 'shared-parent-cohorts', room: partnerSeed.room, actor: partnerSeed.actor,
        people: partnerSeed.people, immutableOperations: partnerSeed.records.length };
      await fs.writeFile(path.join(output, 'own-partner-priority-stored-fixture.json'), JSON.stringify(partnerSeed, null, 2));
      let timer;
      const deadline = Date.now() + 90000;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, partnerSeed, { width: 2400, height: 1800 }, false, true);
          await ownPartnerPriority(page, partnerSeed, deadline);
        })(), new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Finite own-partner-priority exceeded its 90-second budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(timer); }
    }
    if (suite === 'selection-frame-stability') {
      const frameSeed = fixture({ family: 'parent-row-stability' }).finish();
      report.fixture = { family: 'parent-row-stability', room: frameSeed.room, actor: frameSeed.actor,
        people: frameSeed.people, immutableOperations: frameSeed.records.length };
      await fs.writeFile(path.join(output, 'selection-frame-stored-fixture.json'), JSON.stringify(frameSeed, null, 2));
      let timer;
      const deadline = Date.now() + 90000;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, frameSeed, { width: 2600, height: 1900 }, false, true);
          await selectionFrameStability(page, frameSeed, deadline);
        })(), new Promise((_, reject) => {
          timer = setTimeout(() => reject(new Error('Finite selection-frame-stability exceeded its 90-second budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(timer); }
    }
    if (suite === 'explicit-siblings') {
      const desktopSeed = fixture({ family: 'explicit-siblings' }).finish();
      const phoneSeed = fixture({ family: 'explicit-siblings' }).finish();
      report.fixture = { family: 'explicit-siblings', profiles: [desktopSeed, phoneSeed].map((seeded, index) => ({
        label: index ? 'phone-390x844-forms-only' : 'desktop-1440x900-mutations', room: seeded.room,
        actor: seeded.actor, people: seeded.people.map((person) => ({ ...person })), records: seeded.records.length })) };
      await fs.writeFile(path.join(output, 'explicit-siblings-desktop-stored-fixture.json'), JSON.stringify(desktopSeed, null, 2));
      await fs.writeFile(path.join(output, 'explicit-siblings-phone-stored-fixture.json'), JSON.stringify(phoneSeed, null, 2));
      let deadline, phone;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, desktopSeed, { width: 1440, height: 900 }, false, true);
          phone = await roomPage(browser, phoneSeed, { width: 390, height: 844 }, true, true);
          await explicitSiblingsLocal(page, phone, desktopSeed, phoneSeed);
          await Promise.all([page.context().close(), phone.context().close()]);
        })(), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite explicit-siblings exceeded its 150-second browser budget; report partial.')), 150000);
        })]);
      } catch (error) {
        report.failureProfiles = [];
        for (const [label, current, seed] of [['desktop', page, desktopSeed], ['phone', phone, phoneSeed]]) {
          if (!current || current.isClosed()) continue;
          report.failureProfiles.push({ label, semantics: await body(current).catch(() => 'unavailable'),
            completeJournal: await history(current, seed).catch(() => null) });
          await current.screenshot({ path: path.join(output, `explicit-siblings-failure-${label}.png`), animations: 'disabled' }).catch(() => {});
        }
        throw error;
      } finally { clearTimeout(deadline); }
    }
    if (suite === 'step-parent-kinship') {
      const seed = fixture({ family: 'step-parent-kinship' });
      const dataUrl = `data:image/png;base64,${(await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'))).toString('base64')}`;
      for (const id of ['oleg', 'sergey', 'nikita', 'elena']) {
        seed.operation({ type: 'addPhoto', personId: id, itemId: `photo-${id}`, dataUrl,
          caption: 'Identical real PNG: normal, step-parent, cousin, distant controls', afterId: null, beforeId: null });
        seed.value(id, 'avatarPhotoId', `photo-${id}`);
      }
      const kinship = seed.finish();
      report.fixture = { family: 'step-parent-kinship', room: kinship.room, actor: kinship.actor,
        people: kinship.people, immutableOperations: kinship.records.length };
      await fs.writeFile(path.join(output, 'step-parent-kinship-stored-fixture.json'), JSON.stringify(kinship, null, 2));
      // One local room/context, desktop input, two orientations; no extra matrix.
      page = await roomPage(browser, kinship, { width: 1800, height: 1200 }, false, true);
      for (const [label, viewport, portrait] of [
        ['step-parent-kinship-landscape', { width: 1800, height: 1200 }, false],
        ['step-parent-kinship-portrait', { width: 1200, height: 1800 }, true],
      ]) {
        await page.setViewportSize(viewport);
        await stepParentKinship(page, kinship, label, portrait);
      }
      await page.context().close();
    }
    if (suite === 'minimum-avatar-zoom') {
      report.fixture = { family: 'minimum-avatar-zoom', profiles: [] };
      const evidence = [];
      let deadline, lastSeeded;
      try {
        await Promise.race([(async () => {
          const dataUrl = `data:image/png;base64,${(await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'))).toString('base64')}`;
          for (const [label, viewport, mobile] of [
            ['minimum-avatar-desktop-1440x900-dpr1', { width: 1440, height: 900 }, false],
            ['minimum-avatar-phone-390x844-dpr3', { width: 390, height: 844 }, true],
          ]) {
            const seed = fixture({ family: 'minimum-avatar-zoom' });
            seed.operation({ type: 'addPhoto', personId: 'photo-mother', itemId: 'minimum-photo', dataUrl,
              caption: 'Unselected real-photo avatar floor witness', afterId: null, beforeId: null });
            seed.value('photo-mother', 'avatarPhotoId', 'minimum-photo');
            const seeded = seed.finish();
            lastSeeded = seeded;
            report.fixture.profiles.push({ label, room: seeded.room, actor: seeded.actor, people: seeded.people,
              immutableOperations: seeded.records.length, deviceScaleFactor: mobile ? 3 : 1 });
            page = await roomPage(browser, seeded, viewport, mobile, true);
            evidence.push(await minimumAvatarZoom(page, seeded, label, mobile));
            if (!mobile) await page.context().close();
          }
          report.scenarios.push({ name: 'minimum-avatar-zoom-core-completed', profiles: evidence.map((entry) => entry.name),
            corePassed: true, bothCompleteJournalsReloaded: true, physicalMillimetersVerified: false,
            pickerStatus: 'unrun', pickerReason: 'Optional independent-picker coverage is outside this narrow floor case.' });
          const paintResults = [];
          for (const entry of evidence) paintResults.push(await minimumAvatarPaint(page, entry));
          await refinementCheckpoint(page, 'minimum-avatar-after-paint-errors');
          assert.deepEqual(await history(page, lastSeeded), [...lastSeeded.records].sort((a, b) => a.id.localeCompare(b.id)),
            'Passive minimum-avatar pixel inspection changed immutable history.');
          report.scenarios.push({ name: 'minimum-avatar-zoom-paint-summary',
            statuses: evidence.map((entry) => ({ profile: entry.name, paintStatus: entry.paintStatus })),
            physicalMillimetersVerified: false, semanticNominalFloorVerified: true,
            note: 'Actual raster avatar bounds are checked within1.5 CSSpx; nominal4mm sizing is not physical calibration.' });
          assert.ok(paintResults.every(Boolean), 'Minimum-avatar core passed, but actual avatar paint is unverified; report partial.');
          await page.context().close();
        })(), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite minimum-avatar-zoom exceeded its 90-second browser budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(deadline); }
    }
    if (suite === 'parent-row-stability') {
      const rowFixture = fixture({ family: 'parent-row-stability' }).finish();
      report.fixture = { family: 'parent-row-stability', room: rowFixture.room, actor: rowFixture.actor, people: rowFixture.people };
      let deadline;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, rowFixture, { width: 2600, height: 1900 }, false, true);
          await parentRowStability(page, rowFixture);
          await page.context().close();
        })(), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite parent-row-stability exceeded its 90-second browser budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(deadline); }
    }
    if (suite === 'shared-parent-cohorts') {
      const cohort = fixture({ family: 'shared-parent-cohorts' }).finish();
      report.fixture = { family: 'shared-parent-cohorts', room: cohort.room, actor: cohort.actor, people: cohort.people };
      let deadline;
      try {
        await Promise.race([(async () => {
          page = await roomPage(browser, cohort, { width: 2400, height: 1800 }, false, true);
          await sharedParentCohorts(page, cohort);
          await page.context().close();
        })(), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite shared-parent-cohorts exceeded its 90-second browser budget; report partial.')), 90000);
        })]);
      } finally { clearTimeout(deadline); }
    }
    if (suite === 'ancestor-corridor') {
      const corridor = fixture({ family: 'ancestor-corridor' }).finish();
      corridor.corridor = {
        ancestors: ['veronika', 'roman', 'lydia', 'gennady', 'valentina',
          'maternal-great-mother', 'maternal-great-father', 'paternal-great-father'],
        seams: [['veronika', 'roman'], ['lydia', 'gennady'], ['maternal-great-mother', 'maternal-great-father']],
        siblings: [['natalia', 'veronika', 'prikol']],
        // Only the screenshot's known intruders have forced sides. Already
        // exterior context is never moved merely to force its branch label.
        sides: { 'oleg-mother': 'maternal', 'oleg-father': 'maternal',
          'paternal-context-parent': 'paternal' },
        neutral: ['neutral', 'both-context', 'both-context-parent', 'both-context-great'],
      };
      report.fixture = { family: 'ancestor-corridor', room: corridor.room, actor: corridor.actor, people: corridor.people };
      page = await roomPage(browser, corridor, { width: 2400, height: 1800 }, false, true);
      let deadline;
      try {
        await Promise.race([ancestorCorridor(page, corridor), new Promise((_, reject) => {
          deadline = setTimeout(() => reject(new Error('Finite ancestor-corridor exceeded its 115-second browser budget; report partial.')), 115000);
        })]);
      } finally { clearTimeout(deadline); }
      await page.context().close();
    }
    if (suite === 'descendant-branches') {
      report.fixture = { family: 'descendant-branches', orientations: [] };
      for (const [label, viewport, portrait] of [
        ['descendant-branches-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['descendant-branches-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const branchFixture = fixture({ family: 'descendant-branches' }).finish();
        report.fixture.orientations.push({ label, room: branchFixture.room, actor: branchFixture.actor,
          people: branchFixture.people, immutableOperations: branchFixture.records.length });
        page = await roomPage(browser, branchFixture, viewport, false, true);
        await descendantBranches(page, branchFixture, label, portrait);
        await page.context().close();
      }
    }
    if (['all', 'partner-proximity'].includes(suite)) {
      for (const [label, viewport, portrait] of [
        ['partner-proximity-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['partner-proximity-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const partnerFixture = fixture({ family: 'trunk-modes' }).finish();
        page = await roomPage(browser, partnerFixture, viewport, false, true);
        await partnerProximity(page, partnerFixture, label, portrait);
        await page.context().close();
      }
    }
    if (['all', 'parent-adjacency'].includes(suite)) {
      for (const [label, viewport, portrait] of [
        ['parent-adjacency-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['parent-adjacency-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const parentFixture = fixture({ family: 'trunk-modes' }).finish();
        page = await roomPage(browser, parentFixture, viewport, false, true);
        await parentAdjacency(page, parentFixture, label, portrait);
        await page.context().close();
      }
    }
    if (['all', 'trunk-modes'].includes(suite)) {
      for (const [label, viewport, portrait] of [
        ['trunk-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['trunk-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const trunkFixture = fixture({ family: 'trunk-modes' }).finish();
        page = await roomPage(browser, trunkFixture, viewport);
        await trunkModes(page, trunkFixture, label, portrait);
        await page.context().close();
      }
    }
    if (['all', 'alignment', 'alignment-mobile'].includes(suite)) {
      for (const [label, viewport, portrait] of suite === 'alignment-mobile' ? [] : [
        ['canonical-landscape-2100x1700', { width: 2100, height: 1700 }, false],
        ['canonical-portrait-1700x2100', { width: 1700, height: 2100 }, true],
      ]) {
        const alignmentFixture = fixture({ family: 'canonical-alignment' }).finish();
        page = await roomPage(browser, alignmentFixture, viewport);
        await canonicalAlignment(page, alignmentFixture, label, portrait);
        await independentLaneZoom(page, alignmentFixture, label, portrait);
        if (!portrait) await occupiedParentGuard(page, alignmentFixture, label);
        await page.context().close();
        const viewportFixture = fixture({ family: 'viewport-alignment' }).finish();
        page = await roomPage(browser, viewportFixture, viewport);
        await viewportAlignment(page, viewportFixture, label, portrait);
        await page.context().close();
      }
      const mobileFixture = fixture({ family: 'canonical-alignment' }).finish();
      page = await roomPage(browser, mobileFixture, { width: 390, height: 844 }, true);
      await loadRoom(page, mobileFixture);
      await alignmentToolbar(page, mobileFixture, 'alignment-mobile-390x844', true);
      await independentlyPannedPinch(page, mobileFixture, 'alignment-mobile-390x844');
      await occupiedParentGuard(page, mobileFixture, 'alignment-mobile-390x844');
      await page.context().close();
    }
    if (['all', 'surnames'].includes(suite)) {
      for (const [label, viewport, mobile] of [
        ['surname-desktop-1440x900', { width: 1440, height: 900 }, false],
        ['surname-mobile-390x844', { width: 390, height: 844 }, true],
      ]) {
        const surnameFixture = fixture({ family: 'surnames' }).finish();
        page = await roomPage(browser, surnameFixture, viewport, mobile);
        await surnameEditing(page, surnameFixture, label);
        await page.context().close();
        page = await roomPage(browser, seeded, viewport, mobile);
        await surnameCanvasChrome(page, seeded, label, mobile);
        await page.context().close();
      }
    }
    if (['all', 'stability'].includes(suite)) {
      for (const [label, viewport, mobile] of [
        ['desktop-1440x900', { width: 1440, height: 900 }, false],
        ['mobile-390x844', { width: 390, height: 844 }, true],
      ]) {
        const halfFixture = fixture({ family: 'half-stability' }).finish();
        page = await roomPage(browser, halfFixture, viewport, mobile);
        await halfSiblingStability(page, halfFixture, label, mobile);
        if (!mobile) await hoverWithoutNodeTooltip(page, halfFixture);
        await page.context().close();
        console.log(`PASS: ${label} separate half-sibling blocks restore same-current canonical order for four cycles at 100% and 150%; room journal unchanged.`);
      }
      for (const [label, viewport, portrait] of [
        ['kinship-landscape', { width: 1800, height: 1200 }, false],
        ['kinship-portrait', { width: 1200, height: 1800 }, true],
      ]) {
        const kinshipSeed = fixture({ family: 'kinship-style' });
        for (const id of ['cousin', 'nephew', 'niece']) {
          kinshipSeed.operation({ type: 'addPhoto', personId: id, itemId: `photo-${id}`,
            dataUrl: `data:image/png;base64,${(await fs.readFile(path.join(__dirname, '..', 'assets', 'tree-mark.png'))).toString('base64')}`,
            caption: 'Identical real avatar for cousin emphasis comparison', afterId: null, beforeId: null });
          kinshipSeed.value(id, 'avatarPhotoId', `photo-${id}`);
        }
        const kinshipFixture = kinshipSeed.finish();
        page = await roomPage(browser, kinshipFixture, viewport);
        await kinshipPixels(page, kinshipFixture, label, portrait);
        await page.context().close();
        console.log(`PASS: ${label} full/half-sibling children match cousin avatar/block pixels; normal .60 and muted .40 links visible.`);
      }
    }
    if (['all', 'kinship'].includes(suite)) {
      const photoData = await colorfulFixturePhoto(browser);
      for (const [label, viewport, portrait] of [
        ['kinship-followup-landscape', { width: 2400, height: 1800 }, false],
        ['kinship-followup-portrait', { width: 1800, height: 2400 }, true],
      ]) {
        const kinshipSeed = fixture({ family: 'kinship-followup' });
        for (const { id } of kinshipSeed.people) {
          kinshipSeed.operation({ type: 'addPhoto', personId: id, itemId: `photo-${id}`, dataUrl: photoData,
            caption: 'Identical colorful PNG for kinship node filtering', afterId: null, beforeId: null });
          kinshipSeed.value(id, 'avatarPhotoId', `photo-${id}`);
        }
        const kinshipFixture = kinshipSeed.finish();
        page = await roomPage(browser, kinshipFixture, viewport);
        await kinshipFollowup(page, kinshipFixture, label, portrait);
        await page.context().close();
      }
    }
    if (suite === 'compact-search-focus-diagnostic') {
      const diagnosticFixture = fixture().finish();
      page = await roomPage(browser, diagnosticFixture, { width: 390, height: 844 }, true, true);
      await compactSearchFocusDiagnostic(page, diagnosticFixture);
      await page.context().close();
    }
    if (suite === 'compact-search-rotation') {
      const rotationFixture = fixture().finish();
      page = await roomPage(browser, rotationFixture, { width: 390, height: 844 }, true, true);
      await compactSearchRotation(page, rotationFixture, 'compact-search-rotation');
      await page.context().close();
    }
    if (['all', 'compact-search', 'compact-search-mobile'].includes(suite)) {
      for (const [label, viewport, mobile] of [
        ['compact-search-desktop-1440x900', { width: 1440, height: 900 }, false],
        ['compact-search-mobile-390x844', { width: 390, height: 844 }, true],
      ].filter(([, , mobile]) => suite !== 'compact-search-mobile' || mobile)) {
        const focusedSeed = fixture();
        focusedSeed.value('root', 'fatherId', null);
        const focusedFixture = focusedSeed.finish();
        page = await roomPage(browser, focusedFixture, viewport, mobile, true);
        await compactSearchActions(page, focusedFixture, label, mobile);
        await page.context().close();
      }
    }
    if (['all', 'toolbar'].includes(suite)) {
      for (const [label, viewport, portrait, mobile] of [
        ['toolbar-desktop-1440x900', { width: 1440, height: 900 }, false, false],
        ['toolbar-landscape-844x390', { width: 844, height: 390 }, false, false],
        ['toolbar-portrait-390x844', { width: 390, height: 844 }, true, true],
      ]) {
        const toolbarFixture = fixture().finish();
        page = await roomPage(browser, toolbarFixture, viewport, mobile);
        await compactToolbarBrowsing(page, toolbarFixture, label, portrait);
        await linearToolbarWheel(page, toolbarFixture, label);
        if (mobile) await continuousToolbarPinch(page, toolbarFixture, label);
        await page.context().close();
      }
      const photoData = await colorfulFixturePhoto(browser);
      const washSeed = fixture({ family: 'toolbar-style' });
      for (const { id } of washSeed.people) {
        washSeed.operation({ type: 'addPhoto', personId: id, itemId: `toolbar-photo-${id}`, dataUrl: photoData,
          caption: 'Same colorful real PNG; separate normal/context/distant block evidence', afterId: null, beforeId: null });
        washSeed.value(id, 'avatarPhotoId', `toolbar-photo-${id}`);
      }
      const washFixture = washSeed.finish();
      page = await roomPage(browser, washFixture, { width: 1440, height: 900 });
      await toolbarWashPixels(page, washFixture, 'toolbar-kinship-1440x900');
      await page.context().close();
    }
    if (['all', 'zoom'].includes(suite)) {
      for (const [label, viewport, portrait] of [
        ['landscape', { width: 1440, height: 900 }, false],
        ['portrait', { width: 1000, height: 1300 }, true],
      ]) {
        const zoomFixture = fixture().finish();
        page = await roomPage(browser, zoomFixture, viewport);
        await zoomToolbar(page, zoomFixture, label);
        await desktopZoom(page, zoomFixture, label, portrait);
        await pickerZoom(page, zoomFixture, label);
        await page.context().close();
      }
      const mobileFixture = fixture().finish();
      page = await roomPage(browser, mobileFixture, { width: 390, height: 844 }, true);
      await mobileZoom(page, mobileFixture, 'mobile-390x844');
      await pickerZoom(page, mobileFixture, 'mobile-390x844', true);
      await page.context().close();
      const unknownFixture = fixture({ family: 'unknown-avatar' }).finish();
      page = await roomPage(browser, unknownFixture, { width: 390, height: 844 }, true);
      await unknownAvatarVisual(page, unknownFixture);
      await page.context().close();
    }
    for (const [label, viewport] of ['all', 'editing'].includes(suite) ? [
      ['desktop-1440x900', { width: 1440, height: 900 }],
      ['mobile-390x844', { width: 390, height: 844 }],
    ] : []) {
      if (suite === 'all') {
        const relativeSeed = fixture();
        relativeSeed.value('root', 'fatherId', null); // Add fills a free slot; it no longer replaces an occupied father.
        const relativeFixture = relativeSeed.finish();
        page = await roomPage(browser, relativeFixture, viewport);
        await relativeTreeSelection(page, relativeFixture, label);
        await page.context().close();
      }
      for (const [family, scenario] of [
        ['lydia', relationshipEditing], ['lydia', lydiaGenerationRegression],
        ['lydia', childParentRoles], ['single', deleteLastPerson],
      ]) {
        const focusedFixture = fixture({ family }).finish();
        page = await roomPage(browser, focusedFixture, viewport);
        await scenario(page, focusedFixture, label);
        await page.context().close();
        console.log(`PASS: ${label} ${scenario.name}.`);
      }
      const guestSeed = fixture({ family: 'single', role: 'guest' });
      guestSeed.operation({ type: 'deletePerson', personId: 'root' });
      const guestFixture = guestSeed.finish();
      page = await roomPage(browser, guestFixture, viewport);
      await loadRoom(page, guestFixture, null);
      assert.equal(await page.getByRole('button', { name: 'Добавить человека', exact: true }).count(), 0,
        'An empty guest tree exposed editor creation.');
      await page.screenshot({ path: path.join(output, `${label}-empty-guest.png`), animations: 'disabled' });
      report.scenarios.push({ name: `${label}-empty-guest-cannot-create` });
      await page.context().close();
    }
    page = establishedPage;
    if (suite === 'all') {
      const parentFixture = fixture({ family: 'single' }).finish();
      page = await roomPage(browser, parentFixture, { width: 1440, height: 900 });
      await parentCreation(page, parentFixture);
      await page.context().close();
      page = establishedPage;
    }
    assert.deepEqual(report.pageErrors, [], 'The real browser raised uncaught application errors.');
    if (['parent-adjacency', 'partner-proximity', 'own-partner-priority', 'clipped-selection-centering', 'descendant-branches', 'ancestor-corridor', 'shared-parent-cohorts', 'parent-row-stability', 'selection-frame-stability', 'minimum-avatar-zoom', 'explicit-siblings', 'step-parent-kinship', 'collateral-child-ranks', 'personal-family-controls', 'ordering-guest-controls', 'editor-refinements', 'editor-refinements-desktop'].includes(suite)) assert.deepEqual(report.consoleErrors, [], 'The isolated browser logged console errors.');
    if (tracedLocalLayout) {
      assert.deepEqual(report.flutterErrors, [], 'Flutter logged a rendering failure at a console level, including log/warning.');
      assert.ok(report.network.http.every((request) => !request.allowed || new URL(request.url).origin === origin),
        'The local-only layout fixture allowed an off-origin HTTP request.');
      assert.ok(report.network.webSockets.every((socket) => socket.blocked), 'The local-only layout fixture allowed a WebSocket.');
    }
    report.completed = true;
    console.log(`PASS: ${suite} focused browser suite completed; see scenario records for exact verified contracts.`);
    console.log(`Artifacts: ${output}`);
    console.log('Network synchronization is not asserted by this focused canvas regression; explicit local-copy use is recorded.');
  } catch (error) {
    report.completed = false;
    report.failure = error.stack || String(error);
    console.error(report.failure);
    if (page && !page.isClosed()) {
      report.failureSemantics = await body(page).catch(() => 'unavailable');
      report.failurePersistentJournal = await page.evaluate(() => Object.keys(localStorage)
        .filter((key) => key.startsWith('mytree.room-store.v1.') && key.includes('.operation.'))
        .map((key) => JSON.parse(localStorage.getItem(key)))
        .sort((a, b) => a.id.localeCompare(b.id))).catch(() => null);
      console.error(report.failureSemantics);
      await page.screenshot({ path: path.join(output, 'failure.png') }).catch(() => {});
    }
    process.exitCode = 1;
  } finally {
    await fs.writeFile(path.join(output, 'canvas-regression.json'), JSON.stringify(report, null, 2));
    await browser.close();
  }
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
