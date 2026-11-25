-- =============================================================================
-- 02_pkg_health_monitor.sql
-- Projeto  : Oracle Performance Tuning & Health Monitor
-- Objetivo : Package de monitoramento de saude do banco (locks, sessoes
--            bloqueadoras, tablespaces, Top SQL) com registro de alertas via
--            transacao autonoma.
-- Padrao   : SQL corporativo classico - sem funcoes analiticas (OVER PARTITION);
--            uso de JOIN, EXISTS e GROUP BY tradicionais.
-- Requisito: privilegios diretos concedidos em 00_setup_usuario.sql
-- =============================================================================
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED

CREATE OR REPLACE PACKAGE pkg_dba_health_monitor AS
  /*---------------------------------------------------------------------------
    Package  : PKG_DBA_HEALTH_MONITOR
    Objetivo : Capturar indicadores de saude do banco e registrar alertas.
    Uso      : DECLARE
                 v_w NUMBER; v_c NUMBER;
               BEGIN
                 pkg_dba_health_monitor.p_executa_checagem(v_w, v_c);
               END;
  ---------------------------------------------------------------------------*/

  -- Limiares de alerta
  gc_ts_warning_pct  CONSTANT NUMBER := 85;  -- % de uso de tablespace para WARNING
  gc_ts_critical_pct CONSTANT NUMBER := 95;  -- % de uso de tablespace para CRITICAL
  gc_lock_critical_s CONSTANT NUMBER := 60;  -- segundos de espera por lock para CRITICAL

  PROCEDURE p_registra_log        (p_severidade IN VARCHAR2,
                                   p_categoria  IN VARCHAR2,
                                   p_mensagem   IN VARCHAR2,
                                   p_detalhes   IN VARCHAR2 DEFAULT NULL);

  PROCEDURE p_captura_locks       (p_cursor OUT SYS_REFCURSOR);
  PROCEDURE p_sessoes_bloqueadoras(p_cursor OUT SYS_REFCURSOR);
  PROCEDURE p_uso_tablespaces     (p_cursor OUT SYS_REFCURSOR);
  PROCEDURE p_top_sql             (p_cursor OUT SYS_REFCURSOR,
                                   p_top_n  IN  NUMBER   DEFAULT 10,
                                   p_ordem  IN  VARCHAR2 DEFAULT 'CPU');
  PROCEDURE p_ultimos_alertas     (p_cursor OUT SYS_REFCURSOR,
                                   p_top_n  IN  NUMBER   DEFAULT 20);
  PROCEDURE p_executa_checagem    (p_qtd_warning  OUT NUMBER,
                                   p_qtd_critical OUT NUMBER);
END pkg_dba_health_monitor;
/
SHOW ERRORS

CREATE OR REPLACE PACKAGE BODY pkg_dba_health_monitor AS

  /*---------------------------------------------------------------------------
    Procedure : P_REGISTRA_LOG
    Objetivo  : Gravar um alerta em DBA_HEALTH_ALERTS em TRANSACAO AUTONOMA, de
                modo que o registro persista mesmo que a transacao chamadora
                sofra ROLLBACK.
    Parametros: p_severidade - INFO | WARNING | CRITICAL
                p_categoria  - LOCK | TABLESPACE | SQL | CHECK | SETUP ...
                p_mensagem   - texto resumido (ate 1000 caracteres)
                p_detalhes   - detalhes adicionais (ate 4000 caracteres)
    Retorno   : Nenhum
  ---------------------------------------------------------------------------*/
  PROCEDURE p_registra_log (p_severidade IN VARCHAR2,
                            p_categoria  IN VARCHAR2,
                            p_mensagem   IN VARCHAR2,
                            p_detalhes   IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO dba_health_alerts (severidade, categoria, mensagem, detalhes)
    VALUES (UPPER(p_severidade),
            UPPER(p_categoria),
            SUBSTR(p_mensagem, 1, 1000),
            SUBSTR(p_detalhes, 1, 4000));
    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END p_registra_log;

  /*---------------------------------------------------------------------------
    Procedure : PR_AVALIA_LOCKS (privada)
    Objetivo  : Detectar sessoes aguardando lock (V$LOCK x V$SESSION) e
                registrar alerta: WARNING se houver espera, CRITICAL se a maior
                espera atingir GC_LOCK_CRITICAL_S segundos.
    Parametros: p_qtd_warning / p_qtd_critical - contadores acumulados
  ---------------------------------------------------------------------------*/
  PROCEDURE pr_avalia_locks (p_qtd_warning  IN OUT NUMBER,
                             p_qtd_critical IN OUT NUMBER) IS
    v_qtd     NUMBER;
    v_max     NUMBER;
    v_detalhe VARCHAR2(4000);
  BEGIN
    SELECT COUNT(*), NVL(MAX(sw.seconds_in_wait), 0)
      INTO v_qtd, v_max
      FROM v$lock b
      JOIN v$lock    w  ON w.id1 = b.id1 AND w.id2 = b.id2 AND w.type = b.type AND w.sid <> b.sid
      JOIN v$session sw ON sw.sid = w.sid
     WHERE b.block = 1
       AND w.request > 0;

    IF v_qtd > 0 THEN
      FOR r IN (SELECT b.sid AS sid_bloqueador, w.sid AS sid_bloqueado, sw.seconds_in_wait AS espera
                  FROM v$lock b
                  JOIN v$lock    w  ON w.id1 = b.id1 AND w.id2 = b.id2 AND w.type = b.type AND w.sid <> b.sid
                  JOIN v$session sw ON sw.sid = w.sid
                 WHERE b.block = 1
                   AND w.request > 0
                 ORDER BY sw.seconds_in_wait DESC
                 FETCH FIRST 5 ROWS ONLY) LOOP
        v_detalhe := SUBSTR(v_detalhe || 'SID ' || r.sid_bloqueador || ' bloqueia SID ' || r.sid_bloqueado
                            || ' (' || r.espera || 's); ', 1, 4000);
      END LOOP;

      IF v_max >= gc_lock_critical_s THEN
        p_qtd_critical := p_qtd_critical + 1;
        p_registra_log('CRITICAL', 'LOCK',
                       v_qtd || ' sessao(oes) aguardando lock ha ate ' || v_max || 's', v_detalhe);
      ELSE
        p_qtd_warning := p_qtd_warning + 1;
        p_registra_log('WARNING', 'LOCK',
                       v_qtd || ' sessao(oes) aguardando lock (maior espera: ' || v_max || 's)', v_detalhe);
      END IF;
    END IF;
  END pr_avalia_locks;

  /*---------------------------------------------------------------------------
    Procedure : PR_AVALIA_TABLESPACES (privada)
    Objetivo  : Registrar alerta para cada tablespace acima dos limiares
                GC_TS_WARNING_PCT / GC_TS_CRITICAL_PCT.
    Parametros: p_qtd_warning / p_qtd_critical - contadores acumulados
  ---------------------------------------------------------------------------*/
  PROCEDURE pr_avalia_tablespaces (p_qtd_warning  IN OUT NUMBER,
                                   p_qtd_critical IN OUT NUMBER) IS
  BEGIN
    FOR r IN (SELECT m.tablespace_name AS nome, ROUND(m.used_percent, 2) AS pct
                FROM dba_tablespace_usage_metrics m
               WHERE m.used_percent >= gc_ts_warning_pct) LOOP
      IF r.pct >= gc_ts_critical_pct THEN
        p_qtd_critical := p_qtd_critical + 1;
        p_registra_log('CRITICAL', 'TABLESPACE', 'Tablespace ' || r.nome || ' com ' || r.pct || '% de uso');
      ELSE
        p_qtd_warning := p_qtd_warning + 1;
        p_registra_log('WARNING', 'TABLESPACE', 'Tablespace ' || r.nome || ' com ' || r.pct || '% de uso');
      END IF;
    END LOOP;
  END pr_avalia_tablespaces;

  /*---------------------------------------------------------------------------
    Procedure : PR_AVALIA_TOP_SQL (privada)
    Objetivo  : Registrar (INFO) o maior consumidor de CPU em V$SQL.
    Parametros: Nenhum
  ---------------------------------------------------------------------------*/
  PROCEDURE pr_avalia_top_sql IS
  BEGIN
    FOR r IN (SELECT s.sql_id, s.executions, ROUND(s.cpu_time / 1000000, 2) AS cpu_seg
                FROM v$sql s
               WHERE s.parsing_schema_name NOT IN ('SYS', 'SYSTEM', 'DBSNMP', 'SYSRAC', 'AUDSYS')
               ORDER BY s.cpu_time DESC
               FETCH FIRST 1 ROW ONLY) LOOP
      p_registra_log('INFO', 'SQL',
                     'Maior consumidor de CPU: SQL_ID ' || r.sql_id || ' - ' || r.cpu_seg
                     || 's em ' || r.executions || ' execucao(oes)');
    END LOOP;
  END pr_avalia_top_sql;

  /*---------------------------------------------------------------------------
    Procedure : P_CAPTURA_LOCKS
    Objetivo  : Retornar os pares bloqueador x bloqueado, combinando V$LOCK
                (quem detem / quem solicita) com V$SESSION (usuario, modulo,
                evento, tempo de espera) e o objeto envolvido.
    Parametros: p_cursor - SYS_REFCURSOR de saida
  ---------------------------------------------------------------------------*/
  PROCEDURE p_captura_locks (p_cursor OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_cursor FOR
      SELECT b.sid              AS sid_bloqueador,
             sb.serial#         AS serial_bloqueador,
             sb.username        AS usuario_bloqueador,
             sb.module          AS modulo_bloqueador,
             w.sid              AS sid_bloqueado,
             sw.username        AS usuario_bloqueado,
             sw.module          AS modulo_bloqueado,
             b.type             AS tipo_lock,
             b.lmode            AS modo_retido,
             w.request          AS modo_requisitado,
             sw.seconds_in_wait AS espera_seg,
             sw.event           AS evento,
             o.object_name      AS objeto,
             sw.sql_id          AS sql_id_bloqueado
        FROM v$lock b
        JOIN v$lock    w  ON w.id1 = b.id1 AND w.id2 = b.id2 AND w.type = b.type AND w.sid <> b.sid
        JOIN v$session sb ON sb.sid = b.sid
        JOIN v$session sw ON sw.sid = w.sid
        LEFT JOIN all_objects o ON o.object_id = sw.row_wait_obj#
       WHERE b.block = 1
         AND w.request > 0
       ORDER BY sw.seconds_in_wait DESC, b.sid, w.sid;
  END p_captura_locks;

  /*---------------------------------------------------------------------------
    Procedure : P_SESSOES_BLOQUEADORAS
    Objetivo  : Listar as sessoes que bloqueiam outras (V$SESSION.BLOCKING_SESSION),
                com a quantidade de sessoes bloqueadas por cada uma (GROUP BY).
    Parametros: p_cursor - SYS_REFCURSOR de saida
  ---------------------------------------------------------------------------*/
  PROCEDURE p_sessoes_bloqueadoras (p_cursor OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_cursor FOR
      SELECT s.sid,
             s.serial#      AS serial_num,
             s.username     AS usuario,
             s.status       AS situacao,
             s.osuser,
             s.machine      AS maquina,
             s.module       AS modulo,
             s.sql_id,
             s.last_call_et AS inativo_seg,
             COUNT(w.sid)   AS qtd_bloqueadas
        FROM v$session s
        JOIN v$session w ON w.blocking_session = s.sid
       GROUP BY s.sid, s.serial#, s.username, s.status, s.osuser, s.machine, s.module, s.sql_id, s.last_call_et
       ORDER BY COUNT(w.sid) DESC, s.sid;
  END p_sessoes_bloqueadoras;

  /*---------------------------------------------------------------------------
    Procedure : P_USO_TABLESPACES
    Objetivo  : Retornar o uso de cada tablespace (MB e %), com a situacao
                OK / WARNING / CRITICAL conforme os limiares da package.
    Parametros: p_cursor - SYS_REFCURSOR de saida
  ---------------------------------------------------------------------------*/
  PROCEDURE p_uso_tablespaces (p_cursor OUT SYS_REFCURSOR) IS
  BEGIN
    OPEN p_cursor FOR
      SELECT m.tablespace_name                                        AS nome_tablespace,
             ROUND(m.used_space * t.block_size / 1048576, 2)          AS usado_mb,
             ROUND(m.tablespace_size * t.block_size / 1048576, 2)     AS total_mb,
             ROUND(m.used_percent, 2)                                 AS pct_usado,
             CASE WHEN m.used_percent >= gc_ts_critical_pct THEN 'CRITICAL'
                  WHEN m.used_percent >= gc_ts_warning_pct  THEN 'WARNING'
                  ELSE 'OK' END                                       AS situacao
        FROM dba_tablespace_usage_metrics m
        JOIN dba_tablespaces t ON t.tablespace_name = m.tablespace_name
       ORDER BY m.used_percent DESC, m.tablespace_name;
  END p_uso_tablespaces;

  /*---------------------------------------------------------------------------
    Procedure : P_TOP_SQL
    Objetivo  : Retornar os SQLs de maior consumo em V$SQL, ordenados por CPU,
                IO (disk reads), BUFFER (buffer gets) ou TEMPO (elapsed).
    Parametros: p_cursor - SYS_REFCURSOR de saida
                p_top_n  - quantidade de linhas (default 10)
                p_ordem  - CPU | IO | BUFFER | TEMPO (default CPU)
  ---------------------------------------------------------------------------*/
  PROCEDURE p_top_sql (p_cursor OUT SYS_REFCURSOR,
                       p_top_n  IN  NUMBER,
                       p_ordem  IN  VARCHAR2) IS
  BEGIN
    OPEN p_cursor FOR
      SELECT s.sql_id,
             s.parsing_schema_name                 AS esquema,
             s.executions                          AS execucoes,
             ROUND(s.cpu_time / 1000000, 3)        AS cpu_seg,
             ROUND(s.elapsed_time / 1000000, 3)    AS tempo_seg,
             s.buffer_gets,
             s.disk_reads,
             s.rows_processed                      AS linhas,
             SUBSTR(s.sql_text, 1, 100)            AS sql_texto
        FROM v$sql s
       WHERE s.parsing_schema_name NOT IN ('SYS', 'SYSTEM', 'DBSNMP', 'SYSRAC', 'AUDSYS')
       ORDER BY CASE UPPER(p_ordem)
                  WHEN 'IO'     THEN s.disk_reads
                  WHEN 'BUFFER' THEN s.buffer_gets
                  WHEN 'TEMPO'  THEN s.elapsed_time
                  ELSE s.cpu_time
                END DESC
       FETCH FIRST p_top_n ROWS ONLY;
  END p_top_sql;

  /*---------------------------------------------------------------------------
    Procedure : P_ULTIMOS_ALERTAS
    Objetivo  : Retornar os alertas mais recentes de DBA_HEALTH_ALERTS.
    Parametros: p_cursor - SYS_REFCURSOR de saida
                p_top_n  - quantidade de linhas (default 20)
  ---------------------------------------------------------------------------*/
  PROCEDURE p_ultimos_alertas (p_cursor OUT SYS_REFCURSOR,
                               p_top_n  IN  NUMBER) IS
  BEGIN
    OPEN p_cursor FOR
      SELECT a.alert_id,
             TO_CHAR(a.dt_alerta, 'YYYY-MM-DD HH24:MI:SS') AS dt_alerta,
             a.severidade,
             a.categoria,
             a.mensagem
        FROM dba_health_alerts a
       ORDER BY a.alert_id DESC
       FETCH FIRST p_top_n ROWS ONLY;
  END p_ultimos_alertas;

  /*---------------------------------------------------------------------------
    Procedure : P_EXECUTA_CHECAGEM
    Objetivo  : Executar todas as verificacoes (locks, tablespaces, Top SQL) e
                registrar os alertas em DBA_HEALTH_ALERTS.
    Parametros: p_qtd_warning  - (OUT) alertas WARNING gerados nesta execucao
                p_qtd_critical - (OUT) alertas CRITICAL gerados nesta execucao
  ---------------------------------------------------------------------------*/
  PROCEDURE p_executa_checagem (p_qtd_warning  OUT NUMBER,
                                p_qtd_critical OUT NUMBER) IS
  BEGIN
    p_qtd_warning  := 0;
    p_qtd_critical := 0;

    pr_avalia_locks(p_qtd_warning, p_qtd_critical);
    pr_avalia_tablespaces(p_qtd_warning, p_qtd_critical);
    pr_avalia_top_sql;

    p_registra_log('INFO', 'CHECK',
                   'Checagem concluida: ' || p_qtd_warning || ' warning(s), ' || p_qtd_critical || ' critical(s)');
  END p_executa_checagem;

END pkg_dba_health_monitor;
/
SHOW ERRORS

-- Falha explicita se a package tiver ficado invalida
DECLARE
  v_erros NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_erros
    FROM user_errors
   WHERE name = 'PKG_DBA_HEALTH_MONITOR'
     AND attribute = 'ERROR';
  IF v_erros > 0 THEN
    RAISE_APPLICATION_ERROR(-20001, 'PKG_DBA_HEALTH_MONITOR possui erros de compilacao (veja USER_ERRORS)');
  END IF;
END;
/

-- Marcador de conclusao do setup (o Python aguarda este registro antes de iniciar)
INSERT INTO dba_health_alerts (severidade, categoria, mensagem)
VALUES ('INFO', 'SETUP', 'Carga inicial concluida: 100k clientes, 50k produtos, 1M pedidos, 2.5M itens');
COMMIT;

PROMPT >>> 02_pkg_health_monitor.sql concluido com sucesso.
