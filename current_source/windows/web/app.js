(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const state = {
    token: localStorage.getItem('comfyremote.web.token') || '',
    dashboard: null,
    serve: null,
    details: null,
    workflowID: localStorage.getItem('comfyremote.web.workflow') || '',
    outputNodeID: '',
    pollTimer: null,
    promptTimer: null,
    mediaTarget: null,
    resultUrls: new Map(),
    lastResultSignature: '',
    loading: false,
  };

  const els = {
    loginScreen: $('loginScreen'), app: $('app'), pingInfo: $('pingInfo'), password: $('password'), loginBtn: $('loginBtn'),
    connectionId: $('connectionId'), connectionIdBtn: $('connectionIdBtn'), loginError: $('loginError'),
    connectionDot: $('connectionDot'), connectionText: $('connectionText'), systemStats: $('systemStats'),
    tailscaleServeState: $('tailscaleServeState'), tailscaleServeDetail: $('tailscaleServeDetail'), tailscaleServeUrl: $('tailscaleServeUrl'),
    tailscaleServeSetupBtn: $('tailscaleServeSetupBtn'), tailscaleServeOpenBtn: $('tailscaleServeOpenBtn'), tailscaleServeCopyBtn: $('tailscaleServeCopyBtn'),
    workflowSelect: $('workflowSelect'), workflowMeta: $('workflowMeta'), workflowReloadBtn: $('workflowReloadBtn'),
    dynamicInputs: $('dynamicInputs'), outputCard: $('outputCard'), outputCount: $('outputCount'), outputSelect: $('outputSelect'), outputOnly: $('outputOnly'),
    positive: $('positivePrompt'), negative: $('negativePrompt'), promptSyncState: $('promptSyncState'),
    advancedPanel: $('advancedPanel'), advancedSummary: $('advancedSummary'), steps: $('steps'), cfg: $('cfg'), seed: $('seed'), width: $('width'), height: $('height'),
    sampler: $('sampler'), scheduler: $('scheduler'), checkpoint: $('checkpoint'), lora: $('lora'), vae: $('vae'),
    generationStage: $('generationStage'), elapsed: $('elapsed'), progressBar: $('progressBar'), progressText: $('progressText'), currentNode: $('currentNode'), queueCount: $('queueCount'),
    resultsGrid: $('resultsGrid'), stopBtn: $('stopBtn'), randomBtn: $('randomBtn'), generateBtn: $('generateBtn'),
    workflowFile: $('workflowFile'), mediaFile: $('mediaFile'), nodeModal: $('nodeModal'), nodeList: $('nodeList'), nodeSearch: $('nodeSearch'),
    mediaModal: $('mediaModal'), mediaViewerBody: $('mediaViewerBody'), toast: $('toast'),
  };

  function authHeaders(extra = {}) {
    const headers = { ...extra };
    if (state.token) headers.Authorization = `Bearer ${state.token}`;
    return headers;
  }

  async function api(path, options = {}) {
    const opts = { cache: 'no-store', ...options };
    opts.headers = authHeaders(opts.headers || {});
    if (opts.body && typeof opts.body !== 'string' && !(opts.body instanceof FormData)) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.body);
    }
    const response = await fetch(path, opts);
    let value = null;
    const text = await response.text();
    if (text) {
      try { value = JSON.parse(text); } catch { value = { error: text }; }
    }
    if (!response.ok) {
      if (response.status === 401 && path !== '/api/auth/login') showLogin('Сессия завершена. Войдите снова.');
      throw new Error(value?.error || `HTTP ${response.status}`);
    }
    return value;
  }

  async function apiBlob(path) {
    const response = await fetch(path, { headers: authHeaders(), cache: 'no-store' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.blob();
  }

  function showLogin(message = '') {
    state.token = '';
    localStorage.removeItem('comfyremote.web.token');
    els.app.classList.add('hidden');
    els.loginScreen.classList.remove('hidden');
    els.loginError.textContent = message;
    clearTimeout(state.pollTimer);
  }

  function showApp() {
    els.loginScreen.classList.add('hidden');
    els.app.classList.remove('hidden');
    refreshRemoteAccess(true);
  }

  function toast(message) {
    els.toast.textContent = message;
    els.toast.classList.remove('hidden');
    clearTimeout(els.toast._timer);
    els.toast._timer = setTimeout(() => els.toast.classList.add('hidden'), 2200);
  }

  function decodeConnectionID(raw) {
    const cleaned = String(raw || '').trim().replace(/\s+/g, '');
    if (!cleaned.startsWith('PCR1-')) throw new Error('Connection ID должен начинаться с PCR1-');
    let encoded = cleaned.slice(5).replace(/-/g, '+').replace(/_/g, '/');
    while (encoded.length % 4) encoded += '=';
    const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    if (!payload.t) throw new Error('В Connection ID нет токена');
    return payload;
  }

  async function probe() {
    try {
      const value = await api('/api/ping');
      els.pingInfo.textContent = `${value.computer || 'PC'} · Server ${value.server_version || '?'} · ${value.password_set ? 'пароль включён' : 'пароль не задан'}`;
      return value;
    } catch (error) {
      els.pingInfo.textContent = `Сервер не отвечает: ${error.message}`;
      return null;
    }
  }

  async function loginWithPassword() {
    els.loginError.textContent = '';
    els.loginBtn.disabled = true;
    try {
      const value = await api('/api/auth/login', { method: 'POST', body: { password: els.password.value } });
      if (!value?.token) throw new Error('Сервер не вернул token');
      state.token = value.token;
      localStorage.setItem('comfyremote.web.token', state.token);
      showApp();
      await refreshDashboard({ loadParameters: true, forceDetails: true });
      schedulePoll();
    } catch (error) {
      els.loginError.textContent = error.message;
    } finally { els.loginBtn.disabled = false; }
  }

  async function loginWithConnectionID() {
    els.loginError.textContent = '';
    try {
      const payload = decodeConnectionID(els.connectionId.value);
      state.token = payload.t;
      localStorage.setItem('comfyremote.web.token', state.token);
      await api('/api/status');
      showApp();
      await refreshDashboard({ loadParameters: true, forceDetails: true });
      schedulePoll();
    } catch (error) { els.loginError.textContent = error.message; }
  }

  function setOptions(select, values, current, emptyLabel = null) {
    const unique = [...new Set((values || []).filter(v => v !== null && v !== undefined).map(String))];
    if (current && !unique.includes(String(current))) unique.unshift(String(current));
    select.innerHTML = '';
    if (emptyLabel !== null) {
      const opt = document.createElement('option'); opt.value = ''; opt.textContent = emptyLabel; select.appendChild(opt);
    }
    unique.forEach(value => { const o = document.createElement('option'); o.value = value; o.textContent = value; select.appendChild(o); });
    select.value = current == null ? '' : String(current);
  }

  function currentParameters() {
    return {
      positive: els.positive.value,
      negative: els.negative.value,
      steps: Number(els.steps.value || 20),
      cfg: Number(els.cfg.value || 7),
      seed: Number(els.seed.value || 0),
      width: Number(els.width.value || 512),
      height: Number(els.height.value || 512),
      sampler: els.sampler.value || '', scheduler: els.scheduler.value || '', checkpoint: els.checkpoint.value || '', lora: els.lora.value || '', vae: els.vae.value || '',
    };
  }

  function applyParameters(p, dashboard) {
    p = p || {};
    els.positive.value = p.positive || '';
    els.negative.value = p.negative || '';
    els.steps.value = p.steps ?? 20; els.cfg.value = p.cfg ?? 7; els.seed.value = p.seed ?? 0; els.width.value = p.width ?? 512; els.height.value = p.height ?? 512;
    setOptions(els.sampler, dashboard?.samplers || [], p.sampler || '', '—');
    setOptions(els.scheduler, dashboard?.schedulers || [], p.scheduler || '', '—');
    setOptions(els.checkpoint, dashboard?.checkpoints || [], p.checkpoint || '', '—');
    setOptions(els.lora, dashboard?.loras || [], p.lora || '', 'Без LoRA');
    setOptions(els.vae, dashboard?.vaes || [], p.vae || '', 'Auto VAE');
    els.advancedSummary.textContent = `${p.steps ?? 20} steps · CFG ${p.cfg ?? 7}`;
    els.promptSyncState.textContent = els.positive.value ? 'Prompt загружен из workflow' : 'Prompt в workflow не найден';
    els.promptSyncState.className = `sync-state ${els.positive.value ? 'ok' : ''}`;
  }


  function renderRemoteAccess(value) {
    state.serve = value || null;
    if (!els.tailscaleServeState) return;
    const installed = !!value?.installed;
    const online = !!value?.online;
    const configured = !!value?.configured;
    const conflict = !!value?.conflict;
    const secureHere = location.protocol === 'https:' && value?.dns && location.hostname.toLowerCase() === String(value.dns).toLowerCase();

    els.tailscaleServeState.className = 'badge';
    els.tailscaleServeSetupBtn.classList.remove('hidden');
    els.tailscaleServeOpenBtn.classList.add('hidden');
    els.tailscaleServeCopyBtn.classList.add('hidden');
    els.tailscaleServeUrl.classList.add('hidden');

    if (!installed) {
      els.tailscaleServeState.textContent = 'Не установлен';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = 'Установите Tailscale на ПК и войдите в tailnet.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }
    if (!online) {
      els.tailscaleServeState.textContent = 'Offline';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = 'Tailscale установлен, но сейчас не подключён.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }
    if (conflict) {
      els.tailscaleServeState.textContent = 'Занято';
      els.tailscaleServeState.classList.add('warning');
      els.tailscaleServeDetail.textContent = value?.detail || 'Tailscale Serve уже используется другой конфигурацией.';
      els.tailscaleServeSetupBtn.disabled = true;
      return;
    }

    els.tailscaleServeSetupBtn.disabled = false;
    if (configured && value?.https_url) {
      els.tailscaleServeState.textContent = secureHere ? 'HTTPS активен' : 'Готово';
      els.tailscaleServeState.classList.add('secure');
      els.tailscaleServeDetail.textContent = secureHere
        ? 'Вы уже используете защищённое Tailscale HTTPS-подключение.'
        : 'Защищённый адрес доступен внутри вашего tailnet и подходит для PWA.';
      els.tailscaleServeUrl.textContent = value.https_url;
      els.tailscaleServeUrl.classList.remove('hidden');
      els.tailscaleServeSetupBtn.classList.add('hidden');
      if (!secureHere) els.tailscaleServeOpenBtn.classList.remove('hidden');
      els.tailscaleServeCopyBtn.classList.remove('hidden');
      return;
    }

    els.tailscaleServeState.textContent = 'Не настроен';
    els.tailscaleServeDetail.textContent = value?.dns
      ? `Готово к настройке для ${value.dns}.`
      : 'Tailscale подключён. Настройте HTTPS одним нажатием.';
  }

  async function refreshRemoteAccess(force = false) {
    if (!state.token || !els.tailscaleServeState) return;
    try {
      const value = await api(`/api/tailscale/serve-status${force ? '?force=1' : ''}`);
      renderRemoteAccess(value);
    } catch (error) {
      els.tailscaleServeState.textContent = 'Ошибка';
      els.tailscaleServeState.className = 'badge warning';
      els.tailscaleServeDetail.textContent = error.message;
    }
  }

  async function enableTailscaleHTTPS() {
    if (!els.tailscaleServeSetupBtn) return;
    els.tailscaleServeSetupBtn.disabled = true;
    els.tailscaleServeSetupBtn.textContent = 'Настройка…';
    try {
      const value = await api('/api/tailscale/serve-enable', { method: 'POST' });
      renderRemoteAccess(value);
      toast('Tailscale HTTPS настроен');
    } catch (error) {
      toast(error.message);
      els.tailscaleServeDetail.textContent = error.message;
      await refreshRemoteAccess(true);
    } finally {
      els.tailscaleServeSetupBtn.textContent = 'Настроить HTTPS';
      if (!state.serve?.configured && !state.serve?.conflict) els.tailscaleServeSetupBtn.disabled = false;
    }
  }

  function openTailscaleHTTPS() {
    const url = state.serve?.https_url;
    if (url) window.location.assign(url);
  }

  async function copyTailscaleHTTPS() {
    const url = state.serve?.https_url;
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
      toast('HTTPS-ссылка скопирована');
    } catch {
      toast('Скопируйте ссылку из карточки');
    }
  }

  function formatMetric(value, suffix = '') { return value === null || value === undefined || Number.isNaN(Number(value)) ? '—' : `${Number(value).toFixed(value < 10 && suffix === ' GB' ? 1 : 0)}${suffix}`; }

  function renderStats(system) {
    const items = [
      ['GPU', system?.gpu_percent == null ? '—' : `${Math.round(system.gpu_percent)}%${system.gpu_temperature != null ? `  ${Math.round(system.gpu_temperature)}°` : ''}`],
      ['CPU', system?.cpu_percent == null ? '—' : `${Math.round(system.cpu_percent)}%`],
      ['RAM', system ? `${formatMetric(system.ram_used_gb,' GB')} / ${formatMetric(system.ram_total_gb,' GB')}` : '—'],
      ['VRAM', system?.vram_total_gb != null ? `${formatMetric(system.vram_used_gb,' GB')} / ${formatMetric(system.vram_total_gb,' GB')}` : '—'],
    ];
    els.systemStats.innerHTML = items.map(([label, value]) => `<div class="stat"><div class="label">${escapeHtml(label)}</div><div class="value">${escapeHtml(value)}</div></div>`).join('');
  }

  function stageTitle(stage, running, queue) {
    const map = { queued:'Queued', starting:'Starting…', sampling:'Sampling…', executing:'Executing…', saving:'Saving…', complete:'Complete', stopped:'Stopped', error:'Error', offline:'Offline', idle:'Ready' };
    return map[stage] || (running ? 'Executing…' : queue ? 'Queued' : 'Ready');
  }

  function renderGeneration(d) {
    const progress = Math.max(0, Math.min(1, Number(d.progress || 0)));
    els.generationStage.textContent = stageTitle(d.stage, d.running, d.queue_remaining);
    els.progressBar.style.width = `${Math.round(progress * 100)}%`;
    els.progressText.textContent = `${Math.round(progress * 100)}%`;
    els.currentNode.textContent = d.current_node ? `Node #${d.current_node}` : '—';
    els.queueCount.textContent = String(d.queue_remaining || 0);
    const start = Number(d.started_at || 0), end = Number(d.finished_at || 0) || Date.now()/1000;
    const seconds = start ? Math.max(0, Math.floor(end - start)) : 0;
    els.elapsed.textContent = `${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`;
    els.stopBtn.disabled = !d.running && !(d.queue_remaining > 0);
    els.generateBtn.disabled = !d.available || state.loading;
  }

  function renderWorkflows(d, selectionChanged) {
    const current = d.selected_workflow || state.workflowID || '';
    els.workflowSelect.innerHTML = '';
    (d.workflows || []).forEach(w => {
      const o = document.createElement('option'); o.value = w.id; o.textContent = w.name; o.disabled = w.executable === false; els.workflowSelect.appendChild(o);
    });
    if (current) els.workflowSelect.value = current;
    const wf = (d.workflows || []).find(x => x.id === current);
    els.workflowMeta.textContent = wf ? `${wf.node_count || 0} нод · ${wf.format || wf.source || ''}${wf.executable === false ? ' · только просмотр' : ''}` : 'Workflow не выбран';
    if (selectionChanged && current) {
      state.workflowID = current; localStorage.setItem('comfyremote.web.workflow', current);
    }
  }

  function nodeIdentity(node) { return `${node.class_type || ''} ${node.title || ''}`.toLowerCase().replace(/_/g,''); }
  function scalarInputs(node) { return (node.inputs || []).filter(i => i.value_type !== 'connection'); }
  function findMediaInput(node, kind) {
    const id = nodeIdentity(node), scalars = scalarInputs(node);
    const names = {
      image:['image','input_image','start_image','first_frame','init_image','source_image','filename','file'],
      video:['video','input_video','video_path','source_video','filename','file'],
      audio:['audio','input_audio','audio_path','sound','music','filename','file'],
    }[kind];
    const explicit = scalars.find(i => names.includes(String(i.name).toLowerCase()));
    if (explicit) return explicit;
    if (id.includes(kind) && (id.includes('load') || id.includes('input'))) return scalars.find(i => ['string','json',''].includes(String(i.value_type || '').toLowerCase())) || scalars[0];
    return null;
  }
  function isOutputNode(node) { const id = nodeIdentity(node); return /(save|preview).*(image|video|audio|sound|gif|webp|mp4)|videocombine|audiooutput/.test(id); }

  function renderDynamicInputs(details) {
    const groups = { audio:[], video:[], image:[] };
    for (const node of (details?.nodes || [])) {
      for (const kind of ['audio','video','image']) {
        const input = findMediaInput(node, kind); if (input) { groups[kind].push({node,input}); break; }
      }
    }
    const label = {audio:'Audio Input',video:'Video Input',image:'Image Input'};
    const icon = {audio:'♬',video:'▣',image:'▧'};
    els.dynamicInputs.innerHTML = Object.entries(groups).filter(([,items]) => items.length).map(([kind,items]) => `
      <section class="card glass dynamic-card"><div class="section-head"><h2>${icon[kind]} ${label[kind]}</h2><span class="badge">${items.length}</span></div>
      ${items.map(({node,input}) => `<div class="input-node"><div><div class="node-title">${escapeHtml(node.title || node.class_type)}</div><div class="node-sub">#${escapeHtml(node.id)} · ${escapeHtml(input.name)}${input.value ? ` · ${escapeHtml(input.value)}` : ''}</div></div><button class="file-button" data-media-node="${escapeAttr(node.id)}" data-media-input="${escapeAttr(input.name)}" data-media-kind="${kind}">Выбрать</button></div>`).join('')}
      </section>`).join('');
    els.dynamicInputs.querySelectorAll('[data-media-node]').forEach(btn => btn.addEventListener('click', () => chooseMedia(btn.dataset.mediaNode, btn.dataset.mediaInput, btn.dataset.mediaKind)));

    const outputs = (details?.nodes || []).filter(isOutputNode);
    els.outputCard.classList.toggle('hidden', outputs.length === 0); els.outputCount.textContent = String(outputs.length);
    if (outputs.length) {
      const key = `comfyremote.web.output.${state.workflowID}`;
      const saved = localStorage.getItem(key) || '';
      const current = outputs.some(n => n.id === saved) ? saved : outputs[0].id;
      els.outputSelect.innerHTML = outputs.map(n => `<option value="${escapeAttr(n.id)}">${escapeHtml(n.title || n.class_type)} (#${escapeHtml(n.id)})</option>`).join('');
      els.outputSelect.value = current; state.outputNodeID = current;
      els.outputOnly.checked = localStorage.getItem(`${key}.only`) === '1';
    }
  }

  async function loadWorkflowDetails() {
    if (!state.workflowID) { state.details = null; renderDynamicInputs(null); return; }
    try {
      state.details = await api(`/api/comfy/workflow/details?workflow_id=${encodeURIComponent(state.workflowID)}`);
      renderDynamicInputs(state.details); renderNodeList();
    } catch (error) { toast(`Workflow details: ${error.message}`); }
  }

  async function refreshDashboard({ loadParameters = false, forceDetails = false } = {}) {
    if (!state.token || state.loading) return;
    state.loading = true;
    try {
      const requested = state.workflowID ? `?workflow_id=${encodeURIComponent(state.workflowID)}` : '';
      const d = await api(`/api/comfy/dashboard${requested}`);
      const previous = state.workflowID;
      const selected = d.selected_workflow || previous || d.workflows?.[0]?.id || '';
      const changed = selected !== previous;
      state.dashboard = d; state.workflowID = selected;
      if (selected) localStorage.setItem('comfyremote.web.workflow', selected);
      els.connectionDot.classList.toggle('online', !!d.available);
      els.connectionText.textContent = d.available ? `${d.running ? 'Generating' : 'Connected'} · ${d.media_type || 'ComfyUI'}` : 'ComfyUI offline';
      renderStats(d.system); renderWorkflows(d, changed); renderGeneration(d);
      if (loadParameters || changed || !els.positive.dataset.loaded) { applyParameters(d.parameters, d); els.positive.dataset.loaded = '1'; }
      if (forceDetails || changed || !state.details || state.details.workflow_id !== selected) await loadWorkflowDetails();
      await renderResults(d.images || []);
    } catch (error) {
      els.connectionDot.classList.remove('online'); els.connectionText.textContent = 'Disconnected';
      if (!String(error.message).includes('401')) toast(error.message);
    } finally { state.loading = false; }
  }

  function schedulePoll() {
    clearTimeout(state.pollTimer);
    if (!state.token) return;
    const delay = state.dashboard?.running ? 900 : (state.dashboard?.available ? 2500 : 3500);
    state.pollTimer = setTimeout(async () => { await refreshDashboard({ loadParameters:false }); schedulePoll(); }, delay);
  }

  function schedulePromptSync() {
    clearTimeout(state.promptTimer);
    els.promptSyncState.textContent = 'Изменено · сохранение…'; els.promptSyncState.className = 'sync-state busy';
    state.promptTimer = setTimeout(syncPrompt, 550);
  }

  async function syncPrompt() {
    if (!state.workflowID) return;
    try {
      const value = await api('/api/comfy/prompt/set', { method:'POST', body:{ workflow_id:state.workflowID, positive:els.positive.value, negative:els.negative.value } });
      els.promptSyncState.textContent = `Сохранено в workflow${value?.positive_nodes?.length ? ` · node ${value.positive_nodes.join(', ')}` : ''}`;
      els.promptSyncState.className = 'sync-state ok';
      await loadWorkflowDetails();
    } catch (error) { els.promptSyncState.textContent = `Не сохранено: ${error.message}`; els.promptSyncState.className = 'sync-state'; }
  }

  function randomSeed() { const value = Math.floor(Math.random() * Number.MAX_SAFE_INTEGER); els.seed.value = String(value); toast(`Seed: ${value}`); }

  async function generate() {
    if (!state.workflowID) return toast('Выберите workflow');
    state.loading = true; renderGeneration(state.dashboard || {});
    try {
      clearTimeout(state.promptTimer); await syncPrompt();
      const body = { workflow_id: state.workflowID, parameters: currentParameters() };
      if (els.outputOnly.checked && state.outputNodeID) body.output_node_id = state.outputNodeID;
      await api('/api/comfy/generate', { method:'POST', body });
      toast('Генерация запущена'); await refreshDashboard({ loadParameters:false });
    } catch (error) { toast(`Generate: ${error.message}`); }
    finally { state.loading = false; schedulePoll(); }
  }

  async function stopGeneration() {
    try { await api('/api/comfy/interrupt',{method:'POST',body:{}}); try { await api('/api/comfy/queue/clear',{method:'POST',body:{}}); } catch {} toast('Генерация остановлена'); await refreshDashboard({loadParameters:false}); }
    catch(error){ toast(error.message); }
  }

  function chooseMedia(nodeID, inputName, kind) {
    state.mediaTarget = { nodeID, inputName, kind };
    els.mediaFile.accept = kind === 'image' ? 'image/*' : kind === 'video' ? 'video/*' : 'audio/*';
    els.mediaFile.value = ''; els.mediaFile.click();
  }

  async function fileToBase64(file) { const buffer = await file.arrayBuffer(); let binary=''; const bytes=new Uint8Array(buffer); const chunk=0x8000; for(let i=0;i<bytes.length;i+=chunk) binary += String.fromCharCode(...bytes.subarray(i,i+chunk)); return btoa(binary); }

  async function uploadMedia(file) {
    const target = state.mediaTarget; if (!target || !file) return;
    toast('Загрузка файла…');
    try {
      const b64 = await fileToBase64(file);
      await api('/api/comfy/input/set',{method:'POST',body:{workflow_id:state.workflowID,node_id:target.nodeID,input_name:target.inputName,filename:file.name,content_base64:b64}});
      toast('Файл загружен в ComfyUI'); await loadWorkflowDetails();
    } catch(error){ toast(`Upload: ${error.message}`); }
  }

  async function importWorkflow(file) {
    if (!file) return;
    try {
      const b64 = await fileToBase64(file);
      const value = await api('/api/comfy/workflows/import',{method:'POST',body:{filename:file.name,content_base64:b64}});
      toast(`Импортирован: ${value.workflow?.name || file.name}`);
      if (value.workflow?.id) state.workflowID = value.workflow.id;
      await refreshDashboard({loadParameters:true,forceDetails:true});
    } catch(error){ toast(`Import: ${error.message}`); }
  }

  function resultKind(item) { const ext=(item.filename||'').split('.').pop().toLowerCase(); if(['mp4','mov','m4v','webm','avi','mkv'].includes(ext))return'video'; if(['mp3','wav','m4a','aac','flac','ogg','opus','aiff','aif','wma'].includes(ext))return'audio'; return'image'; }
  function resultPath(item){ const q=new URLSearchParams({filename:item.filename||'',subfolder:item.subfolder||'',type:item.type||'output'}); return `/api/comfy/result?${q}`; }

  async function getResultUrl(item) {
    const key=item.id || `${item.prompt_id}|${item.type}|${item.subfolder}|${item.filename}`;
    if(state.resultUrls.has(key))return state.resultUrls.get(key);
    const blob=await apiBlob(resultPath(item)); const url=URL.createObjectURL(blob); state.resultUrls.set(key,url); return url;
  }

  async function renderResults(items) {
    const signature=items.map(i=>i.id||i.filename).join('|');
    if(signature===state.lastResultSignature)return; state.lastResultSignature=signature;
    if(!items.length){els.resultsGrid.innerHTML='<div class="empty">Результатов пока нет</div>';return;}
    els.resultsGrid.innerHTML=items.map((item,index)=>`<div class="result loading ${resultKind(item)}" data-result-index="${index}"><div class="empty">…</div><span class="result-type">${resultKind(item)}</span></div>`).join('');
    items.forEach(async(item,index)=>{
      const host=els.resultsGrid.querySelector(`[data-result-index="${index}"]`); if(!host)return;
      try{const url=await getResultUrl(item);const kind=resultKind(item);if(kind==='image')host.innerHTML=`<img src="${url}" alt="result"><span class="result-type">image</span>`;else if(kind==='video')host.innerHTML=`<video src="${url}" muted playsinline preload="metadata"></video><span class="result-type">video</span>`;else host.innerHTML=`<audio src="${url}" controls preload="metadata"></audio>`;host.addEventListener('click',e=>{if(e.target.tagName==='AUDIO')return;openMedia(item,url,kind);});}catch{host.innerHTML='<div class="empty">Не загрузилось</div>';}
    });
  }

  function openMedia(item,url,kind){ els.mediaViewerBody.innerHTML=kind==='image'?`<img src="${url}" alt="${escapeAttr(item.filename||'')}">`:kind==='video'?`<video src="${url}" controls autoplay playsinline></video>`:`<audio src="${url}" controls autoplay></audio>`;els.mediaModal.classList.remove('hidden'); }
  function closeMedia(){els.mediaModal.classList.add('hidden');els.mediaViewerBody.querySelectorAll('video,audio').forEach(x=>x.pause());els.mediaViewerBody.innerHTML='';}

  function renderNodeList() {
    if (!state.details) return;
    const query=(els.nodeSearch.value||'').trim().toLowerCase();
    const nodes=(state.details.nodes||[]).filter(n=>!query||`${n.title} ${n.class_type} ${n.id}`.toLowerCase().includes(query));
    els.nodeList.innerHTML=nodes.map(node=>{
      const editable=scalarInputs(node);
      return `<div class="node-card" data-node-card="${escapeAttr(node.id)}"><div class="node-card-head"><div><div class="node-card-title">${escapeHtml(node.title||node.class_type)} <span class="badge">#${escapeHtml(node.id)}</span></div><div class="node-card-class">${escapeHtml(node.class_type)}</div></div></div><div class="node-inputs">${editable.length?editable.map(input=>`<label>${escapeHtml(input.name)}<input class="input" data-node-input="${escapeAttr(input.name)}" value="${escapeAttr(input.value||'')}"></label>`).join(''):'<div class="muted small">Нет scalar inputs</div>'}</div>${editable.length?'<button class="button secondary node-save">Сохранить ноду</button>':''}</div>`;
    }).join('')||'<div class="empty">Ноды не найдены</div>';
    els.nodeList.querySelectorAll('.node-save').forEach(btn=>btn.addEventListener('click',()=>saveNode(btn.closest('[data-node-card]'))));
  }

  async function saveNode(card){const nodeID=card.dataset.nodeCard;const inputs={};card.querySelectorAll('[data-node-input]').forEach(input=>inputs[input.dataset.nodeInput]=input.value);try{await api('/api/comfy/workflow/node/update',{method:'POST',body:{workflow_id:state.workflowID,node_id:nodeID,inputs}});toast(`Node #${nodeID} сохранён`);await refreshDashboard({loadParameters:true,forceDetails:true});}catch(error){toast(error.message);}}

  function escapeHtml(value){return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));}
  function escapeAttr(value){return escapeHtml(value).replace(/`/g,'&#096;');}

  function bindEvents(){
    els.loginBtn.addEventListener('click',loginWithPassword);els.password.addEventListener('keydown',e=>{if(e.key==='Enter')loginWithPassword();});els.connectionIdBtn.addEventListener('click',loginWithConnectionID);
    els.tailscaleServeSetupBtn?.addEventListener('click',enableTailscaleHTTPS);els.tailscaleServeOpenBtn?.addEventListener('click',openTailscaleHTTPS);els.tailscaleServeCopyBtn?.addEventListener('click',copyTailscaleHTTPS);
    $('refreshBtn').addEventListener('click',()=>refreshDashboard({loadParameters:true,forceDetails:true}));els.workflowReloadBtn.addEventListener('click',()=>refreshDashboard({loadParameters:true,forceDetails:true}));$('resultsRefreshBtn').addEventListener('click',()=>{state.lastResultSignature='';refreshDashboard({loadParameters:false});});
    els.workflowSelect.addEventListener('change',async()=>{state.workflowID=els.workflowSelect.value;localStorage.setItem('comfyremote.web.workflow',state.workflowID);els.positive.dataset.loaded='';await refreshDashboard({loadParameters:true,forceDetails:true});});
    els.positive.addEventListener('input',schedulePromptSync);els.negative.addEventListener('input',schedulePromptSync);
    $('clearPromptBtn').addEventListener('click',()=>{els.positive.value='';schedulePromptSync();});$('copyPromptBtn').addEventListener('click',async()=>{await navigator.clipboard?.writeText(els.positive.value);toast('Prompt скопирован');});
    $('advancedToggle').addEventListener('click',()=>els.advancedPanel.classList.toggle('hidden'));$('seedInlineBtn').addEventListener('click',randomSeed);els.randomBtn.addEventListener('click',randomSeed);els.generateBtn.addEventListener('click',generate);els.stopBtn.addEventListener('click',stopGeneration);
    els.outputSelect.addEventListener('change',()=>{state.outputNodeID=els.outputSelect.value;localStorage.setItem(`comfyremote.web.output.${state.workflowID}`,state.outputNodeID);});els.outputOnly.addEventListener('change',()=>localStorage.setItem(`comfyremote.web.output.${state.workflowID}.only`,els.outputOnly.checked?'1':'0'));
    $('importWorkflowBtn').addEventListener('click',()=>{els.workflowFile.value='';els.workflowFile.click();});els.workflowFile.addEventListener('change',()=>importWorkflow(els.workflowFile.files?.[0]));els.mediaFile.addEventListener('change',()=>uploadMedia(els.mediaFile.files?.[0]));
    $('nodesBtn').addEventListener('click',()=>{renderNodeList();els.nodeModal.classList.remove('hidden');});els.nodeSearch.addEventListener('input',renderNodeList);document.querySelectorAll('[data-close-modal]').forEach(x=>x.addEventListener('click',()=>els.nodeModal.classList.add('hidden')));document.querySelectorAll('[data-close-media]').forEach(x=>x.addEventListener('click',closeMedia));
    $('logoutBtn').addEventListener('click',()=>showLogin('Вы вышли из Web Remote.'));
    document.addEventListener('visibilitychange',()=>{if(!document.hidden&&state.token){refreshDashboard({loadParameters:false});refreshRemoteAccess();}});
  }

  async function boot(){bindEvents();await probe();if(state.token){try{await api('/api/status');showApp();await refreshDashboard({loadParameters:true,forceDetails:true});schedulePoll();return;}catch{showLogin('Войдите в PC Remote Server.');}}showLogin();}

  if('serviceWorker' in navigator){window.addEventListener('load',()=>navigator.serviceWorker.register('/web/sw.js',{scope:'/web/'}).catch(()=>{}));}
  boot();
})();
