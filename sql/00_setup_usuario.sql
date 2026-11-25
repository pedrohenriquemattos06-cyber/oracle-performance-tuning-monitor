-- =============================================================================
-- 00_setup_usuario.sql
-- Cria o usuario ERP_DBA no PDB (FREEPDB1) e concede os privilegios diretos
-- necessarios para a package de monitoramento (definer's rights nao enxerga
-- privilegios vindos de ROLE, por isso os GRANTs sao feitos objeto a objeto).
-- Executado como SYS pelo script docker/initdb/01_init_projeto.sh
-- Uso: @00_setup_usuario.sql <senha_do_erp_dba>
-- =============================================================================
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET VERIFY OFF

DECLARE
  v_qtd NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_qtd FROM dba_users WHERE username = 'ERP_DBA';
  IF v_qtd > 0 THEN
    EXECUTE IMMEDIATE 'DROP USER erp_dba CASCADE';
  END IF;
END;
/

CREATE USER erp_dba IDENTIFIED BY "&1"
  DEFAULT TABLESPACE users
  TEMPORARY TABLESPACE temp
  QUOTA UNLIMITED ON users;

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE, CREATE PROCEDURE TO erp_dba;

-- Privilegios diretos (usados dentro da PKG_DBA_HEALTH_MONITOR e pelo Python)
GRANT SELECT ON sys.v_$session                    TO erp_dba;
GRANT SELECT ON sys.v_$lock                       TO erp_dba;
GRANT SELECT ON sys.v_$sql                        TO erp_dba;
GRANT SELECT ON sys.v_$mystat                     TO erp_dba;
GRANT SELECT ON sys.v_$statname                   TO erp_dba;
GRANT SELECT ON sys.dba_tablespaces               TO erp_dba;
GRANT SELECT ON sys.dba_tablespace_usage_metrics  TO erp_dba;

-- Facilita o uso de SET AUTOTRACE no SQL*Plus / SQLcl durante o laboratorio
GRANT SELECT_CATALOG_ROLE TO erp_dba;

EXIT
