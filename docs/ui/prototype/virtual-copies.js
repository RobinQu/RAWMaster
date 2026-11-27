'use strict';

const VirtualCopies = (() => {
  const labels = {create:'创建虚拟副本', rename:'重命名虚拟副本', remove:'移除虚拟副本'};
  const canPresent = () => S.scope === 'all' || S.scope === 'picks' || S.scope.startsWith('project/');
  let request;
  function menu(ids) {
    if (!canPresent()) return '';
    if (ids.length !== 1)
      return btn('创建虚拟副本…','copy-request','create',{disabled:true,title:'请选中一张照片或虚拟副本'});
    return Object.entries(labels).filter(([key]) => key === 'create' || Studio.copy(ids[0]))
      .map(([key,label]) => btn(label + '…','copy-request',key,{icon:key==='remove'?'trash':key==='rename'?'edit':'layers'})).join('');
  }
  function focusPhoto(id) {
    const selector = '[data-act="photo"][data-val="' + CSS.escape(id) + '"]';
    $(selector)?.focus({preventScroll:true});
  }
  function selectOnly(id) {
    const browse = Studio.browser(S.scope);
    browse.selected = [id]; browse.focus = browse.anchor = id;
    Studio.save();
  }
  function defaultName(id) {
    const names = new Set(Studio.copiesOf(id).map(copy => copy.name));
    let index=1;
    while (names.has('副本 ' + index)) index++;
    return '副本 ' + index;
  }
  function open(kind) {
    const id = activeBrowser().focus;
    if (!canPresent() || !validWork(id) || !labels[kind] || (kind!=='create' && !Studio.copy(id))) return;
    request = {kind,id};
    const removing = kind === 'remove';
    const prompt = removing
      ? '<p>移除「' + h(Studio.copy(id).name) + '」及其编辑与快照？原片和已交付文件会保留。</p>'
      : field('副本名称','copyName',kind==='create' ? defaultName(id) : Studio.copy(id).name)
        + '<p id="copy-name-error" class="form-error" role="alert"></p>';
    dialog(labels[kind], '<p class="muted">' + h(Studio.displayName(id)) + '</p>' + prompt,
      btn('取消','copy-cancel') + btn(removing ? '移除副本' : kind==='create' ? '创建' : '存储','copy-commit','',
        {cls:removing?'destructive':'primary'}));
    if (removing) sheet.querySelector('[data-act=copy-cancel]').focus();
    else {const input=sheet.querySelector('[name=copyName]'); input.focus(); input.select();}
  }
  function close(id) {
    request=null; closeSheet(); render();
    requestAnimationFrame(() => focusPhoto(id));
  }
  function commit() {
    if (!request) return;
    const {id,kind} = request;
    let selected=id;
    if (kind==='remove') {
      selected=Studio.physicalID(id);
      Studio.change(labels[kind], c => { delete c.virtualCopies[id]; });
    } else {
      const name=value('copyName').trim(), issue=Studio.copyNameIssue(id,name,kind==='rename' ? id : null);
      if (issue) {const input=sheet.querySelector('[name=copyName]');input.setAttribute('aria-invalid','true');input.focus();$('#copy-name-error').textContent=issue;return;}
      if (kind==='create') selected=Studio.createCopy(id,name);
      else Studio.change(labels[kind], c => {c.virtualCopies[id].name=name;});
    }
    if (kind !== 'rename') {
      const last = Studio.data.history[0];
      if (last) last.copyUndoFocus=id;
    }
    selectOnly(selected); close(selected);
  }
  function context(event) {
    const row=event.target.closest('.photo-card[data-act=photo],.filmstrip-photo[data-act=photo]');
    if (!row || !canPresent()) return;
    event.preventDefault(); selectOnly(row.dataset.val); render(); focusPhoto(row.dataset.val);
    actions['selection-menu']();
  }
  document.addEventListener('contextmenu',context);
  document.addEventListener('keydown',event=>{
    if (event.key==='ContextMenu' || event.key==='F10'&&event.shiftKey) {context(event);return;}
    if (!request || !sheet.open) return;
    if (event.key==='Escape') { event.preventDefault(); close(request.id); }
    else if (event.key==='Enter' && event.target.name==='copyName') { event.preventDefault(); commit(); }
  },true);
  sheet.addEventListener('close',()=>{request=null;});
  actions['copy-request']=open;
  actions['copy-commit']=commit;
  actions['copy-cancel']=()=>{if(request)close(request.id);};
  return {menu,focusPhoto,selectOnly};
})();
