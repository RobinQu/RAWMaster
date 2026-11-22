// Source indexes stay stable across sample sizes, filters, focus changes and submitted jobs.
class WorkspaceSelection {
  static limit = 200;
  static rowHeight = 56;

  constructor(photos, actions) {
    this.photos = photos;
    this.actions = actions;
    this.total = photos.length;
    this.included = new Set(photos.keys());
    this.revision = 0;
    this.filter = document.getElementById('selection-filter');
    this.search = document.getElementById('selection-search');
    this.list = document.getElementById('asset-list');
    this.track = document.getElementById('asset-rows');
    this.rows = new Map();
    this.matches = [];
    this.positions = new Map();
    this.ordered = [];
    this.anchor = null;
    this.tabRow = 0;
    this.frame = 0;
    const refilter = () => {
      this.list.scrollTop = 0;
      this.anchor = null;
      this.filterRows();
      this.draw();
    };
    this.search.addEventListener('input', refilter);
    this.filter.addEventListener('change', refilter);
    document.getElementById('select-matches').onclick = () => this.setMatches(true);
    document.getElementById('clear-matches').onclick = () => this.setMatches(false);
    document.getElementById('limit-selection').onclick = () => this.keepFirstBatch();
    document.getElementById('sample-size').onchange = event => this.useSample(Number(event.target.value));
    this.list.addEventListener('click', event => this.clickRow(event));
    this.list.addEventListener('keydown', event => this.keyDown(event));
    this.list.addEventListener('scroll', () => this.scheduleDraw(), {passive:true});
    new ResizeObserver(() => this.scheduleDraw()).observe(this.list);
    this.filterRows();
  }

  get overLimit() {
    return this.included.size > WorkspaceSelection.limit;
  }

  // Larger synthetic sets reuse three thumbnails and edit-version fixtures. Each item keeps
  // its own online state and chosen version. Previously submitted indexes remain addressable.
  useSample(size) {
    if (![3,1200,201].includes(size)) return;
    for (let i = this.photos.length; i < size; i++) {
      const base = this.photos[i % 3];
      const suffix = base.name.split('.').pop();
      const sampleName = 'RIVER_' + String(i + 1).padStart(4,'0') + '.' + suffix;
      this.photos.push({...base, name:sampleName, choice:0, online:i % 19 !== 0});
    }
    this.total = size;
    this.included.clear();
    for (let index = 0; index < size; index++) this.included.add(index);
    this.filter.value = 'all';
    this.search.value = '';
    this.anchor = null;
    this.tabRow = 0;
    this.list.scrollTop = 0;
    this.actions.setFocus(0);
    this.changed();
  }

  filterRows() {
    const needle = this.search.value.trim().toLocaleLowerCase();
    const filter = this.filter.value;
    this.matches = [];
    this.positions.clear();
    this.ordered = [];
    let checkedMatches = 0;
    for (let index = 0; index < this.total; index++) {
      const photo = this.photos[index];
      const checked = this.included.has(index);
      if (checked) this.ordered.push(index);
      if (filter === 'checked' && !checked || filter === 'offline' && photo.online) continue;
      const jpeg = /\.jpe?g$/i.test(photo.name);
      if (filter === 'raw' && jpeg || filter === 'jpeg' && !jpeg) continue;
      if (needle && !(photo.name + ' ' + photo.scene + ' ' + photo.date).toLocaleLowerCase().includes(needle)) continue;
      this.positions.set(index,this.matches.length);
      this.matches.push(index);
      if (checked) checkedMatches++;
    }
    this.checkedMatches = checkedMatches;
    if (!this.positions.has(this.tabRow)) this.tabRow = this.matches[0];
    const height = this.matches.length * WorkspaceSelection.rowHeight;
    this.track.style.height = height + 'px';
    this.list.style.setProperty('--results-height',height + 'px');
    this.list.setAttribute('aria-label','选片列表，' + this.matches.length + ' 项');
    document.getElementById('empty-selection').hidden = this.matches.length > 0;
    document.getElementById('select-matches').disabled = checkedMatches === this.matches.length;
    document.getElementById('clear-matches').disabled = checkedMatches === 0;
    const summary = document.getElementById('selection-summary');
    summary.hidden = filter === 'all' && !needle;
    summary.textContent =
      '筛选结果 ' + this.matches.length.toLocaleString('zh-CN') + ' 张 · 已选 ' + checkedMatches.toLocaleString('zh-CN') + ' 张';
    document.getElementById('selection-limit').hidden = !this.overLimit;
    if (this.overLimit) document.getElementById('limit-count').textContent =
      '单批最多 200 张，当前多选了 ' + (this.included.size - WorkspaceSelection.limit).toLocaleString('zh-CN') + ' 张。';
  }

  changed() {
    this.revision++;
    this.filterRows();
    this.actions.refresh();
  }

  setMatches(value) {
    for (const index of this.matches) {
      if (value) this.included.add(index);
      else this.included.delete(index);
    }
    this.anchor = null;
    this.changed();
  }

  keepFirstBatch() {
    if (!this.overLimit) return;
    for (const index of this.ordered.slice(WorkspaceSelection.limit)) this.included.delete(index);
    this.changed();
  }

  toggle(index, value, range) {
    const position = this.positions.get(index);
    if (position === undefined) return;
    const from = range && this.anchor !== null ? this.positions.get(this.anchor) : position;
    const start = from ?? position;
    for (let i = Math.min(start,position); i <= Math.max(start,position); i++) {
      if (value) this.included.add(this.matches[i]);
      else this.included.delete(this.matches[i]);
    }
    if (!range || from === undefined) this.anchor = index;
    this.tabRow = index;
    this.changed();
  }

  scheduleDraw() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.draw();
    });
  }

  makeRow() {
    const row = document.createElement('div');
    row.className = 'asset';
    row.setAttribute('role','listitem');
    const check = document.createElement('input');
    check.type = 'checkbox';
    const button = document.createElement('button');
    button.type = 'button';
    const img = document.createElement('img');
    img.alt = '';
    img.decoding = 'async';
    const copy = document.createElement('span');
    copy.className = 'copy';
    copy.append(document.createElement('strong'),document.createElement('small'));
    button.append(img,copy);
    row.append(check,button);
    return row;
  }

  paintRow(row, index, position) {
    const photo = this.photos[index];
    const [check,button] = row.children;
    const [img,copy] = button.children;
    const [title,subtitle] = copy.children;
    const url = this.actions.imageURL(photo);
    if (img.getAttribute('src') !== url) img.src = url;
    const chosen = index === this.actions.getFocus();
    row.dataset.index = index;
    row.style.top = position * WorkspaceSelection.rowHeight + 'px';
    row.setAttribute('aria-posinset',String(position + 1));
    row.setAttribute('aria-setsize',String(this.matches.length));
    row.classList.toggle('chosen',chosen);
    check.checked = this.included.has(index);
    check.setAttribute('aria-label','列入交付 ' + photo.name);
    check.tabIndex = button.tabIndex = index === this.tabRow ? 0 : -1;
    button.setAttribute('aria-pressed',String(chosen));
    if (title.textContent !== photo.name) title.textContent = photo.name;
    const status = this.actions.status(photo);
    if (subtitle.textContent !== status) subtitle.textContent = status;
    subtitle.classList.toggle('warn',!this.actions.available(photo));
  }

  draw() {
    const height = WorkspaceSelection.rowHeight;
    const overscan = 3;
    const first = Math.max(0,Math.floor(this.list.scrollTop / height) - overscan);
    const end = Math.min(this.matches.length,Math.ceil((this.list.scrollTop + this.list.clientHeight) / height) + overscan);
    const visible = this.matches.slice(first,end);
    const kept = new Set(visible);
    const pool = [];
    const active = document.activeElement;
    for (const [index,row] of this.rows) {
      if (!kept.has(index)) {
        if (row.contains(active)) this.list.focus({preventScroll:true});
        row.remove();
        this.rows.delete(index);
        pool.push(row);
      }
    }
    // Keep DOM order aligned with visual order when scrolling in both directions.
    let next = null;
    for (let i = visible.length - 1; i >= 0; i--) {
      const index = visible[i];
      let row = this.rows.get(index);
      if (!row) {
        row = pool.pop() || this.makeRow();
        this.rows.set(index,row);
        this.track.insertBefore(row,next);
      }
      this.paintRow(row,index,first + i);
      next = row;
    }
  }

  clickRow(event) {
    const row = event.target.closest('.asset');
    if (!row) return;
    const index = Number(row.dataset.index);
    if (event.target.matches('input')) this.toggle(index,event.target.checked,event.shiftKey);
    else if (event.target.closest('button')) this.focusAt(this.positions.get(index));
  }

  focusAt(position) {
    if (!this.matches.length || position === undefined) return;
    const rank = Math.max(0,Math.min(this.matches.length - 1,position));
    const index = this.matches[rank];
    this.tabRow = index;
    this.actions.setFocus(index);
    const height = WorkspaceSelection.rowHeight;
    const top = rank * height;
    if (top < this.list.scrollTop) this.list.scrollTop = top;
    else if (top + height > this.list.scrollTop + this.list.clientHeight) {
      this.list.scrollTop = top + height - this.list.clientHeight;
    }
    this.actions.refresh();
    this.rows.get(index)?.querySelector('button').focus({preventScroll:true});
  }

  keyDown(event) {
    if (!this.matches.length || event.metaKey || event.ctrlKey || event.altKey) return;
    const row = event.target.closest('.asset');
    const firstVisible = Math.min(this.matches.length - 1,Math.floor(this.list.scrollTop / WorkspaceSelection.rowHeight));
    const index = row ? Number(row.dataset.index) : this.matches[firstVisible];
    const rank = this.positions.get(index);
    const page = Math.max(1,Math.floor(this.list.clientHeight / WorkspaceSelection.rowHeight));
    if (event.key === ' ') {
      event.preventDefault();
      this.toggle(index,!this.included.has(index),event.shiftKey);
      return;
    }
    const positions = {ArrowDown:rank+1,ArrowRight:rank+1,ArrowUp:rank-1,ArrowLeft:rank-1,
      Home:0,End:this.matches.length-1,PageDown:rank+page,PageUp:rank-page,Enter:rank};
    if (Object.hasOwn(positions,event.key)) {
      event.preventDefault();
      this.focusAt(positions[event.key]);
    }
  }
}
