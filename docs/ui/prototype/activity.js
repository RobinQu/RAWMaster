'use strict';

const Activity = (() => {
  const panel = $('#activity-window');
  const libraryName = () => Studio.catalog().packageName || '本机资料库';
  const libraryID = () => Studio.catalog().activityID ??= Studio.uid();
  let current, timer, selected = 'notices', opener;
  const tabs = {notices:'通知', tasks:'任务', logs:'日志'};
  function entries() {
    const libraries = Studio.data.activityByLibrary ??= {};
    return libraries[libraryID()] ??= {notices:[], logs:[]};
  }
  const clock = time => new Date(time).toLocaleTimeString('zh-CN', {hour:'2-digit',minute:'2-digit',second:'2-digit'});
  function log(source, message) {
    entries().logs.unshift({id:Studio.uid(), source, message, time:Date.now()});
    Studio.save();
    refresh();
  }
  function toast(photo) {
    return current && current.photo === photo && current.library === libraryID() && current.expires > Date.now() ? current : null;
  }
  function dismiss(id) {
    if (!current || current.id !== id) return;
    clearTimeout(timer); current = null;
    $('.editor-notices')?.replaceChildren();
  }
  function post(message, kind, photo = null, retry = '') {
    const entry = {id:Studio.uid(),message,kind,photo,retry,time:Date.now()};
    entries().notices.unshift(entry);
    Studio.save();
    if (S.page === 'edit' && photo === Studio.data.work) {
      clearTimeout(timer);
      const duration = kind === 'error' ? 6000 : 3500;
      current = {...entry,library:libraryID(),expires:entry.time+duration};
      const host = $('.editor-notices');
      if (host) host.innerHTML = editorNoticeRow(current);
      timer = setTimeout(() => dismiss(entry.id), duration);
    }
    refresh();
  }
  function resolve(action, photo) {
    for (const notice of entries().notices) if (notice.photo === photo && notice.retry === action) notice.retry = '';
    if (current?.photo === photo && current.retry === action) current.retry = '';
    Studio.save();
  }
  function refresh() {
    if (!panel.open) return;
    const rows = entries()[selected];
    if (selected === 'tasks') {
      panel.querySelector('.activity-list').innerHTML = Studio.data.jobs.map(j =>
        `<div class="activity-row">${icon('clock')}<div><strong>${h(j.kind)}</strong><small>${h([...new Set([jobNames[j.state] || j.state, j.deliveryStatus].filter(Boolean))].join(' · '))}</small></div>${j.delivery || j.quickPrompt || j.group || j.result ? btn('查看详情','job-detail',j.id):''}</div>`
      ).join('') || '<p class="activity-empty">当前资料库暂无后台任务</p>';
    } else {
      panel.querySelector('.activity-list').innerHTML = rows.map(row => {
        const label = selected === 'logs' ? row.source : row.kind === 'error' ? '错误' : '信息';
        const photo = row.photo && Studio.asset(row.photo)?.name;
        return `<div class="activity-row">${icon(row.kind === 'error' ? 'warning' : selected === 'logs' ? 'pulse' : 'info')}<div><strong>${h(row.message)}</strong><small>${h([label,photo,clock(row.time)].filter(Boolean).join(' · '))}</small></div></div>`;
      }).join('') || `<p class="activity-empty">当前资料库暂无${tabs[selected]}</p>`;
    }
    panel.querySelector('.activity-library').textContent = libraryName();
  }
  function show(tab = selected, returnSelector) {
    selected = Object.hasOwn(tabs, tab) ? tab : 'notices';
    if (!panel.open) opener = returnSelector || '[data-act=activity-open]';
    panel.innerHTML = `<header><div><h2 id="activity-title">后台信息</h2><small class="activity-library"></small></div>${btn('关闭后台信息','activity-close','',{icon:'close',only:true,cls:'icon-btn'})}</header>
      <nav aria-label="后台信息栏目">${Object.entries(tabs).map(([id,label])=>btn(label,'activity-tab',id,{pressed:selected===id})).join('')}</nav><div class="activity-list" role="region" aria-label="${tabs[selected]}"></div>`;
    if (!panel.open) panel.show();
    refresh();
    panel.querySelector('[aria-pressed=true]').focus({preventScroll:true});
  }
  function close() {
    panel.close();
    ($(opener) || $('[data-act=activity-open]'))?.focus({preventScroll:true});
  }
  panel.addEventListener('keydown',event=>{
    if (event.key === 'Escape') {event.preventDefault();event.stopPropagation();close();}
    const tab=event.target.closest('[data-act=activity-tab]');
    if (!tab || !['ArrowLeft','ArrowRight'].includes(event.key)) return;
    event.preventDefault(); const keys=Object.keys(tabs);
    show(keys[(keys.indexOf(selected)+(event.key==='ArrowRight'?1:2))%keys.length]);
  });
  actions['activity-open'] = () => show();
  actions['activity-window-menu'] = () => { const menu=$('.window-menu'); if(menu)menu.open=false; show(selected,'.window-menu summary'); };
  actions['activity-tab'] = show;
  actions['activity-close'] = close;
  return {toast,post,dismiss,resolve,refresh,log,leavePhoto:()=>{if(current)dismiss(current.id);}};
})();

Activity.log('工作台','已打开资料库');
