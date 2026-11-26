-- ---------------------------------------------------------------
-- Schema do sistema de enquetes
-- Executado automaticamente na primeira subida do container postgres
-- (docker-entrypoint-initdb.d)
-- ---------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS enquetes (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo        text        NOT NULL,
    descricao     text,
    status        text        NOT NULL DEFAULT 'aberta'
                              CHECK (status IN ('aberta', 'fechada')),
    abertura      timestamptz NOT NULL DEFAULT now(),
    prazo         timestamptz NOT NULL,
    criada_por    text,

    -- Enquete anônima: a tela de voto não pede nome.
    -- Enquete identificada: exige o nome do votante.
    anonima       boolean     NOT NULL DEFAULT true,

    -- Quantas opções cada pessoa pode marcar (1 = voto único, 2 = duas opções)
    max_escolhas  smallint    NOT NULL DEFAULT 1
                              CHECK (max_escolhas IN (1, 2)),

    CONSTRAINT titulo_nao_vazio CHECK (length(trim(titulo)) > 0)
);

CREATE TABLE IF NOT EXISTS opcoes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    enquete_id  uuid NOT NULL REFERENCES enquetes(id) ON DELETE CASCADE,
    rotulo      text NOT NULL,
    ordem       int  NOT NULL,
    CONSTRAINT rotulo_nao_vazio CHECK (length(trim(rotulo)) > 0),
    UNIQUE (enquete_id, ordem)
);

CREATE TABLE IF NOT EXISTS votos (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    enquete_id    uuid NOT NULL REFERENCES enquetes(id) ON DELETE CASCADE,
    opcao_id      uuid NOT NULL REFERENCES opcoes(id)   ON DELETE CASCADE,

    -- Identificador anônimo do votante (uuid gerado no navegador e guardado
    -- no localStorage). Substitui o CPF: permite limitar votos sem coletar
    -- dado pessoal. É "melhor esforço": limpar o navegador gera outro id.
    votante_id    uuid NOT NULL,

    -- Nome do votante: preenchido apenas em enquetes não anônimas.
    votante_nome  text,
    CONSTRAINT nome_tamanho CHECK (votante_nome IS NULL OR length(votante_nome) BETWEEN 2 AND 80),

    criado_em     timestamptz NOT NULL DEFAULT now(),

    -- Mesma pessoa não vota duas vezes na MESMA opção.
    -- Para max_escolhas = 2, ela pode ter no máximo duas linhas (uma por opção),
    -- o que é validado também na aplicação (dentro de uma transação).
    CONSTRAINT um_voto_por_opcao UNIQUE (enquete_id, votante_id, opcao_id)
);

-- Índices para leitura de resultado, dedupe e listagem
CREATE INDEX IF NOT EXISTS idx_votos_enquete     ON votos (enquete_id);
CREATE INDEX IF NOT EXISTS idx_votos_opcao       ON votos (opcao_id);
CREATE INDEX IF NOT EXISTS idx_votos_votante     ON votos (enquete_id, votante_id);
CREATE INDEX IF NOT EXISTS idx_enquetes_status   ON enquetes (status, prazo);
CREATE INDEX IF NOT EXISTS idx_opcoes_enquete    ON opcoes (enquete_id, ordem);
