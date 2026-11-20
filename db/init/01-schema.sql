-- ---------------------------------------------------------------
-- Schema do sistema de enquetes
-- Executado automaticamente na primeira subida do container postgres
-- (docker-entrypoint-initdb.d)
-- ---------------------------------------------------------------

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS enquetes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo      text        NOT NULL,
    descricao   text,
    status      text        NOT NULL DEFAULT 'aberta'
                            CHECK (status IN ('aberta', 'fechada')),
    abertura    timestamptz NOT NULL DEFAULT now(),
    prazo       timestamptz NOT NULL,
    criada_por  text,
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
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    enquete_id  uuid NOT NULL REFERENCES enquetes(id) ON DELETE CASCADE,
    opcao_id    uuid NOT NULL REFERENCES opcoes(id)   ON DELETE CASCADE,
    cpf         text NOT NULL,
    criado_em   timestamptz NOT NULL DEFAULT now(),
    -- Regra de negócio: 1 CPF = 1 voto por enquete
    -- (garantida pelo banco, não só pelo código)
    CONSTRAINT um_voto_por_cpf UNIQUE (enquete_id, cpf)
);

-- Índices para leitura de resultado e listagem
CREATE INDEX IF NOT EXISTS idx_votos_enquete     ON votos (enquete_id);
CREATE INDEX IF NOT EXISTS idx_votos_opcao       ON votos (opcao_id);
CREATE INDEX IF NOT EXISTS idx_enquetes_status   ON enquetes (status, prazo);
CREATE INDEX IF NOT EXISTS idx_opcoes_enquete    ON opcoes (enquete_id, ordem);
