#!/bin/bash
# =============================================================================
# Executado automaticamente pela imagem gvenzl/oracle-free na PRIMEIRA
# inicialização (volume de dados vazio). Cria o usuário ERP_DBA, carrega a
# massa de dados e compila a package de monitoramento.
# =============================================================================
export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
PDB="FREEPDB1"
APP_USER="ERP_DBA"
SQL_DIR="/sql-scripts"

echo ">>> [init] (1/3) Criando usuario ${APP_USER} e concedendo privilegios no ${PDB}..."
sqlplus -L / as sysdba <<EOF
WHENEVER SQLERROR EXIT FAILURE
ALTER SESSION SET CONTAINER = ${PDB};
@${SQL_DIR}/00_setup_usuario.sql "${ERP_PWD}"
EXIT
EOF
if [ $? -ne 0 ]; then echo "!!! [init] Falha ao criar o usuario ${APP_USER}"; exit 1; fi

CONN="${APP_USER}/${ERP_PWD}@//localhost:1521/${PDB}"

echo ">>> [init] (2/3) Criando schema e carregando massa de dados (pode levar alguns minutos)..."
sqlplus -L "${CONN}" @"${SQL_DIR}/01_schema_e_carga.sql" < /dev/null
if [ $? -ne 0 ]; then echo "!!! [init] Falha em 01_schema_e_carga.sql"; exit 1; fi

echo ">>> [init] (3/3) Compilando PKG_DBA_HEALTH_MONITOR..."
sqlplus -L "${CONN}" @"${SQL_DIR}/02_pkg_health_monitor.sql" < /dev/null
if [ $? -ne 0 ]; then echo "!!! [init] Falha em 02_pkg_health_monitor.sql"; exit 1; fi

echo ">>> [init] Ambiente pronto."
