/*
 * MessageArchiver — the Message Explorer (Milestone 22).
 *
 * The archive browsed like a messaging app: people and conversations on the left, the
 * conversation on the right. Offline: it reads only the archive's own files, and as script
 * files (Explorer/list.js, then each conversation's parts in Explorer/c/), because browsers
 * refuse fetch() on file:// pages. Each part holds up to 500 messages, already rendered as the
 * conversation pages render them; a conversation opens on its newest part, and earlier parts
 * load when asked for.
 */
'use strict';

const MA = (() => {
    let data = null;
    let tab = 'conversations';
    let current = null;
    const byKey = new Map();
    const byPerson = new Map();
    const parts = new Map();
    const waiting = new Map();

    const $ = id => document.getElementById(id);

    function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
    }

    const plural = (n, word) => `${n.toLocaleString()} ${word}${n === 1 ? '' : 's'}`;

    function avatar(name) {
        const words = name.replace(/[^\p{L}\p{N}\s]/gu, ' ').trim().split(/\s+/).filter(Boolean);
        const letters = /^\p{L}/u.test(words[0] || '') ? words.slice(0, 2).map(w => w[0]).join('').toUpperCase() : '#';
        let hash = 0;
        for (const c of name) hash = (hash * 31 + c.codePointAt(0)) % 360;
        const a = el('span', 'ex_avatar', letters);
        a.style.background = `hsl(${hash} 42% 50%)`;
        a.setAttribute('aria-hidden', 'true');
        return a;
    }

    // A path in the archive as a link: each part encoded, as the pages' own links are.
    const href = path => path.split('/').map(encodeURIComponent).join('/');

    const personName = p => p.name || p.handles[0] || 'Unknown';

    // MARK: Data, from the script files

    function list(d) {
        data = d;
        for (const c of d.conversations) {
            c.time = c.last ? Date.parse(c.last) : 0;
            byKey.set(c.key, c);
        }
        for (const p of d.people) {
            p.conversations = [];
            byPerson.set(p.id, p);
        }
        for (const c of d.conversations) {
            for (const id of c.people) byPerson.get(id)?.conversations.push(c);
        }
        d.conversations.sort((a, b) => b.time - a.time || a.title.localeCompare(b.title));
        for (const c of d.conversations) {
            const names = c.people.map(id => byPerson.get(id)).filter(Boolean)
                .map(p => [p.name || '', ...p.handles].join(' '));
            c.find = [c.title, c.sources, ...names].join(' ').toLowerCase();
        }
        for (const p of d.people) {
            p.conversations.sort((a, b) => b.time - a.time);
            p.messages = p.conversations.reduce((n, c) => n + c.messages, 0);
            p.time = p.conversations.length ? p.conversations[0].time : 0;
            p.day = p.conversations.length ? p.conversations[0].day : '';
            p.find = [p.name || '', ...p.handles].join(' ').toLowerCase();
        }
        d.people.sort((a, b) => personName(a).localeCompare(personName(b)));
        start();
    }

    function chunk(key, n, messages) {
        if (!parts.has(key)) parts.set(key, []);
        parts.get(key)[n] = messages;
        const done = waiting.get(`${key}/${n}`);
        if (done) {
            waiting.delete(`${key}/${n}`);
            done(messages);
        }
    }

    function load(key, n) {
        const have = parts.get(key)?.[n];
        if (have) return Promise.resolve(have);
        return new Promise((resolve, reject) => {
            waiting.set(`${key}/${n}`, resolve);
            const s = document.createElement('script');
            s.src = `Explorer/c/${key}-${n}.js`;
            s.onload = () => s.remove();
            s.onerror = () => {
                waiting.delete(`${key}/${n}`);
                s.remove();
                reject(new Error(`Explorer/c/${key}-${n}.js couldn’t be read`));
            };
            document.head.appendChild(s);
        });
    }

    // MARK: The side bar

    function start() {
        $('ex-sub').textContent = data.summary;
        for (const name of ['conversations', 'people']) {
            $(`ex-tab-${name}`).addEventListener('click', () => setTab(name));
        }
        $('ex-filter').addEventListener('input', renderList);
        $('ex-filter').addEventListener('keydown', e => {
            if (e.key === 'ArrowDown' || e.key === 'Enter') {
                const first = $('ex-list').querySelector('a.ex_row');
                if (first) {
                    e.preventDefault();
                    first.focus();
                    if (e.key === 'Enter') first.click();
                }
            }
        });
        // Up and down move through the list, opening each row, as a messaging app does.
        $('ex-list').addEventListener('keydown', e => {
            if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return;
            const rows = [...$('ex-list').querySelectorAll('a.ex_row')];
            const i = rows.indexOf(document.activeElement);
            const next = rows[e.key === 'ArrowDown' ? i + 1 : i - 1];
            if (i < 0 || !next) return;
            e.preventDefault();
            next.focus();
            next.click();
        });
        window.addEventListener('hashchange', route);
        const h = decodeURIComponent(location.hash.slice(1));
        setTab(h.startsWith('p/') ? 'people' : 'conversations');
        route();
    }

    function setTab(name) {
        tab = name;
        for (const t of ['conversations', 'people']) {
            $(`ex-tab-${t}`).setAttribute('aria-selected', String(t === name));
        }
        $('ex-filter').placeholder = name === 'people' ? 'Find a person, number or email' : 'Find a conversation';
        renderList();
    }

    function renderList() {
        const q = $('ex-filter').value.trim().toLowerCase();
        const items = tab === 'people' ? data.people : data.conversations;
        const out = document.createDocumentFragment();
        let shown = 0;
        for (const item of items) {
            if (q && !item.find.includes(q)) continue;
            out.appendChild(tab === 'people' ? personRow(item) : conversationRow(item));
            shown++;
        }
        if (!shown) {
            out.appendChild(el('li', 'ex_none', q ? 'Nothing matches.' : (tab === 'people' ? 'No people in this archive.' : 'No conversations in this archive.')));
        }
        $('ex-list').replaceChildren(out);
        markSelected();
    }

    function row(href, name, title, day, sub) {
        const li = el('li');
        const a = el('a', 'ex_row');
        a.href = href;
        const text = el('span', 'ex_row_text');
        const top = el('span', 'ex_row_top');
        top.append(el('span', 'ex_row_title', title), el('span', 'ex_row_date', day));
        text.append(top, el('span', 'ex_row_sub', sub));
        a.append(avatar(name), text);
        li.append(a);
        return li;
    }

    function conversationRow(c) {
        const sub = [plural(c.messages, 'message'), c.group ? 'Group' : null, c.sources].filter(Boolean).join(' · ');
        return row(`#c/${c.key}`, c.title, c.title, c.day, sub);
    }

    function personRow(p) {
        const more = p.handles.length > 1 ? ` +${p.handles.length - 1}` : '';
        const sub = [`${p.handles[0] || ''}${more}`, plural(p.conversations.length, 'conversation')].join(' · ');
        return row(`#p/${encodeURIComponent(p.id)}`, personName(p), personName(p), p.day, sub);
    }

    function markSelected() {
        for (const a of $('ex-list').querySelectorAll('a.ex_row')) {
            const on = a.getAttribute('href') === location.hash;
            a.classList.toggle('selected', on);
            if (on) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current');
        }
    }

    // MARK: The main pane

    function route() {
        const h = decodeURIComponent(location.hash.slice(1));
        current = null;
        if (h.startsWith('c/') && byKey.has(h.slice(2))) {
            showConversation(byKey.get(h.slice(2)));
        } else if (h.startsWith('p/') && byPerson.has(h.slice(2))) {
            showPerson(byPerson.get(h.slice(2)));
        } else {
            showWelcome();
        }
        markSelected();
    }

    function backLink() {
        const a = el('a', 'ex_back', '‹ All');
        a.href = '#';
        return a;
    }

    function showWelcome() {
        document.body.classList.remove('ex_open');
        const box = el('div', 'ex_welcome');
        box.append(el('h2', 'ex_brand', 'Message Explorer'));
        if (data.range) box.append(el('p', 'ex_range', data.range));
        box.append(el('p', null, data.about), el('p', null, `Read from: ${data.read_from}`));
        if (data.stopped) box.append(el('p', 'ex_warn', 'This export was stopped before it finished.'));
        for (const line of data.incomplete) box.append(el('p', 'ex_warn', `Incomplete: ${line}`));
        box.append(el('p', 'ex_hint', 'Choose a conversation or a person on the left.'), el('p', 'ex_fine', data.exported));
        $('ex-main').replaceChildren(box);
        document.title = `${data.name} · Message Explorer`;
    }

    function showConversation(c) {
        document.body.classList.add('ex_open');
        document.title = `${c.title} · Message Explorer`;
        const head = el('header', 'ex_head');
        const title = el('div', 'ex_head_title');
        title.append(avatar(c.title), el('h2', null, c.title));
        head.append(backLink(), title);
        const people = c.people.map(id => byPerson.get(id)).filter(Boolean)
            .map(p => (p.name ? `${p.name} (${p.handles.join(', ')})` : p.handles.join(', ')));
        if (people.length) head.append(el('p', null, people.join(' · ')));
        let attachments = plural(c.attachments, 'attachment');
        if (c.missing) attachments += ` (${c.missing.toLocaleString()} missing)`;
        head.append(el('p', null, [plural(c.messages, 'message'), attachments, c.group ? 'Group' : null, c.sources].filter(Boolean).join(' · ')));
        head.append(el('p', null, [c.range, c.bates, c.incomplete ? 'incomplete' : null].filter(Boolean).join(' · ')));
        if (c.links.length) {
            const links = el('nav', 'ex_links');
            for (const l of c.links) {
                const a = el('a', 'ex_link', l.label);
                a.href = href(l.path);
                links.append(a);
            }
            head.append(links);
        }
        const scroll = el('div', 'ex_messages');
        scroll.tabIndex = -1;
        $('ex-main').replaceChildren(head, scroll);

        if (!c.parts) {
            const note = el('div', 'ex_notice', 'This conversation was written into the archive before it had a Message Explorer, so its messages are only on its own page.');
            const page = c.links[0];
            if (page) {
                const a = el('a', 'ex_link', ` Open ${page.label.toLowerCase()}`);
                a.href = href(page.path);
                note.append(a);
            }
            scroll.append(note);
            return;
        }
        const view = { key: c.key, conversation: c, scroll, earliest: c.parts, more: null };
        current = view;
        scroll.addEventListener('click', e => {
            const a = e.target.closest('a[href^="#m-"]');
            if (!a) return;
            e.preventDefault();
            reveal(view, a.getAttribute('href').slice(1));
        });
        loadEarlier(view).then(() => {
            scroll.scrollTop = scroll.scrollHeight;
            scroll.focus({ preventScroll: true });
        });
    }

    // The part before the earliest one shown, added above it, the view staying where it was.
    async function loadEarlier(view) {
        if (view.earliest === 0) return false;
        const n = view.earliest - 1;
        let messages;
        try {
            messages = await load(view.key, n);
        } catch (error) {
            if (current === view) view.scroll.prepend(el('div', 'ex_notice', `${error.message}. The conversation's page has every message.`));
            return false;
        }
        if (current !== view) return false;
        view.earliest = n;
        const block = el('div', 'ex_part');
        block.innerHTML = messages.join('');
        const before = view.scroll.scrollHeight - view.scroll.scrollTop;
        view.more?.remove();
        view.scroll.prepend(block);
        if (n > 0) {
            const shown = view.conversation.messages - Math.min(view.conversation.messages, n * 500);
            view.more = el('button', 'ex_more', `Show earlier messages (${shown.toLocaleString()} of ${view.conversation.messages.toLocaleString()} shown)`);
            view.more.type = 'button';
            view.more.addEventListener('click', () => loadEarlier(view));
            view.scroll.prepend(view.more);
        } else {
            view.more = null;
            view.scroll.prepend(el('div', 'ex_start', 'The start of this conversation in the archive'));
        }
        view.scroll.scrollTop = view.scroll.scrollHeight - before;
        return true;
    }

    // A reply's link to the message it answers: earlier parts load until it is found.
    async function reveal(view, id) {
        let target = document.getElementById(id);
        while (!target && await loadEarlier(view)) target = document.getElementById(id);
        if (!target || current !== view) return;
        target.scrollIntoView({ block: 'center' });
        target.classList.remove('ex_flash');
        void target.offsetWidth;
        target.classList.add('ex_flash');
    }

    function showPerson(p) {
        document.body.classList.add('ex_open');
        document.title = `${personName(p)} · Message Explorer`;
        const head = el('header', 'ex_head');
        const title = el('div', 'ex_head_title');
        title.append(avatar(personName(p)), el('h2', null, personName(p)));
        head.append(backLink(), title);
        head.append(el('p', null, [p.contacts ? 'In Contacts' : 'Not in Contacts', plural(p.conversations.length, 'conversation'), plural(p.messages, 'message')].join(' · ')));
        const body = el('div', 'ex_person');
        body.append(el('h3', null, 'Phone numbers and emails'));
        const handles = el('ul', 'ex_handles');
        for (const h of p.handles) handles.append(el('li', null, h));
        body.append(handles, el('h3', null, 'Conversations'));
        const list = el('ul', 'ex_list ex_inline');
        for (const c of p.conversations) list.append(conversationRow(c));
        body.append(list);
        $('ex-main').replaceChildren(head, body);
    }

    return { list, chunk };
})();
