'use strict';

/* ------------------------------------------------------------------
 * Página da enquete: votar + resultado em tempo real
 * ------------------------------------------------------------------ */

const enqueteId = decodeURIComponent(window.location.pathname.split('/e/')[1] || '');
const elTitulo = document.getElementById('titulo');
const elDescricao = document.getElementById('descricao');
const elStatus = document.getElementById('status');
const elPrazo = document.getElementById('prazo');
const elOpcoes = document.getElementById('opcoes');
const elResultado = document.getElementById('resultado');
const elTotal = document.getElementById('total');
const elTotalLabel = document.getElementById('total-label');
const elFonte = document.getElementById('fonte');
const form = document.getElementById('form-voto');
const cpfInput = document.getElementById('cpf');
const msg = document.getElementById('msg');
const cardVoto = document.getElementById('card-voto');

let enquete = null;
let opcaoEscolhida = null;
let jaVotou = false;

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

function renderCabecalho() {
  document.title = enquete.titulo + ' · Enquete';
  elTitulo.textContent = enquete.titulo;
  elDescricao.textContent = enquete.descricao || '';
  elDescricao.style.display = enquete.descricao ? '' : 'none';

  const aberta = estaAberta();
  elStatus.textContent = aberta ? 'aberta' : 'encerrada';
  elStatus.className = 'badge ' + (aberta ? 'aberta' : 'fechada');
  elPrazo.textContent = aberta ? tempoRestante(enquete.prazo) : 'Enquete encerrada';
}

function renderOpcoes() {
  if (!enquete.resultado) return;

  // Não recria os radios enquanto o usuário está votando
  if (!elOpcoes.dataset.pronto) {
    elOpcoes.innerHTML = enquete.resultado
      .map(
        (r) => `
        <label class="opcao-voto" data-id="${r.opcao_id}">
          <input type="radio" name="opcao" value="${r.opcao_id}">
          <span>${escapar(r.rotulo)}</span>
        </label>`
      )
      .join('');

    elOpcoes.querySelectorAll('input[type="radio"]').forEach((input) => {
      input.addEventListener('change', () => {
        opcaoEscolhida = input.value;
        elOpcoes.querySelectorAll('.opcao-voto').forEach((l) => l.classList.remove('selecionada'));
        input.closest('.opcao-voto').classList.add('selecionada');
      });
    });
    elOpcoes.dataset.pronto = '1';
  }
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

async function carregar() {
  const resp = await fetch(`/enquetes/${enqueteId}/resultado`, { cache: 'no-store' });

  if (!resp.ok) {
    elTitulo.textContent = 'Enquete não encontrada';
    elDescricao.textContent = 'Verifique o link ou volte para a lista.';
    cardVoto.style.display = 'none';
    return false;
  }

  enquete = await resp.json();
  renderCabecalho();
  renderOpcoes();
  renderResultado();

  if (!estaAberta() || jaVotou) {
    cardVoto.style.display = 'none';
  }
  return true;
}

cpfInput.addEventListener('input', () => {
  const d = cpfInput.value.replace(/\D/g, '').slice(0, 11);
  cpfInput.value = d
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d{1,2})$/, '$1-$2');
});

const ERROS = {
  cpf_invalido: 'CPF inválido: informe os 11 dígitos.',
  cpf_ja_votou: 'Este CPF já votou nesta enquete.',
  enquete_fechada: 'Esta enquete já foi encerrada.',
  enquete_expirada: 'O prazo desta enquete terminou.',
  opcao_nao_pertence_a_enquete: 'Opção inválida.',
  enquete_nao_encontrada: 'Enquete não encontrada.',
};

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  mostrarMsg('');

  const cpf = cpfInput.value.replace(/\D/g, '');
  if (cpf.length !== 11) return mostrarMsg(ERROS.cpf_invalido, 'erro');
  if (!opcaoEscolhida) return mostrarMsg('Escolha uma opção antes de votar.', 'erro');

  const btn = document.getElementById('btn-votar');
  btn.disabled = true;
  btn.textContent = 'Enviando...';

  try {
    const resp = await fetch(`/enquetes/${enqueteId}/votos`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cpf, opcao_id: opcaoEscolhida }),
    });

    const dados = await resp.json();

    if (!resp.ok) {
      mostrarMsg(ERROS[dados.error] || 'Não foi possível registrar o voto.', 'erro');
      return;
    }

    jaVotou = true;
    mostrarMsg('Voto registrado! Obrigado.', 'ok');
    btn.textContent = 'Voto registrado';

    // O contador é assíncrono (SNS → SQS → worker): espera um instante
    setTimeout(carregar, 1200);
    setTimeout(() => { cardVoto.style.display = 'none'; }, 2500);
  } catch (err) {
    mostrarMsg('Falha de rede: ' + err.message, 'erro');
  } finally {
    if (!jaVotou) {
      btn.disabled = false;
      btn.textContent = 'Votar';
    }
  }
});

// Carrega e mantém atualizado (resultado ao vivo)
carregar().then((ok) => {
  if (!ok) return;
  setInterval(() => {
    if (!estaAberta()) return;
    carregar().catch(() => {});
  }, 3000);
});
