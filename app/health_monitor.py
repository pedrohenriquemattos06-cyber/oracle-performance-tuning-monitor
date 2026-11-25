#!/usr/bin/env python3
"""
health_monitor.py - Monitor de saude do banco Oracle (sob demanda ou continuo).

Consulta a PKG_DBA_HEALTH_MONITOR (locks, sessoes bloqueadoras, tablespaces, Top SQL),
registra alertas em DBA_HEALTH_ALERTS e gera um diagnostico no terminal, exportavel
para Markdown e/ou JSON. Por padrao, SIMULA uma contencao de lock entre duas sessoes
para demonstrar a deteccao em tempo real.

Uso:
  docker compose exec app python health_monitor.py                      # 1 snapshot com simulacao de lock
  docker compose exec app python health_monitor.py --no-simulate-lock   # snapshot sem simulacao
  docker compose exec app python health_monitor.py --watch 30           # monitoramento continuo (30 s)
  docker compose exec app python health_monitor.py --export json
"""
from __future__ import annotations

import argparse
import json
import threading
import time
from contextlib import contextmanager
from datetime import datetime

import oracledb
from faker import Faker
from rich.console import Console
from rich.panel import Panel
from tabulate import tabulate

from common import Settings, build_table, connect, fetch_ref_cursor, get_settings, wait_for_database

console = Console()
PKG = "pkg_dba_health_monitor"


# --------------------------------------------------------------------------- #
# Simulacao de contencao de lock (2 sessoes)                                   #
# --------------------------------------------------------------------------- #
@contextmanager
def lock_contention(settings: Settings, hold_seconds: float):
    """Sessao A faz UPDATE sem COMMIT; sessao B tenta atualizar a mesma linha e fica bloqueada.

    Dentro do bloco `with` a contencao esta ativa; ao sair, A faz ROLLBACK e B e liberada.
    """
    fake = Faker("pt_BR")
    info = {"linha": "ERP_CLIENTES.CLI_ID = 1", "detectada_em_segundos": None}
    errors: list[Exception] = []

    blocker = connect(settings, module="LOCK_SIM_BLOCKER")
    cur = blocker.cursor()
    cur.execute("UPDATE erp_clientes SET cli_nome = :n WHERE cli_id = :id", n=fake.company()[:90], id=1)
    cur.execute("SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual")
    info["sid_bloqueador"] = cur.fetchone()[0]

    def waiter() -> None:
        conn = None
        try:
            conn = connect(settings, module="LOCK_SIM_WAITER")
            c = conn.cursor()
            c.execute("UPDATE erp_clientes SET cli_nome = :n WHERE cli_id = :id", n=fake.company()[:90], id=1)
            conn.rollback()
        except Exception as exc:  # noqa: BLE001 - registrado e exibido ao final
            errors.append(exc)
        finally:
            if conn is not None:
                conn.close()

    thread = threading.Thread(target=waiter, name="lock-waiter", daemon=True)
    thread.start()

    # aguarda a sessao B aparecer como bloqueada em V$SESSION (ate 20 s)
    started = time.monotonic()
    probe = blocker.cursor()
    while time.monotonic() - started < 20:
        probe.execute("SELECT COUNT(*) FROM v$session WHERE module = 'LOCK_SIM_WAITER' AND blocking_session IS NOT NULL")
        if probe.fetchone()[0] > 0:
            info["detectada_em_segundos"] = round(time.monotonic() - started, 1)
            break
        time.sleep(0.5)
    time.sleep(hold_seconds)  # deixa o tempo de espera acumular

    try:
        yield info
    finally:
        blocker.rollback()          # libera o lock -> sessao B prossegue
        thread.join(timeout=30)
        blocker.close()
        if errors:
            console.print(f"[red]Erro na sessao B da simulacao: {errors[0]}[/red]")


# --------------------------------------------------------------------------- #
# Coleta e diagnostico                                                         #
# --------------------------------------------------------------------------- #
def collect_snapshot(conn: oracledb.Connection, top_n: int) -> dict:
    cur = conn.cursor()
    qtd_warning = cur.var(oracledb.NUMBER)
    qtd_critical = cur.var(oracledb.NUMBER)
    cur.callproc(f"{PKG}.p_executa_checagem", [qtd_warning, qtd_critical])

    sections: dict[str, dict] = {}
    plan = [
        ("locks", "Locks ativos (V$LOCK x V$SESSION)", f"{PKG}.p_captura_locks(:1)", []),
        ("bloqueadoras", "Sessoes bloqueadoras", f"{PKG}.p_sessoes_bloqueadoras(:1)", []),
        ("tablespaces", "Uso de tablespaces", f"{PKG}.p_uso_tablespaces(:1)", []),
        ("top_sql_cpu", f"Top {top_n} SQL por CPU (V$SQL)", f"{PKG}.p_top_sql(:1, :2, :3)", [top_n, "CPU"]),
        ("top_sql_io", f"Top {top_n} SQL por I/O fisico (V$SQL)", f"{PKG}.p_top_sql(:1, :2, :3)", [top_n, "IO"]),
        ("alertas", "Ultimos alertas registrados (DBA_HEALTH_ALERTS)", f"{PKG}.p_ultimos_alertas(:1, :2)", [12]),
    ]
    for key, title, call, args in plan:
        columns, rows = fetch_ref_cursor(conn, call, *args)
        sections[key] = {"title": title, "columns": columns, "rows": rows}

    warnings = int(qtd_warning.getvalue() or 0)
    criticals = int(qtd_critical.getvalue() or 0)
    status = "CRITICO" if criticals else ("ATENCAO" if warnings else "SAUDAVEL")
    return {
        "gerado_em": datetime.now().isoformat(timespec="seconds"),
        "status": status,
        "alertas_warning": warnings,
        "alertas_critical": criticals,
        "sections": sections,
    }


def build_findings(snapshot: dict) -> list[str]:
    """Traduz os dados coletados em achados e recomendacoes em linguagem de DBA."""
    findings: list[str] = []
    s = snapshot["sections"]

    for row in s["locks"]["rows"]:
        findings.append(
            f"LOCK: SID {row['SID_BLOQUEADOR']} (modulo {row['MODULO_BLOQUEADOR'] or '-'}) bloqueia SID "
            f"{row['SID_BLOQUEADO']} ha {row['ESPERA_SEG']}s no objeto {row['OBJETO'] or 'n/d'} "
            f"(evento: {row['EVENTO']}). Acao: pedir COMMIT/ROLLBACK ao dono da sessao ou, em ultimo caso, "
            f"ALTER SYSTEM KILL SESSION '{row['SID_BLOQUEADOR']},{row['SERIAL_BLOQUEADOR']}' IMMEDIATE."
        )
    for row in s["tablespaces"]["rows"]:
        if row["SITUACAO"] != "OK":
            findings.append(f"TABLESPACE {row['NOME_TABLESPACE']} em {row['PCT_USADO']}% ({row['SITUACAO']}): "
                            f"adicionar datafile/ampliar autoextend ou arquivar dados.")
    if s["top_sql_cpu"]["rows"]:
        top = s["top_sql_cpu"]["rows"][0]
        findings.append(
            f"TOP SQL (CPU): SQL_ID {top['SQL_ID']} - {top['CPU_SEG']}s de CPU, {top['BUFFER_GETS']:,} buffer gets "
            f"em {top['EXECUCOES']} execucao(oes). Candidata a tuning (veja plano com DBMS_XPLAN.DISPLAY_CURSOR)."
        )
    if not findings:
        findings.append("Nenhuma anomalia detectada: sem locks, tablespaces dentro dos limites.")
    return findings


# --------------------------------------------------------------------------- #
# Saida                                                                        #
# --------------------------------------------------------------------------- #
def render(snapshot: dict, findings: list[str], simulation: dict | None) -> None:
    color = {"SAUDAVEL": "green", "ATENCAO": "yellow", "CRITICO": "red"}[snapshot["status"]]
    console.print(Panel.fit(
        f"[bold {color}]STATUS: {snapshot['status']}[/bold {color}]   "
        f"warnings={snapshot['alertas_warning']}  criticals={snapshot['alertas_critical']}   "
        f"({snapshot['gerado_em']})",
        title="Oracle Health Monitor", border_style=color))
    if simulation:
        console.print(f"[magenta]Simulacao ativa:[/magenta] SID {simulation['sid_bloqueador']} segurando lock em "
                      f"{simulation['linha']}; sessao bloqueada detectada em "
                      f"{simulation['detectada_em_segundos']}s.")
    for key in ("locks", "bloqueadoras", "tablespaces", "top_sql_cpu", "top_sql_io", "alertas"):
        sec = snapshot["sections"][key]
        if sec["rows"]:
            console.print(build_table(sec["title"], sec["columns"], sec["rows"], max_rows=12))
        else:
            console.print(f"[dim]{sec['title']}: nenhum registro[/dim]")
    console.print(Panel("\n".join(f"- {f}" for f in findings), title="Diagnostico e recomendacoes", border_style=color))


def export_report(snapshot: dict, findings: list[str], simulation: dict | None, settings: Settings, fmt: str) -> None:
    if fmt == "none":
        return
    settings.reports_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    if fmt in ("md", "both"):
        lines = [
            "# Relatorio de Saude do Banco Oracle",
            "",
            f"- **Gerado em:** {snapshot['gerado_em']}",
            f"- **Status:** {snapshot['status']} ({snapshot['alertas_warning']} warning, "
            f"{snapshot['alertas_critical']} critical)",
        ]
        if simulation:
            lines.append(f"- **Simulacao de lock:** SID {simulation['sid_bloqueador']} bloqueando em {simulation['linha']}")
        lines += ["", "## Diagnostico", ""] + [f"- {f}" for f in findings] + [""]
        for key in ("locks", "bloqueadoras", "tablespaces", "top_sql_cpu", "top_sql_io", "alertas"):
            sec = snapshot["sections"][key]
            lines += [f"## {sec['title']}", ""]
            if sec["rows"]:
                body = [[("" if r[c] is None else r[c]) for c in sec["columns"]] for r in sec["rows"]]
                lines.append(tabulate(body, headers=[c.lower() for c in sec["columns"]], tablefmt="github"))
            else:
                lines.append("_Nenhum registro._")
            lines.append("")
        path = settings.reports_dir / f"health_report_{stamp}.md"
        path.write_text("\n".join(lines), encoding="utf-8")
        console.print(f"Relatorio Markdown: {path}")

    if fmt in ("json", "both"):
        payload = {
            "gerado_em": snapshot["gerado_em"],
            "status": snapshot["status"],
            "alertas_warning": snapshot["alertas_warning"],
            "alertas_critical": snapshot["alertas_critical"],
            "simulacao_lock": simulation,
            "diagnostico": findings,
            "secoes": {k: v["rows"] for k, v in snapshot["sections"].items()},
        }
        path = settings.reports_dir / f"health_report_{stamp}.json"
        path.write_text(json.dumps(payload, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
        console.print(f"Relatorio JSON: {path}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Monitor de saude do banco Oracle")
    p.add_argument("--watch", type=int, metavar="SEG", help="modo continuo: repete a cada SEG segundos")
    p.add_argument("--simulate-lock", action=argparse.BooleanOptionalAction, default=True,
                   help="simula contencao de lock entre duas sessoes (default: ligado; na 1a iteracao)")
    p.add_argument("--lock-seconds", type=float, default=4.0, help="tempo extra de espera da simulacao (default: 4)")
    p.add_argument("--top-n", type=int, default=8, help="linhas nos rankings de Top SQL (default: 8)")
    p.add_argument("--export", choices=["md", "json", "both", "none"], default="both")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    settings = get_settings()
    console.print(Panel.fit("[bold]Oracle Performance Tuning & Health Monitor[/bold]", border_style="cyan"))
    wait_for_database(settings, console)

    iteration = 0
    try:
        while True:
            iteration += 1
            simulation = None
            with connect(settings, module="HEALTH_MONITOR") as conn:
                if args.simulate_lock and iteration == 1:
                    console.print("[magenta]Criando contencao de lock entre duas sessoes...[/magenta]")
                    with lock_contention(settings, args.lock_seconds) as simulation:
                        snapshot = collect_snapshot(conn, args.top_n)
                        findings = build_findings(snapshot)
                        render(snapshot, findings, simulation)
                    console.print("[magenta]Lock liberado (ROLLBACK na sessao bloqueadora).[/magenta]")
                else:
                    snapshot = collect_snapshot(conn, args.top_n)
                    findings = build_findings(snapshot)
                    render(snapshot, findings, simulation)
            export_report(snapshot, findings, simulation, settings, args.export)
            if not args.watch:
                break
            console.print(f"[dim]Proxima checagem em {args.watch}s (Ctrl+C para sair)...[/dim]")
            time.sleep(args.watch)
    except KeyboardInterrupt:
        console.print("\n[yellow]Monitoramento encerrado.[/yellow]")


if __name__ == "__main__":
    main()
