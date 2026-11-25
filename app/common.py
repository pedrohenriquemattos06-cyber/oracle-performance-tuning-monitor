"""Utilitarios compartilhados entre benchmark_runner.py e health_monitor.py."""
from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path

import oracledb
from rich.console import Console
from rich.table import Table


@dataclass(frozen=True)
class Settings:
    user: str
    password: str
    dsn: str
    sql_dir: Path
    reports_dir: Path


def get_settings() -> Settings:
    """Le a configuracao a partir de variaveis de ambiente (definidas no docker-compose)."""
    return Settings(
        user=os.getenv("DB_USER", "erp_dba"),
        password=os.getenv("DB_PASSWORD", "ErpDba_2025"),
        dsn=os.getenv("DB_DSN", "oracle-db:1521/FREEPDB1"),
        sql_dir=Path(os.getenv("SQL_DIR", "/sql")),
        reports_dir=Path(os.getenv("REPORTS_DIR", "/reports")),
    )


def connect(settings: Settings, module: str | None = None) -> oracledb.Connection:
    """Abre uma conexao (modo Thin: nao requer Oracle Client). `module` identifica a sessao em V$SESSION."""
    conn = oracledb.connect(user=settings.user, password=settings.password, dsn=settings.dsn)
    if module:
        conn.module = module
    return conn


def wait_for_database(settings: Settings, console: Console, timeout_s: int = 1800, interval_s: int = 10) -> None:
    """Aguarda o Oracle aceitar conexoes e a carga inicial (init scripts) terminar."""
    deadline = time.monotonic() + timeout_s
    last_msg = None
    while True:
        try:
            with connect(settings) as conn:
                cur = conn.cursor()
                cur.execute(
                    "SELECT COUNT(*) FROM dba_health_alerts "
                    "WHERE categoria = 'SETUP' AND mensagem LIKE 'Carga inicial%'"
                )
                if cur.fetchone()[0] > 0:
                    console.print("[green]Banco de dados pronto.[/green]")
                    return
                msg = "Banco acessivel; aguardando o termino da carga inicial (1M pedidos / 2,5M itens)..."
        except oracledb.Error as exc:
            first_line = str(exc).splitlines()[0][:100]
            msg = f"Aguardando o Oracle iniciar... ({first_line})"
        if msg != last_msg:
            console.print(f"[yellow]{msg}[/yellow]")
            last_msg = msg
        if time.monotonic() > deadline:
            raise TimeoutError("Tempo esgotado aguardando o banco de dados.")
        time.sleep(interval_s)


def fetch_ref_cursor(conn: oracledb.Connection, call: str, *args):
    """Executa 'BEGIN <call>; END;' onde o 1o bind (:1) e um SYS_REFCURSOR de saida.

    Exemplo: fetch_ref_cursor(conn, "pkg.p_top_sql(:1, :2, :3)", 10, "CPU")
    Retorna (colunas, linhas_como_dicts).
    """
    ref = conn.cursor()
    cur = conn.cursor()
    cur.execute(f"BEGIN {call}; END;", [ref, *args])
    columns = [d[0] for d in ref.description]
    rows = [dict(zip(columns, row)) for row in ref.fetchall()]
    ref.close()
    cur.close()
    return columns, rows


def fmt_duration(ms: float) -> str:
    """Formata milissegundos como 'X ms' ou 'Y.YY s'."""
    if ms >= 1000:
        return f"{ms / 1000:.2f} s"
    if ms >= 10:
        return f"{ms:.0f} ms"
    return f"{ms:.1f} ms"


def build_table(title: str, columns: list[str], rows: list[dict], max_rows: int = 20) -> Table:
    """Cria uma tabela Rich a partir de uma lista de dicts."""
    table = Table(title=title, header_style="bold cyan", title_justify="left")
    for col in columns:
        table.add_column(col.lower())
    for row in rows[:max_rows]:
        table.add_row(*["-" if row[c] is None else str(row[c]) for c in columns])
    if len(rows) > max_rows:
        table.caption = f"... e mais {len(rows) - max_rows} linha(s)"
    return table
