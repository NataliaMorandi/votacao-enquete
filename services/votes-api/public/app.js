'use strict';

/* ------------------------------------------------------------------
 * Página inicial: criar enquete + listar enquetes
 * ------------------------------------------------------------------ */

const listaOpcoes = document.getElementById('lista-opcoes');
const btnAdd = document.getElementById('add-opcao');
const form = document.getElementById('form-nova');
const msg = document.getElementById('msg');
const lista = document.getElementById('lista');
const atualizado = document.getElementById('atualizado');

function adicionarOpcao(valor = '') {
  if (listaOpcoes.children.length >= 10) return;
  const linha = document.createElement('div');
  linha.className = 'opcao-linha';

  const input = document.createElement('input');
  input.type = 'text';
  input.maxLength = 80;
  input.placeholder = `Opção ${listaOpcoes.children.length + 1}`;
  input.value = valor;

  const remover = document.createElement('button');
  remover.type = 'button';
  remover.className = 'btn-ghost';
  remover.textContent = '×';
  remover.title = 'Remover opção';
  remover.addEventListener('click', () => {
    if (listaOpcoes.children.length <= 2) {
      mostrarMsg('São necessárias pelo menos 2 opções.', 'erro');
      return;
    }
    linha.remove();
  });

  linha.append(input, remover);
  listaOpcoes.append(linha);
}

function mostrarMsg(texto, tipo) {
  msg.textContent = texto;
  msg.className = 'msg' + (tipo ? ' ' + tipo : '');
}

function opcoesPreenchidas() {
  return [...listaOpcoes.querySelectorAll('input')]
    .map((i) => i.value.trim())
    .filter(Boolean);
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  mostrarMsg('');

  const titulo = document.getElementById('titulo').value.trim();
  const descricao = document.getElementById('descricao').value.trim();
  const duracao_minutos = Number(document.getElementById('duracao').value);
  const opcoes = opcoesPreenchidas();
  const anonima = document.getElementById('anonima').checked;
  const max_escolhas = document.getElementById('duas-opcoes').checked ? 2 : 1;

  if (titulo.length < 3) return mostrarMsg('O título precisa ter pelo menos 3 caracteres.', 'erro');
  if (opcoes.length < 2) return mostrarMsg('Informe pelo menos 2 opções.', 'erro');
  if (max_escolhas === 2 && opcoes.length < 2) {
    return mostrarMsg('Para permitir duas escolhas, cadastre pelo menos 2 opções.', 'erro');
  }

  const btn = document.getElementById('btn-criar');
  btn.disabled = true;
  btn.textContent = 'Criando...';

  try {
    const resp = await fetch('/enquetes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        titulo,
        descricao: descricao || null,
        duracao_minutos,
        opcoes,
        anonima,
        max_escolhas,
      }),
    });

    const dados = await resp.json();

    if (!resp.ok) {
      mostrarMsg(mensagemErro(dados), 'erro');
      return;
    }

    mostrarMsg('Enquete criada! Abrindo...', 'ok');
    window.location.href = `/e/${dados.id}`;
  } catch (err) {
    mostrarMsg('Falha de rede: ' + err.message, 'erro');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Criar enquete';
  }
});

btnAdd.addEventListener('click', () => adicionarOpcao());

function mensagemErro(dados) {
  const mapa = {
    titulo_invalido: 'Título inválido (mínimo 3 caracteres).',
    opcoes_invalidas: 'Informe de 2 a 10 opções não vazias.',
    duracao_invalida: 'Duração inválida.',
  };
  return mapa[dados && dados.error] || 'Erro ao criar a enquete.';
}

function tempoRestante(prazo) {
  const ms = new Date(prazo).getTime() - Date.now();
  if (ms <= 0) return 'encerrada';
  const min = Math.floor(ms / 60000);
  if (min < 1) return 'menos de 1 min';
  if (min < 60) return `faltam ${min} min`;
  const h = Math.floor(min / 60);
  const resto = min % 60;
  return `faltam ${h}h${resto ? resto + 'min' : ''}`;
}

function escapar(texto) {
  const div = document.createElement('div');
  div.textContent = texto == null ? '' : String(texto);
  return div.innerHTML;
}

async function carregarLista() {
  try {
    const resp = await fetch('/enquetes');
    const dados = await resp.json();
    const enquetes = dados.enquetes || [];

    if (enquetes.length === 0) {
      lista.innerHTML = '<p class="rodape">Nenhuma enquete ainda. Crie a primeira acima.</p>';
      return;
    }

    lista.innerHTML = enquetes
      .map((e) => {
        const fechada = e.status !== 'aberta' || new Date(e.prazo) <= new Date();
        const modo = e.anonima ? 'anônima' : 'com nome';
        const escolhas = e.max_escolhas === 2 ? '2 opções' : '1 opção';
        return `
          <a class="enquete-item" href="/e/${e.id}">
            <div class="titulo">${escapar(e.titulo)}</div>
            <div class="meta">
              <span class="badge ${fechada ? 'fechada' : 'aberta'}">${fechada ? 'encerrada' : 'aberta'}</span>
              <span>${e.total_votos} voto${e.total_votos === 1 ? '' : 's'}</span>
              <span>${modo} · ${escolhas}</span>
              <span>${fechada ? 'encerrada' : tempoRestante(e.prazo)}</span>
            </div>
          </a>`;
      })
      .join('');

    atualizado.textContent = '· atualizado ' + new Date().toLocaleTimeString('pt-BR');
  } catch (err) {
    lista.innerHTML = `<p class="msg erro">Não foi possível carregar as enquetes: ${escapar(err.message)}</p>`;
  }
}

adicionarOpcao();
adicionarOpcao();
carregarLista();
setInterval(carregarLista, 10000);
