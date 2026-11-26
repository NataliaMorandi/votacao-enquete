'use strict';

/* ------------------------------------------------------------------
 * Página da enquete
 * - enquete anônima  -> não pede nome
 * - enquete com nome -> exige nome
 * - max_escolhas 1   -> radio (uma opção)
 * - max_escolhas 2   -> checkbox (até duas opções)
 *
 * Identificação do votante: uuid aleatório guardado no localStorage.
 * Não coletamos CPF nem IP; o id serve só para limitar votos repetidos.
 * ------------------------------------------------------------------ */

const enqueteId = decodeURIComponent(window.location.pathname.split('/e/')[1] || '');

const el = (id) => document.getElementById(id);
const elTitulo = el('titulo');
const elDescricao = el('descricao');
const elStatus = el('status');
const elModo = el('modo');
const elPrazo = el('prazo');
const elOpcoes = el('opcoes');
const elResultado = el('resultado');
const elTotal = el('total');
const elTotalLabel = el('total-label');
const elFonte = el('fonte');
const elVotantes = el('votantes');
const elCardVotantes = el('card-votantes');
const form = el('form-voto');
const cardVoto = el('card-voto');
const campoNome = el('campo-nome');
const inputNome = el('nome');
const msg = el('msg');
const btnVotar = el('btn-votar');
const avisoPrivacidade = el('aviso-privacidade');

let enquete = null;
let montouOpcoes = false;
let votosAnteriores = [];

// --- identidade anônima do navegador -----------------------------
// crypto.randomUUID() só existe em contexto seguro (HTTPS ou localhost).
// Como a demo roda em http://IP:3000, usamos fallback com getRandomValues
// (disponível em HTTP) e, em último caso, Math.random.
function gerarUuid() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }

  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; // versão 4
    b[8] = (b[8] & 0x3f) | 0x80; // variante RFC 4122
    const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }

  // último recurso (navegadores muito antigos)
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function votanteId() {
  let id = localStorage.getItem('votante_id');
  if (!id) {
    id = gerarUuid();
    localStorage.setItem('votante_id', id);
  }
  return id;
}

function chaveVotos() {
  return `votos_${enqueteId}`;
}

function lerVotosAnteriores() {
  try {
    return JSON.parse(localStorage.getItem(chaveVotos()) || '[]');
  } catch {
    return [];
  }
}

function salvarVotos(opcaoIds) {
  const atuais = new Set(lerVotosAnteriores());
  opcaoIds.forEach((o) => atuais.add(o));
  localStorage.setItem(chaveVotos(), JSON.stringify([...atuais]));
}

// --- utilidades ---------------------------------------------------
function escapar(texto) {
  const div = document.createElement('div');
  div.textContent = texto == null ? '' : String(texto);
  return div.innerHTML;
}

function mostrarMsg(texto, tipo) {
  msg.textContent = texto;
  msg.className = 'msg' + (tipo ? ' ' + tipo : '');
}

function tempoRestante(prazo) {
  const ms = new Date(prazo).getTime() - Date.now();
  if (ms <= 0) return 'encerrada';
  const min = Math.floor(ms / 60000);
  if (min < 1) return 'encerra em menos de 1 min';
  if (min < 60) return `encerra em ${min} min`;
  const h = Math.floor(min / 60);
  return `encerra em ${h}h${min % 60 ? ' ' + (min % 60) + 'min' : ''}`;
}

function estaAberta() {
  return enquete && enquete.status === 'aberta' && new Date(enquete.prazo) > new Date();
}

// --- renderização -------------------------------------------------
function renderCabecalho() {
  document.title = enquete.titulo + ' · Enquete';
  elTitulo.textContent = enquete.titulo;
  elDescricao.textContent = enquete.descricao || '';
  elDescricao.style.display = enquete.descricao ? '' : 'none';

  const aberta = estaAberta();
  elStatus.textContent = aberta ? 'aberta' : 'encerrada';
  elStatus.className = 'badge ' + (aberta ? 'aberta' : 'fechada');
  elPrazo.textContent = aberta ? tempoRestante(enquete.prazo) : 'Enquete encerrada';

  elModo.textContent =
    (enquete.anonima ? 'anônima' : 'com nome') +
    ' · ' +
    (enquete.max_escolhas === 2 ? 'até 2 opções' : '1 opção');
  elModo.className = 'badge fechada';

  avisoPrivacidade.textContent = enquete.anonima
    ? 'Enquete anônima: nenhum dado pessoal é solicitado.'
    : 'Enquete identificada: seu nome aparecerá na lista de votantes.';

  campoNome.style.display = enquete.anonima ? 'none' : '';
  elTituloVoto();
}

function elTituloVoto() {
  el('titulo-voto').textContent =
    enquete.max_escolhas === 2 ? 'Seus votos (marque até 2)' : 'Seu voto';
}

function renderOpcoes() {
  if (!enquete.resultado) return;
  if (montouOpcoes) return;

  const tipo = enquete.max_escolhas === 2 ? 'checkbox' : 'radio';
  votosAnteriores = lerVotosAnteriores();

  elOpcoes.innerHTML = enquete.resultado
    .map((r) => {
      const jaVotou = votosAnteriores.includes(r.opcao_id);
      return `
        <label class="opcao-voto ${jaVotou ? 'selecionada' : ''}" data-id="${r.opcao_id}">
          <input type="${tipo}" name="opcao" value="${r.opcao_id}"
                 ${jaVotou ? 'checked disabled' : ''}>
          <span>${escapar(r.rotulo)}${jaVotou ? ' <small>(seu voto)</small>' : ''}</span>
        </label>`;
    })
    .join('');

  elOpcoes.querySelectorAll('input[type="radio"], input[type="checkbox"]').forEach((input) => {
    input.addEventListener('change', () => {
      if (tipo === 'radio') {
        elOpcoes.querySelectorAll('.opcao-voto').forEach((l) => l.classList.remove('selecionada'));
        input.closest('.opcao-voto').classList.add('selecionada');
        return;
      }

      // checkboxes: no máximo 2 marcados, contando os já votados
      const marcados = selecionados();
      if (marcados.length + votosAnteriores.length > enquete.max_escolhas) {
        input.checked = false;
        mostrarMsg(`Você pode marcar até ${enquete.max_escolhas} opção(ões).`, 'erro');
        return;
      }
      input.closest('.opcao-voto').classList.toggle('selecionada', input.checked);
    });
  });

  montouOpcoes = true;
}

function selecionados() {
  return [...elOpcoes.querySelectorAll('input:checked:not([disabled])')].map((i) => i.value);
}

function renderResultado() {
  elTotal.textContent = enquete.total_votos;
  elTotalLabel.textContent = enquete.total_votos === 1 ? 'voto' : 'votos';
  elFonte.textContent =
    enquete.fonte_contagem === 'redis'
      ? 'contadores em tempo real (Redis)'
      : 'recontado do banco de dados';

  elResultado.innerHTML = enquete.resultado
    .map(
      (r) => `
      <div class="resultado-item">
        <div class="linha">
          <strong>${escapar(r.rotulo)}</strong>
          <span class="pct">${r.votos} voto${r.votos === 1 ? '' : 's'} · ${r.percentual}%</span>
        </div>
        <div class="barra"><span style="width:${r.percentual}%"></span></div>
      </div>`
    )
    .join('');
}

function renderVotantes() {
  if (enquete.anonima || !enquete.votantes || enquete.votantes.length === 0) {
    elCardVotantes.style.display = 'none';
    return;
  }
  elCardVotantes.style.display = '';
  elVotantes.innerHTML = enquete.votantes
    .map(
      (v) => `
      <div class="resultado-item">
        <div class="linha">
          <strong>${escapar(v.nome)}</strong>
          <span class="pct">${escapar((v.opcoes || []).join(', '))}</span>
        </div>
      </div>`
    )
    .join('');
}

function atualizarFormulario() {
  if (!estaAberta()) {
    cardVoto.style.display = 'none';
    return;
  }
  if (votosAnteriores.length >= enquete.max_escolhas) {
    cardVoto.style.display = 'none';
    return;
  }
  cardVoto.style.display = '';
}

// --- dados --------------------------------------------------------
async function carregar() {
  const resp = await fetch(`/enquetes/${enqueteId}/resultado`, { cache: 'no-store' });

  if (!resp.ok) {
    elTitulo.textContent = 'Enquete não encontrada';
    elDescricao.textContent = 'Verifique o link ou volte para a lista.';
    cardVoto.style.display = 'none';
    return false;
  }

  enquete = await resp.json();
  votosAnteriores = lerVotosAnteriores();
  renderCabecalho();
  renderOpcoes();
  renderResultado();
  renderVotantes();
  atualizarFormulario();
  return true;
}

// --- envio --------------------------------------------------------
const ERROS = {
  votante_id_invalido: 'Não foi possível identificar este navegador. Recarregue a página.',
  nome_obrigatorio: 'Esta enquete é identificada: informe seu nome.',
  opcao_ids_invalido: 'Selecione pelo menos uma opção.',
  limite_de_escolhas_excedido: 'Você já atingiu o limite de opções desta enquete.',
  voto_duplicado: 'Você já votou nesta opção.',
  enquete_fechada: 'Esta enquete já foi encerrada.',
  enquete_expirada: 'O prazo desta enquete terminou.',
  opcao_nao_pertence_a_enquete: 'Opção inválida.',
  enquete_nao_encontrada: 'Enquete não encontrada.',
};

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  mostrarMsg('');

  const novas = selecionados();
  if (novas.length === 0) return mostrarMsg('Selecione pelo menos uma opção.', 'erro');

  const total = novas.length + votosAnteriores.length;
  if (total > enquete.max_escolhas) {
    return mostrarMsg(`Você pode votar em até ${enquete.max_escolhas} opção(ões).`, 'erro');
  }

  if (!enquete.anonima) {
    const nome = inputNome.value.trim();
    if (nome.length < 2) return mostrarMsg('Informe seu nome (mínimo 2 caracteres).', 'erro');
  }

  btnVotar.disabled = true;
  btnVotar.textContent = 'Enviando...';

  try {
    const resp = await fetch(`/enquetes/${enqueteId}/votos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        votante_id: votanteId(),
        nome: enquete.anonima ? null : inputNome.value.trim(),
        opcao_ids: novas,
      }),
    });

    const dados = await resp.json();

    if (!resp.ok) {
      mostrarMsg(ERROS[dados.error] || 'Não foi possível registrar o voto.', 'erro');
      return;
    }

    salvarVotos(novas);
    votosAnteriores = lerVotosAnteriores();

    mostrarMsg(
      novas.length > 1 ? ` ${novas.length} votos registrados! Obrigado.` : 'Voto registrado! Obrigado.',
      'ok'
    );
    btnVotar.textContent = 'Registrado';

    setTimeout(carregar, 1200);
  } catch (err) {
    mostrarMsg('Falha de rede: ' + err.message, 'erro');
  } finally {
    if (votosAnteriores.length < (enquete ? enquete.max_escolhas : 1)) {
      btnVotar.disabled = false;
      btnVotar.textContent = 'Votar';
    }
  }
});

// --- inicialização ------------------------------------------------
carregar().then((ok) => {
  if (!ok) return;
  setInterval(() => {
    if (!estaAberta()) return;
    carregar().catch(() => {});
  }, 3000);
});
