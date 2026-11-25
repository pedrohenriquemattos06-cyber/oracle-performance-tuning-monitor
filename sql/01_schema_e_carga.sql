-- =============================================================================
-- 01_schema_e_carga.sql
-- Projeto  : Oracle Performance Tuning & Health Monitor
-- Objetivo : Criar um cenario realista de ERP com volumetria alta e, de
--            proposito, COM GARGALOS: sem indices nas chaves estrangeiras e nas
--            colunas de filtro, e com estatisticas desatualizadas/travadas.
-- Volumes  : ERP_CLIENTES 100.000 | ERP_PRODUTOS 50.000
--            ERP_PEDIDOS 1.000.000 | ERP_ITENS_PEDIDO 2.500.000
-- Tecnicas : FORALL (clientes) e INSERT /*+ APPEND */ (demais tabelas)
-- Execucao : automatica no primeiro start do container (ou manual como ERP_DBA)
-- =============================================================================
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET TIMING ON
SET FEEDBACK ON
SET LINESIZE 200

PROMPT >>> [1/8] Removendo objetos de execucoes anteriores...
BEGIN
  FOR t IN (SELECT column_value AS nome
              FROM TABLE(sys.odcivarchar2list('ERP_ITENS_PEDIDO', 'ERP_PEDIDOS', 'ERP_PRODUTOS',
                                              'ERP_CLIENTES', 'DBA_BENCHMARK_LOGS', 'DBA_HEALTH_ALERTS'))) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE ' || t.nome || ' CASCADE CONSTRAINTS PURGE';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE <> -942 THEN
          RAISE;
        END IF;
    END;
  END LOOP;
END;
/

PROMPT >>> [2/8] Criando tabelas (sem PK/FK/indices ainda, para a carga ser rapida)...
CREATE TABLE erp_clientes (
  cli_id          NUMBER(10)    NOT NULL,
  cli_nome        VARCHAR2(100) NOT NULL,
  cli_cnpj        VARCHAR2(18),
  cli_regiao      VARCHAR2(2)   NOT NULL,
  cli_uf          CHAR(2)       NOT NULL,
  cli_segmento    VARCHAR2(20),
  cli_ativo       CHAR(1)       DEFAULT 'S' NOT NULL,
  cli_dt_cadastro DATE          DEFAULT SYSDATE NOT NULL
);

CREATE TABLE erp_produtos (
  prd_id             NUMBER(10)    NOT NULL,
  prd_codigo         VARCHAR2(20)  NOT NULL,
  prd_descricao      VARCHAR2(120) NOT NULL,
  prd_categoria      VARCHAR2(30)  NOT NULL,
  prd_preco          NUMBER(12,2)  NOT NULL,
  prd_estoque_atual  NUMBER(12)    NOT NULL,
  prd_estoque_minimo NUMBER(12)    NOT NULL,
  prd_ativo          CHAR(1)       DEFAULT 'S' NOT NULL
);

CREATE TABLE erp_pedidos (
  ped_id              NUMBER(12)   NOT NULL,
  cli_id              NUMBER(10)   NOT NULL,
  ped_data            DATE         NOT NULL,   -- possui componente de hora (importante para SARGability)
  ped_status          VARCHAR2(12) NOT NULL,
  ped_valor_total     NUMBER(14,2) NOT NULL,
  ped_dt_entrega_prev DATE,
  ped_obs             VARCHAR2(100)
);

CREATE TABLE erp_itens_pedido (
  itm_id           NUMBER(12)   NOT NULL,
  ped_id           NUMBER(12)   NOT NULL,
  prd_id           NUMBER(10)   NOT NULL,
  itm_qtd          NUMBER(10)   NOT NULL,
  itm_preco_unit   NUMBER(12,2) NOT NULL,
  itm_qtd_entregue NUMBER(10)   DEFAULT 0 NOT NULL,
  itm_desconto     NUMBER(5,2)  DEFAULT 0 NOT NULL
);

CREATE TABLE dba_benchmark_logs (
  log_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id        VARCHAR2(36)  NOT NULL,
  query_name    VARCHAR2(40)  NOT NULL,
  fase          VARCHAR2(10)  NOT NULL CHECK (fase IN ('ANTES', 'DEPOIS')),
  elapsed_ms    NUMBER(14,2),
  cpu_ms        NUMBER(14,2),
  logical_reads NUMBER,
  physical_reads NUMBER,
  rows_fetched  NUMBER,
  dt_execucao   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
  obs           VARCHAR2(400)
);

CREATE TABLE dba_health_alerts (
  alert_id   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dt_alerta  TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
  severidade VARCHAR2(10)   NOT NULL CHECK (severidade IN ('INFO', 'WARNING', 'CRITICAL')),
  categoria  VARCHAR2(30)   NOT NULL,
  mensagem   VARCHAR2(1000) NOT NULL,
  detalhes   VARCHAR2(4000)
);

PROMPT >>> [3/8] Carregando ERP_CLIENTES (100.000) com BULK / FORALL em lotes de 10.000...
DECLARE
  c_total CONSTANT PLS_INTEGER := 100000;
  c_lote  CONSTANT PLS_INTEGER := 10000;

  TYPE t_ids   IS TABLE OF NUMBER        INDEX BY PLS_INTEGER;
  TYPE t_nomes IS TABLE OF VARCHAR2(100) INDEX BY PLS_INTEGER;
  TYPE t_cnpjs IS TABLE OF VARCHAR2(18)  INDEX BY PLS_INTEGER;
  TYPE t_regs  IS TABLE OF VARCHAR2(2)   INDEX BY PLS_INTEGER;
  TYPE t_segs  IS TABLE OF VARCHAR2(20)  INDEX BY PLS_INTEGER;
  TYPE t_ativ  IS TABLE OF VARCHAR2(1)   INDEX BY PLS_INTEGER;
  TYPE t_dts   IS TABLE OF DATE          INDEX BY PLS_INTEGER;

  v_ids   t_ids;
  v_nomes t_nomes;
  v_cnpjs t_cnpjs;
  v_regs  t_regs;
  v_ufs   t_regs;
  v_segs  t_segs;
  v_ativ  t_ativ;
  v_dts   t_dts;

  -- UF e regiao correspondentes (mais peso em SE e S, como num ERP de industria do Sul/Sudeste)
  r_ufs  CONSTANT sys.odcivarchar2list := sys.odcivarchar2list('AM','PA','BA','PE','CE','GO','MT','SP','RJ','MG','PR','SC','RS');
  r_regs CONSTANT sys.odcivarchar2list := sys.odcivarchar2list('N','N','NE','NE','NE','CO','CO','SE','SE','SE','S','S','S');
  r_segs CONSTANT sys.odcivarchar2list := sys.odcivarchar2list('VAREJO','ATACADO','INDUSTRIA','SERVICOS');
  v_idx  PLS_INTEGER;
BEGIN
  FOR lote IN 0 .. (c_total / c_lote) - 1 LOOP
    FOR i IN 1 .. c_lote LOOP
      v_idx      := TRUNC(DBMS_RANDOM.VALUE(1, 14));
      v_ids(i)   := lote * c_lote + i;
      v_nomes(i) := 'CLIENTE ' || LPAD(v_ids(i), 6, '0') || ' ' || DBMS_RANDOM.STRING('U', 10);
      v_cnpjs(i) := LPAD(TRUNC(DBMS_RANDOM.VALUE(1, 99999999999999)), 14, '0');
      v_ufs(i)   := r_ufs(v_idx);
      v_regs(i)  := r_regs(v_idx);
      v_segs(i)  := r_segs(TRUNC(DBMS_RANDOM.VALUE(1, 5)));
      v_ativ(i)  := CASE WHEN DBMS_RANDOM.VALUE < 0.90 THEN 'S' ELSE 'N' END;
      v_dts(i)   := DATE '2018-01-01' + TRUNC(DBMS_RANDOM.VALUE(0, 2000));
    END LOOP;

    FORALL i IN 1 .. c_lote
      INSERT INTO erp_clientes (cli_id, cli_nome, cli_cnpj, cli_regiao, cli_uf, cli_segmento, cli_ativo, cli_dt_cadastro)
      VALUES (v_ids(i), v_nomes(i), v_cnpjs(i), v_regs(i), v_ufs(i), v_segs(i), v_ativ(i), v_dts(i));
    COMMIT;
  END LOOP;
END;
/

PROMPT >>> [4/8] Carregando ERP_PRODUTOS (50.000) com INSERT APPEND...
INSERT /*+ APPEND */ INTO erp_produtos
  (prd_id, prd_codigo, prd_descricao, prd_categoria, prd_preco, prd_estoque_atual, prd_estoque_minimo, prd_ativo)
SELECT n,
       'PRD' || LPAD(n, 6, '0'),
       'PRODUTO ' || LPAD(n, 6, '0') || ' ' || DBMS_RANDOM.STRING('U', 12),
       CASE MOD(n, 6) WHEN 0 THEN 'ALIMENTOS' WHEN 1 THEN 'BEBIDAS' WHEN 2 THEN 'LIMPEZA'
                      WHEN 3 THEN 'HIGIENE'   WHEN 4 THEN 'EMBALAGENS' ELSE 'DIVERSOS' END,
       ROUND(DBMS_RANDOM.VALUE(5, 500), 2),
       TRUNC(DBMS_RANDOM.VALUE(0, 15)),
       TRUNC(DBMS_RANDOM.VALUE(5, 40)),
       CASE WHEN DBMS_RANDOM.VALUE < 0.95 THEN 'S' ELSE 'N' END
  FROM (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 50000);
COMMIT;

PROMPT >>> [5/8] Carregando ERP_PEDIDOS (1.000.000) com INSERT APPEND...
-- Distribuicao de status: 5% CANCELADO, 8% ABERTO, 12% FATURADO, 75% ENTREGUE
-- Datas entre 2023-01-01 e 2025-12-31 (com hora). O ROWNUM na view interna impede o
-- "merge" da view e garante que cada coluna aleatoria seja calculada uma unica vez por linha.
INSERT /*+ APPEND */ INTO erp_pedidos
  (ped_id, cli_id, ped_data, ped_status, ped_valor_total, ped_dt_entrega_prev, ped_obs)
SELECT v.n,
       v.cli,
       v.dt,
       CASE WHEN v.r < 0.05 THEN 'CANCELADO'
            WHEN v.r < 0.13 THEN 'ABERTO'
            WHEN v.r < 0.25 THEN 'FATURADO'
            ELSE 'ENTREGUE' END,
       v.valor,
       v.dt + TRUNC(DBMS_RANDOM.VALUE(3, 30)),
       'OBS ' || v.obs
  FROM (SELECT g.n,
               ROWNUM                                              AS rn,
               TRUNC(DBMS_RANDOM.VALUE(1, 100001))                 AS cli,
               DATE '2023-01-01' + DBMS_RANDOM.VALUE(0, 1095.999)  AS dt,
               DBMS_RANDOM.VALUE                                   AS r,
               ROUND(DBMS_RANDOM.VALUE(50, 20000), 2)              AS valor,
               DBMS_RANDOM.STRING('X', 40)                         AS obs
          FROM (SELECT (a.n - 1) * 1000 + b.n AS n
                  FROM (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000) a
                 CROSS JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000) b) g) v;
COMMIT;

PROMPT >>> [6/8] Carregando ERP_ITENS_PEDIDO (2.500.000) com INSERT APPEND...
-- ~85% dos itens totalmente entregues; ~15% com entrega parcial/zero (itens pendentes).
INSERT /*+ APPEND */ INTO erp_itens_pedido
  (itm_id, ped_id, prd_id, itm_qtd, itm_preco_unit, itm_qtd_entregue, itm_desconto)
SELECT v.n,
       v.ped,
       v.prd,
       v.qtd,
       v.preco,
       CASE WHEN v.r < 0.85 THEN v.qtd ELSE TRUNC(DBMS_RANDOM.VALUE(0, v.qtd)) END,
       ROUND(DBMS_RANDOM.VALUE(0, 15), 2)
  FROM (SELECT g.n,
               ROWNUM                                  AS rn,
               TRUNC(DBMS_RANDOM.VALUE(1, 1000001))    AS ped,
               TRUNC(DBMS_RANDOM.VALUE(1, 50001))      AS prd,
               TRUNC(DBMS_RANDOM.VALUE(1, 11))         AS qtd,
               ROUND(DBMS_RANDOM.VALUE(5, 500), 2)     AS preco,
               DBMS_RANDOM.VALUE                       AS r
          FROM (SELECT (a.n - 1) * 2500 + b.n AS n
                  FROM (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 1000) a
                 CROSS JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 2500) b) g) v;
COMMIT;

PROMPT >>> [7/8] Criando PKs e FKs (FKs SEM indices de apoio e NOVALIDATE: gargalo proposital)...
ALTER TABLE erp_clientes     ADD CONSTRAINT pk_erp_clientes     PRIMARY KEY (cli_id);
ALTER TABLE erp_produtos     ADD CONSTRAINT pk_erp_produtos     PRIMARY KEY (prd_id);
ALTER TABLE erp_pedidos      ADD CONSTRAINT pk_erp_pedidos      PRIMARY KEY (ped_id);
ALTER TABLE erp_itens_pedido ADD CONSTRAINT pk_erp_itens_pedido PRIMARY KEY (itm_id);

ALTER TABLE erp_pedidos      ADD CONSTRAINT fk_ped_cli FOREIGN KEY (cli_id) REFERENCES erp_clientes (cli_id) ENABLE NOVALIDATE;
ALTER TABLE erp_itens_pedido ADD CONSTRAINT fk_itm_ped FOREIGN KEY (ped_id) REFERENCES erp_pedidos (ped_id) ENABLE NOVALIDATE;
ALTER TABLE erp_itens_pedido ADD CONSTRAINT fk_itm_prd FOREIGN KEY (prd_id) REFERENCES erp_produtos (prd_id) ENABLE NOVALIDATE;

PROMPT >>> [8/8] Simulando estatisticas desatualizadas: coleta, distorce (10% da volumetria real) e TRAVA...
DECLARE
  v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  v_tabs  sys.odcivarchar2list := sys.odcivarchar2list('ERP_CLIENTES', 'ERP_PRODUTOS', 'ERP_PEDIDOS', 'ERP_ITENS_PEDIDO');
  v_rows  sys.odcinumberlist   := sys.odcinumberlist(10000, 5000, 100000, 250000);
BEGIN
  FOR i IN 1 .. v_tabs.COUNT LOOP
    DBMS_STATS.GATHER_TABLE_STATS(ownname          => v_owner,
                                  tabname          => v_tabs(i),
                                  estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                  method_opt       => 'FOR ALL COLUMNS SIZE 1',
                                  cascade          => TRUE);
    DBMS_STATS.SET_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i), numrows => v_rows(i));
    DBMS_STATS.LOCK_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i));
  END LOOP;
END;
/

PROMPT >>> Conferindo volumetria:
SELECT 'ERP_CLIENTES' AS tabela, COUNT(*) AS registros FROM erp_clientes
UNION ALL SELECT 'ERP_PRODUTOS',     COUNT(*) FROM erp_produtos
UNION ALL SELECT 'ERP_PEDIDOS',      COUNT(*) FROM erp_pedidos
UNION ALL SELECT 'ERP_ITENS_PEDIDO', COUNT(*) FROM erp_itens_pedido;

PROMPT >>> 01_schema_e_carga.sql concluido com sucesso.
