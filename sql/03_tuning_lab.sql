-- =============================================================================
-- 03_tuning_lab.sql  -  LABORATORIO DE TUNING: O "ANTES E DEPOIS"
-- Projeto : Oracle Performance Tuning & Health Monitor
--
-- Tres consultas criticas de negocio, cada uma em duas versoes:
--   Q1 - Faturamento por cliente/regiao (marco/2025)
--   Q2 - Pedidos com itens pendentes de entrega (novembro/2025)
--   Q3 - Cruzamento estoque x demanda pendente de pedidos (4o trimestre/2025)
--
-- USO AUTOMATIZADO : benchmark_runner.py le os blocos delimitados por
--                    "-- @BEGIN <NOME>" ... "-- @END". Dentro de RESET e TUNING,
--                    cada comando termina com uma linha contendo apenas "/".
-- USO MANUAL       : sqlplus erp_dba/ErpDba_2025@//localhost:1521/FREEPDB1 @03_tuning_lab.sql
--                    (ou rode os passos separadamente no SQL Developer / SQLcl)
-- =============================================================================
SET DEFINE OFF
SET SQLBLANKLINES ON
SET LINESIZE 220
SET PAGESIZE 200
SET TRIMSPOOL ON
SET TIMING ON
SET SERVEROUTPUT ON SIZE UNLIMITED
WHENEVER SQLERROR CONTINUE

-- =============================================================================
-- PASSO 0 - RESET: volta ao estado "sem tuning" (remove indices do laboratorio e
--           restaura estatisticas desatualizadas e TRAVADAS). Idempotente.
-- =============================================================================
-- @BEGIN RESET
DECLARE
  v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  v_idx   sys.odcivarchar2list := sys.odcivarchar2list('IDX_PED_DATA_STATUS_COV', 'IDX_PED_CLI_DATA',
                                                       'IDX_ITM_PED_COV', 'IDX_ITM_PRD', 'IDX_CLI_REGIAO_ATIVO');
  v_tabs  sys.odcivarchar2list := sys.odcivarchar2list('ERP_CLIENTES', 'ERP_PRODUTOS', 'ERP_PEDIDOS', 'ERP_ITENS_PEDIDO');
  v_rows  sys.odcinumberlist   := sys.odcinumberlist(10000, 5000, 100000, 250000);
BEGIN
  FOR i IN 1 .. v_idx.COUNT LOOP
    BEGIN
      EXECUTE IMMEDIATE 'DROP INDEX ' || v_idx(i);
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE <> -1418 THEN   -- ORA-01418: indice inexistente
          RAISE;
        END IF;
    END;
  END LOOP;

  FOR i IN 1 .. v_tabs.COUNT LOOP
    DBMS_STATS.UNLOCK_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i));
    DBMS_STATS.SET_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i), numrows => v_rows(i));
    DBMS_STATS.LOCK_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i));
  END LOOP;
END;
/
-- @END

-- =============================================================================
-- PASSO 1 - PLANOS DE EXECUCAO "ANTES" (EXPLAIN PLAN + DBMS_XPLAN.DISPLAY)
-- Observe: TABLE ACCESS FULL, filtros por TRUNC(...) so como "filter", cardinalidades
-- erradas (estatisticas desatualizadas) e ausencia de INDEX RANGE SCAN.
-- =============================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q1_ANTES' FOR
SELECT c.cli_regiao, c.cli_id, c.cli_nome,
       COUNT(p.ped_id)        AS qtd_pedidos,
       SUM(p.ped_valor_total) AS faturamento
FROM   erp_pedidos p,
       erp_clientes c
WHERE  p.cli_id = c.cli_id
AND    TRUNC(p.ped_data) BETWEEN DATE '2025-03-01' AND DATE '2025-03-31'
AND    p.ped_status IN ('FATURADO', 'ENTREGUE')
AND    p.cli_id IN (SELECT c2.cli_id
                    FROM   erp_clientes c2
                    WHERE  c2.cli_ativo = 'S'
                    AND    c2.cli_regiao IN ('SE', 'S'))
GROUP BY c.cli_regiao, c.cli_id, c.cli_nome
ORDER BY faturamento DESC, c.cli_id
FETCH FIRST 100 ROWS ONLY;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q1_ANTES', 'TYPICAL'));

EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q2_ANTES' FOR
SELECT *
FROM   erp_pedidos p,
       erp_clientes c
WHERE  p.cli_id = c.cli_id
AND    p.ped_status IN ('ABERTO', 'FATURADO')
AND    TRUNC(p.ped_data) BETWEEN DATE '2025-11-01' AND DATE '2025-11-30'
AND    p.ped_id IN (SELECT i.ped_id
                    FROM   erp_itens_pedido i
                    WHERE  i.itm_qtd_entregue < i.itm_qtd)
ORDER BY p.ped_data, p.ped_id;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q2_ANTES', 'TYPICAL'));

EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q3_ANTES' FOR
SELECT *
FROM  (SELECT pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo,
              SUM(i.itm_qtd - i.itm_qtd_entregue) AS demanda_pendente
       FROM   erp_produtos pr,
              erp_itens_pedido i
       WHERE  i.prd_id = pr.prd_id
       AND    pr.prd_ativo = 'S'
       AND    i.itm_qtd_entregue < i.itm_qtd
       AND    i.ped_id IN (SELECT p.ped_id
                           FROM   erp_pedidos p
                           WHERE  p.ped_status IN ('ABERTO', 'FATURADO')
                           AND    TRUNC(p.ped_data) >= DATE '2025-10-01')
       GROUP BY pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo) v
WHERE  v.demanda_pendente > v.prd_estoque_atual
ORDER BY v.demanda_pendente - v.prd_estoque_atual DESC, v.prd_id
FETCH FIRST 500 ROWS ONLY;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q3_ANTES', 'TYPICAL'));

-- =============================================================================
-- PASSO 2 - EXECUCAO DAS VERSOES LENTAS ("ANTES")
-- Anti-padroes: funcao na coluna filtrada (TRUNC), IN com subquery redundante/ampla,
-- SELECT * trazendo colunas desnecessarias, joins por virgula e sem indices de apoio.
-- Para medir no SQL*Plus sem imprimir milhares de linhas: SET AUTOTRACE TRACEONLY STATISTICS
-- =============================================================================
SET AUTOTRACE TRACEONLY STATISTICS

-- @BEGIN Q1_ANTES
SELECT c.cli_regiao, c.cli_id, c.cli_nome,
       COUNT(p.ped_id)        AS qtd_pedidos,
       SUM(p.ped_valor_total) AS faturamento
FROM   erp_pedidos p,
       erp_clientes c
WHERE  p.cli_id = c.cli_id
AND    TRUNC(p.ped_data) BETWEEN DATE '2025-03-01' AND DATE '2025-03-31'
AND    p.ped_status IN ('FATURADO', 'ENTREGUE')
AND    p.cli_id IN (SELECT c2.cli_id
                    FROM   erp_clientes c2
                    WHERE  c2.cli_ativo = 'S'
                    AND    c2.cli_regiao IN ('SE', 'S'))
GROUP BY c.cli_regiao, c.cli_id, c.cli_nome
ORDER BY faturamento DESC, c.cli_id
FETCH FIRST 100 ROWS ONLY;
-- @END

-- @BEGIN Q2_ANTES
SELECT *
FROM   erp_pedidos p,
       erp_clientes c
WHERE  p.cli_id = c.cli_id
AND    p.ped_status IN ('ABERTO', 'FATURADO')
AND    TRUNC(p.ped_data) BETWEEN DATE '2025-11-01' AND DATE '2025-11-30'
AND    p.ped_id IN (SELECT i.ped_id
                    FROM   erp_itens_pedido i
                    WHERE  i.itm_qtd_entregue < i.itm_qtd)
ORDER BY p.ped_data, p.ped_id;
-- @END

-- @BEGIN Q3_ANTES
SELECT *
FROM  (SELECT pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo,
              SUM(i.itm_qtd - i.itm_qtd_entregue) AS demanda_pendente
       FROM   erp_produtos pr,
              erp_itens_pedido i
       WHERE  i.prd_id = pr.prd_id
       AND    pr.prd_ativo = 'S'
       AND    i.itm_qtd_entregue < i.itm_qtd
       AND    i.ped_id IN (SELECT p.ped_id
                           FROM   erp_pedidos p
                           WHERE  p.ped_status IN ('ABERTO', 'FATURADO')
                           AND    TRUNC(p.ped_data) >= DATE '2025-10-01')
       GROUP BY pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo) v
WHERE  v.demanda_pendente > v.prd_estoque_atual
ORDER BY v.demanda_pendente - v.prd_estoque_atual DESC, v.prd_id
FETCH FIRST 500 ROWS ONLY;
-- @END

SET AUTOTRACE OFF

-- =============================================================================
-- PASSO 3 - TUNING: indices compostos estrategicos + estatisticas (DBMS_STATS)
--   IDX_PED_DATA_STATUS_COV : filtro por data (range) + status; "covering" para Q1/Q2/Q3
--   IDX_PED_CLI_DATA        : indice da FK ERP_PEDIDOS.CLI_ID (join/consultas por cliente)
--   IDX_ITM_PED_COV         : FK ERP_ITENS_PEDIDO.PED_ID + colunas de quantidade (EXISTS sem ir a tabela)
--   IDX_ITM_PRD             : FK ERP_ITENS_PEDIDO.PRD_ID
--   IDX_CLI_REGIAO_ATIVO    : filtros de regiao/ativo em clientes
-- =============================================================================
-- @BEGIN TUNING
CREATE INDEX idx_ped_data_status_cov ON erp_pedidos (ped_data, ped_status, ped_id, cli_id, ped_valor_total)
/
CREATE INDEX idx_ped_cli_data ON erp_pedidos (cli_id, ped_data)
/
CREATE INDEX idx_itm_ped_cov ON erp_itens_pedido (ped_id, prd_id, itm_qtd, itm_qtd_entregue)
/
CREATE INDEX idx_itm_prd ON erp_itens_pedido (prd_id)
/
CREATE INDEX idx_cli_regiao_ativo ON erp_clientes (cli_regiao, cli_ativo)
/
DECLARE
  v_owner VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  v_tabs  sys.odcivarchar2list := sys.odcivarchar2list('ERP_CLIENTES', 'ERP_PRODUTOS', 'ERP_PEDIDOS', 'ERP_ITENS_PEDIDO');
BEGIN
  FOR i IN 1 .. v_tabs.COUNT LOOP
    DBMS_STATS.UNLOCK_TABLE_STATS(ownname => v_owner, tabname => v_tabs(i));
    DBMS_STATS.GATHER_TABLE_STATS(ownname          => v_owner,
                                  tabname          => v_tabs(i),
                                  estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
                                  method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
                                  cascade          => TRUE);
  END LOOP;
END;
/
-- @END

-- =============================================================================
-- PASSO 4 - PLANOS DE EXECUCAO 
-- Observe: INDEX RANGE SCAN nos indices novos, ausencia de funcao na coluna de data,
-- SEMI JOIN para EXISTS e cardinalidades proximas do real (estatisticas atualizadas).
-- =============================================================================
EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q1_DEPOIS' FOR
SELECT c.cli_regiao, c.cli_id, c.cli_nome,
       COUNT(p.ped_id)        AS qtd_pedidos,
       SUM(p.ped_valor_total) AS faturamento
FROM   erp_clientes c
JOIN   erp_pedidos  p ON p.cli_id = c.cli_id
WHERE  c.cli_ativo = 'S'
AND    c.cli_regiao IN ('SE', 'S')
AND    p.ped_data >= DATE '2025-03-01'
AND    p.ped_data <  DATE '2025-04-01'
AND    p.ped_status IN ('FATURADO', 'ENTREGUE')
GROUP BY c.cli_regiao, c.cli_id, c.cli_nome
ORDER BY faturamento DESC, c.cli_id
FETCH FIRST 100 ROWS ONLY;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q1_DEPOIS', 'TYPICAL'));

EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q2_DEPOIS' FOR
SELECT p.ped_id, p.ped_data, p.ped_status, p.ped_valor_total, p.ped_dt_entrega_prev,
       c.cli_id, c.cli_nome, c.cli_uf
FROM   erp_pedidos p
JOIN   erp_clientes c ON c.cli_id = p.cli_id
WHERE  p.ped_status IN ('ABERTO', 'FATURADO')
AND    p.ped_data >= DATE '2025-11-01'
AND    p.ped_data <  DATE '2025-12-01'
AND    EXISTS (SELECT 1
               FROM   erp_itens_pedido i
               WHERE  i.ped_id = p.ped_id
               AND    i.itm_qtd_entregue < i.itm_qtd)
ORDER BY p.ped_data, p.ped_id;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q2_DEPOIS', 'TYPICAL'));

EXPLAIN PLAN SET STATEMENT_ID = 'LAB_Q3_DEPOIS' FOR
SELECT pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo,
       SUM(i.itm_qtd - i.itm_qtd_entregue)                          AS demanda_pendente,
       SUM(i.itm_qtd - i.itm_qtd_entregue) - pr.prd_estoque_atual   AS deficit
FROM   erp_produtos pr
JOIN   erp_itens_pedido i ON i.prd_id = pr.prd_id
WHERE  pr.prd_ativo = 'S'
AND    i.itm_qtd_entregue < i.itm_qtd
AND    EXISTS (SELECT 1
               FROM   erp_pedidos p
               WHERE  p.ped_id = i.ped_id
               AND    p.ped_status IN ('ABERTO', 'FATURADO')
               AND    p.ped_data >= DATE '2025-10-01')
GROUP BY pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo
HAVING SUM(i.itm_qtd - i.itm_qtd_entregue) > pr.prd_estoque_atual
ORDER BY deficit DESC, pr.prd_id
FETCH FIRST 500 ROWS ONLY;
SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', 'LAB_Q3_DEPOIS', 'TYPICAL'));

-- =============================================================================
-- PASSO 5 - EXECUCAO DAS VERSOES OTIMIZADAS 
-- Tecnicas: filtros SARGable (intervalo de data sem funcao na coluna), EXISTS,
-- projecao apenas das colunas necessarias, JOIN ANSI e indices compostos.
-- =============================================================================
SET AUTOTRACE TRACEONLY STATISTICS

-- @BEGIN Q1_DEPOIS
SELECT c.cli_regiao, c.cli_id, c.cli_nome,
       COUNT(p.ped_id)        AS qtd_pedidos,
       SUM(p.ped_valor_total) AS faturamento
FROM   erp_clientes c
JOIN   erp_pedidos  p ON p.cli_id = c.cli_id
WHERE  c.cli_ativo = 'S'
AND    c.cli_regiao IN ('SE', 'S')
AND    p.ped_data >= DATE '2025-03-01'
AND    p.ped_data <  DATE '2025-04-01'
AND    p.ped_status IN ('FATURADO', 'ENTREGUE')
GROUP BY c.cli_regiao, c.cli_id, c.cli_nome
ORDER BY faturamento DESC, c.cli_id
FETCH FIRST 100 ROWS ONLY;
-- @END

-- @BEGIN Q2_DEPOIS
SELECT p.ped_id, p.ped_data, p.ped_status, p.ped_valor_total, p.ped_dt_entrega_prev,
       c.cli_id, c.cli_nome, c.cli_uf
FROM   erp_pedidos p
JOIN   erp_clientes c ON c.cli_id = p.cli_id
WHERE  p.ped_status IN ('ABERTO', 'FATURADO')
AND    p.ped_data >= DATE '2025-11-01'
AND    p.ped_data <  DATE '2025-12-01'
AND    EXISTS (SELECT 1
               FROM   erp_itens_pedido i
               WHERE  i.ped_id = p.ped_id
               AND    i.itm_qtd_entregue < i.itm_qtd)
ORDER BY p.ped_data, p.ped_id;
-- @END

-- @BEGIN Q3_DEPOIS
SELECT pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo,
       SUM(i.itm_qtd - i.itm_qtd_entregue)                          AS demanda_pendente,
       SUM(i.itm_qtd - i.itm_qtd_entregue) - pr.prd_estoque_atual   AS deficit
FROM   erp_produtos pr
JOIN   erp_itens_pedido i ON i.prd_id = pr.prd_id
WHERE  pr.prd_ativo = 'S'
AND    i.itm_qtd_entregue < i.itm_qtd
AND    EXISTS (SELECT 1
               FROM   erp_pedidos p
               WHERE  p.ped_id = i.ped_id
               AND    p.ped_status IN ('ABERTO', 'FATURADO')
               AND    p.ped_data >= DATE '2025-10-01')
GROUP BY pr.prd_id, pr.prd_codigo, pr.prd_descricao, pr.prd_estoque_atual, pr.prd_estoque_minimo
HAVING SUM(i.itm_qtd - i.itm_qtd_entregue) > pr.prd_estoque_atual
ORDER BY deficit DESC, pr.prd_id
FETCH FIRST 500 ROWS ONLY;
-- @END

SET AUTOTRACE OFF

-- =============================================================================
-- PASSO 6 - Conferir estatisticas coletadas e indices criados
-- =============================================================================
SELECT table_name, num_rows, blocks, last_analyzed, stattype_locked
FROM   user_tab_statistics
WHERE  table_name LIKE 'ERP\_%' ESCAPE '\'
ORDER BY table_name;

SELECT index_name, table_name, status, num_rows, distinct_keys
FROM   user_indexes
WHERE  table_name LIKE 'ERP\_%' ESCAPE '\'
ORDER BY table_name, index_name;
