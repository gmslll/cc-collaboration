(() => {
  const $ = (id) => document.getElementById(id);
  const params = new URLSearchParams(location.search);
  const els = {
    authPanel: $('authPanel'),
    controlPanel: $('controlPanel'),
    identity: $('identity'),
    hostMode: $('hostMode'),
    viewerMode: $('viewerMode'),
    roomInput: $('roomInput'),
    startButton: $('startButton'),
    stopButton: $('stopButton'),
    shareLinkWrap: $('shareLinkWrap'),
    shareLink: $('shareLink'),
    copyLink: $('copyLink'),
    video: $('video'),
    emptyState: $('emptyState'),
    status: $('status'),
  };

  const state = {
    mode: params.get('mode') === 'viewer' ? 'viewer' : 'host',
    room: sanitizeRoom(params.get('room')) || randomRoom(),
    token: localStorage.getItem('token') || '',
    identity: localStorage.getItem('identity') || '',
    ws: null,
    connId: 0,
    stream: null,
    peers: new Map(),
    running: false,
  };

  const iceServers = [{ urls: 'stun:stun.l.google.com:19302' }];

  function sanitizeRoom(value) {
    const room = (value || '').trim();
    return /^[A-Za-z0-9_-]{4,64}$/.test(room) ? room : '';
  }

  function randomRoom() {
    const bytes = new Uint8Array(5);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => (b % 36).toString(36)).join('').toUpperCase();
  }

  function setStatus(text, error = false) {
    els.status.textContent = text;
    els.status.classList.toggle('error', error);
  }

  function updateMode() {
    els.hostMode.classList.toggle('active', state.mode === 'host');
    els.viewerMode.classList.toggle('active', state.mode === 'viewer');
    els.startButton.textContent = state.mode === 'host' ? '开始共享' : '开始观看';
  }

  function updateLink() {
    const url = new URL(location.href);
    url.searchParams.set('mode', 'viewer');
    url.searchParams.set('room', state.room);
    els.shareLink.value = url.toString();
    els.shareLinkWrap.hidden = state.mode !== 'host';
  }

  function updateUrl() {
    const url = new URL(location.href);
    url.searchParams.set('mode', state.mode);
    url.searchParams.set('room', state.room);
    history.replaceState(null, '', url.toString());
    updateLink();
  }

  function requireAuth() {
    if (state.token) {
      els.authPanel.hidden = true;
      els.controlPanel.hidden = false;
      els.identity.textContent = state.identity ? `账号 ${state.identity}` : '已登录';
      return true;
    }
    els.authPanel.hidden = false;
    els.controlPanel.hidden = true;
    els.identity.textContent = '未登录';
    setStatus('请先登录 Web 客户端，然后回到此页面。', true);
    return false;
  }

  function wsUrl(role) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const url = new URL(`${proto}//${location.host}/v1/screen-share/ws`);
    url.searchParams.set('role', role);
    url.searchParams.set('room', state.room);
    url.searchParams.set('access_token', state.token);
    return url.toString();
  }

  function send(frame) {
    if (!state.ws || state.ws.readyState !== WebSocket.OPEN) return;
    frame.from = state.connId;
    state.ws.send(JSON.stringify(frame));
  }

  function connect(role) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(wsUrl(role));
      state.ws = ws;
      const timer = window.setTimeout(() => reject(new Error('连接超时')), 12000);
      ws.addEventListener('open', () => setStatus('信令已连接，等待对端...'));
      ws.addEventListener('message', (event) => onMessage(event.data));
      ws.addEventListener('close', () => {
        if (state.running) setStatus('信令连接已断开', true);
      });
      ws.addEventListener('error', () => {
        window.clearTimeout(timer);
        reject(new Error('无法连接信令服务'));
      });
      const onHello = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.t !== '_hello') return;
          state.connId = Number(msg.connId || 0);
          window.clearTimeout(timer);
          ws.removeEventListener('message', onHello);
          resolve();
        } catch (_) {}
      };
      ws.addEventListener('message', onHello);
    });
  }

  async function start() {
    if (!requireAuth()) return;
    const room = sanitizeRoom(els.roomInput.value);
    if (!room) {
      setStatus('房间码只能包含字母、数字、下划线或连字符，长度 4-64。', true);
      return;
    }
    state.room = room;
    state.running = true;
    updateUrl();
    els.startButton.disabled = true;
    els.stopButton.disabled = false;
    try {
      if (state.mode === 'host') {
        await startHost();
      } else {
        await startViewer();
      }
    } catch (error) {
      setStatus(error.message || String(error), true);
      stop();
    }
  }

  async function startHost() {
    state.stream = await navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: { ideal: 24, max: 30 } },
      audio: true,
    });
    els.video.srcObject = state.stream;
    els.video.muted = true;
    els.emptyState.hidden = true;
    state.stream.getVideoTracks()[0]?.addEventListener('ended', stop);
    await connect('host');
    setStatus(`房间 ${state.room} 已就绪，等待观看端加入。`);
  }

  async function startViewer() {
    els.video.muted = false;
    await connect('viewer');
    setStatus(`已加入房间 ${state.room}，等待共享端。`);
  }

  function stop() {
    state.running = false;
    for (const peer of state.peers.values()) {
      peer.pc.close();
    }
    state.peers.clear();
    state.ws?.close();
    state.ws = null;
    state.connId = 0;
    state.stream?.getTracks().forEach((track) => track.stop());
    state.stream = null;
    els.video.srcObject = null;
    els.emptyState.hidden = false;
    els.startButton.disabled = false;
    els.stopButton.disabled = true;
    setStatus('已停止');
  }

  async function onMessage(raw) {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (_) {
      return;
    }
    if (msg.t === '_hello') {
      state.connId = Number(msg.connId || 0);
      return;
    }
    if (msg.t === '_peer') {
      await onPeer(msg);
      return;
    }
    if (msg.t === 'offer' && state.mode === 'viewer') {
      await onOffer(msg);
    } else if (msg.t === 'answer' && state.mode === 'host') {
      await onAnswer(msg);
    } else if (msg.t === 'ice') {
      await onIce(msg);
    }
  }

  async function onPeer(msg) {
    const peerId = Number(msg.connId || 0);
    if (!peerId) return;
    if (msg.event === 'disconnect') {
      const peer = state.peers.get(peerId);
      peer?.pc.close();
      state.peers.delete(peerId);
      setStatus(state.mode === 'host' ? `观看端 ${peerId} 已离开。` : '共享端已离开。');
      return;
    }
    if (state.mode === 'host' && msg.role === 'viewer') {
      await callViewer(peerId);
    }
  }

  function makePeer(peerId) {
    const existing = state.peers.get(peerId);
    if (existing) return existing;
    const pc = new RTCPeerConnection({ iceServers });
    const peer = { pc, pendingIce: [] };
    state.peers.set(peerId, peer);

    pc.addEventListener('icecandidate', (event) => {
      if (event.candidate) {
        send({ t: 'ice', to: peerId, candidate: event.candidate });
      }
    });
    pc.addEventListener('connectionstatechange', () => {
      setStatus(`P2P 状态：${pc.connectionState}`);
    });
    pc.addEventListener('track', (event) => {
      els.video.srcObject = event.streams[0];
      els.emptyState.hidden = true;
    });
    return peer;
  }

  async function callViewer(peerId) {
    const peer = makePeer(peerId);
    for (const track of state.stream.getTracks()) {
      peer.pc.addTrack(track, state.stream);
    }
    const offer = await peer.pc.createOffer();
    await peer.pc.setLocalDescription(offer);
    send({ t: 'offer', to: peerId, sdp: peer.pc.localDescription });
    setStatus(`正在连接观看端 ${peerId}...`);
  }

  async function onOffer(msg) {
    const from = Number(msg.from || 0);
    if (!from || !msg.sdp) return;
    const peer = makePeer(from);
    await peer.pc.setRemoteDescription(msg.sdp);
    for (const candidate of peer.pendingIce.splice(0)) {
      await peer.pc.addIceCandidate(candidate);
    }
    const answer = await peer.pc.createAnswer();
    await peer.pc.setLocalDescription(answer);
    send({ t: 'answer', to: from, sdp: peer.pc.localDescription });
    setStatus('正在建立 P2P 连接...');
  }

  async function onAnswer(msg) {
    const from = Number(msg.from || 0);
    const peer = state.peers.get(from);
    if (!peer || !msg.sdp) return;
    await peer.pc.setRemoteDescription(msg.sdp);
    for (const candidate of peer.pendingIce.splice(0)) {
      await peer.pc.addIceCandidate(candidate);
    }
  }

  async function onIce(msg) {
    const from = Number(msg.from || 0);
    if (!from || !msg.candidate) return;
    const peer = state.peers.get(from) || makePeer(from);
    const candidate = new RTCIceCandidate(msg.candidate);
    if (!peer.pc.remoteDescription) {
      peer.pendingIce.push(candidate);
      return;
    }
    await peer.pc.addIceCandidate(candidate);
  }

  els.hostMode.addEventListener('click', () => {
    if (state.running) return;
    state.mode = 'host';
    updateMode();
    updateUrl();
  });
  els.viewerMode.addEventListener('click', () => {
    if (state.running) return;
    state.mode = 'viewer';
    updateMode();
    updateUrl();
  });
  els.roomInput.addEventListener('input', () => {
    state.room = els.roomInput.value.trim();
    if (!state.running && sanitizeRoom(state.room)) updateLink();
  });
  els.startButton.addEventListener('click', start);
  els.stopButton.addEventListener('click', stop);
  els.copyLink.addEventListener('click', async () => {
    await navigator.clipboard.writeText(els.shareLink.value);
    setStatus('观看链接已复制。');
  });

  els.roomInput.value = state.room;
  updateMode();
  updateUrl();
  requireAuth();
})();
