#!/usr/bin/env python3
"""
benchmark_runner.py - Benchmark "Antes e Depois" do laboratorio de tuning Oracle.

Fluxo:
  1. (opcional) RESET: remove indices do laboratorio e restaura estatisticas desatualizadas
  2. Captura o plano e mede as 3 queries na versao LENTA ("ANTES")
  3. Aplica o tuning (CREATE INDEX + DBMS_STATS) lido de sql/03_tuning_lab.sql
  4. Captura o plano e mede as 3 queries na versao OTIMIZADA ("DEPOIS")
  5. Exibe a tabela comparativa, grava em DBA_BENCHMARK_LOGS e exporta .md/.json + planos

Uso:
  docker compose exec app python benchmark_runner.py
  docker compose exec app python benchmark_runner.py --runs 5 --only Q1 Q3
  docker compose exec app python benchmark_runner.py --history
"""
from __future__ import annotations

import argparse
import json
import re
import time
import uuid
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path

import oracledb
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from tabulate import tabulate

from common import Settings, build_table, connect, fmt_duration, get_settings, wait_for_database

console = Console()

# (id, nome gravado no log, descricao)
QUERIES = [
    ("Q1", "Q1_FATURAMENTO", "Faturamento por cliente/regiao (mar/2025)"),
    ("Q2", "Q2_PENDENTES_ENTREGA", "Pedidos com itens pendentes de entrega (nov/2025)"),
    ("Q3", "Q3_ESTOQUE_VS_PEDIDOS", "Estoque x demanda pendente (4o tri/2025)"),
]

STAT_NAMES = ("session logical reads", "physical reads", "CPU used by this session")
SECTION_RE = re.compile(r"^--\s*@BEGIN\s+(\w+)[ \t]*\n(.*?)^--\s*@END[ \t]*$", re.MULTILINE | re.DOTALL)


# --------------------------------------------------------------------------- #
# Leitura do laboratorio SQL                                                   #
# --------------------------------------------------------------------------- #
def load_lab(path: Path) -> dict[str, str]:
    """Extrai os blocos '-- @BEGIN NOME' ... '-- @END' de 03_tuning_lab.sql."""
    text = path.read_text(encoding="utf-8")
    return {m.group(1): m.group(2).strip() for m in SECTION_RE.finditer(text)}


def split_statements(block: str) -> list[str]:
    """Separa comandos terminados por uma linha contendo apenas '/' (estilo SQL*Plus)."""
    statements, buffer = [], []
    for line in block.splitlines():
        if line.strip() == "/":
            stmt = "\n".join(buffer).strip()
            if stmt:
                statements.append(stmt)
            buffer = []
        else:
            buffer.append(line)
    tail = "\n".join(buffer).strip()
    if tail:
        statements.append(tail)
    return statements


def clean_query(sql: str) -> str:
    return sql.strip().rstrip(";").strip()


# --------------------------------------------------------------------------- #
# Medicao                                                                      #
# --------------------------------------------------------------------------- #
@dataclass
class Measure:
    elapsed_ms: float = 0.0
    cpu_ms: float = 0.0
    logical_reads: int = 0
    physical_reads: int = 0
    rows: int = 0
    timed_out: bool = False
    runs: int = 1


class Bench:
    def __init__(self, settings: Settings, timeout_s: int):
        self.settings = settings
        self.timeout_ms = int(timeout_s * 1000)
        self.conn = self._open()

    def _open(self) -> oracledb.Connection:
        return connect(self.settings, module="BENCHMARK_RUNNER")

    def _reconnect(self) -> None:
        try:
            self.conn.close()
        except oracledb.Error:
            pass
        self.conn = self._open()

    def _snapshot(self) -> dict[str, int]:
        cur = self.conn.cursor()
        cur.execute(
            "SELECT sn.name, ms.value FROM v$mystat ms "
            "JOIN v$statname sn ON sn.statistic# = ms.statistic# "
            "WHERE sn.name IN (:1, :2, :3)",
            list(STAT_NAMES),
        )
        data = {name: int(value) for name, value in cur.fetchall()}
        cur.close()
        return data

    def _execute_once(self, sql: str) -> Measure:
        before = self._snapshot()
        cur = self.conn.cursor()
        cur.arraysize = 1000
        self.conn.call_timeout = self.timeout_ms
        try:
            t0 = time.perf_counter()
            cur.execute(sql)
            rows = 0
            while True:
                batch = cur.fetchmany(1000)
                if not batch:
                    break
                rows += len(batch)
            elapsed_ms = (time.perf_counter() - t0) * 1000
        finally:
            self.conn.call_timeout = 0
        cur.close()
        after = self._snapshot()
        delta = {k: after.get(k, 0) - before.get(k, 0) for k in STAT_NAMES}
        return Measure(
            elapsed_ms=elapsed_ms,
            cpu_ms=delta["CPU used by this session"] * 10.0,  # centissegundos -> ms
            logical_reads=delta["session logical reads"],
            physical_reads=delta["physical reads"],
            rows=rows,
        )

    def measure(self, sql: str, runs: int) -> Measure:
        """Executa a query `runs` vezes e devolve a execucao mediana (por tempo)."""
        samples: list[Measure] = []
        for _ in range(runs):
            try:
                samples.append(self._execute_once(sql))
            except oracledb.Error as exc:
                if "DPY-4024" in str(exc) or "ORA-01013" in str(exc):
                    self._reconnect()
                    return Measure(elapsed_ms=float(self.timeout_ms), timed_out=True, runs=len(samples) + 1)
                raise
        samples.sort(key=lambda m: m.elapsed_ms)
        median = samples[len(samples) // 2]
        median.runs = len(samples)
        return median

    def capture_plan(self, sql: str, statement_id: str) -> str:
        """EXPLAIN PLAN + DBMS_XPLAN.DISPLAY (sem executar a query)."""
        cur = self.conn.cursor()
        cur.execute("DELETE FROM plan_table WHERE statement_id = :s", s=statement_id)
        cur.execute(f"EXPLAIN PLAN SET STATEMENT_ID = '{statement_id}' FOR {sql}")
        cur.execute(
            "SELECT plan_table_output FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', :sid, 'TYPICAL'))",
            sid=statement_id,
        )
        lines = [r[0] for r in cur.fetchall()]
        cur.close()
        return "\n".join(lines)

    def apply_block(self, block: str) -> None:
        cur = self.conn.cursor()
        for stmt in split_statements(block):
            cur.execute(stmt)
        cur.close()

    def save_logs(self, run_id: str, name: str, phase: str, m: Measure, obs: str) -> None:
        cur = self.conn.cursor()
        cur.execute(
            "INSERT INTO dba_benchmark_logs "
            "(run_id, query_name, fase, elapsed_ms, cpu_ms, logical_reads, physical_reads, rows_fetched, obs) "
            "VALUES (:1, :2, :3, :4, :5, :6, :7, :8, :9)",
            [run_id, name, phase, round(m.elapsed_ms, 2), round(m.cpu_ms, 2),
             m.logical_reads, m.physical_reads, m.rows, obs[:400]],
        )
        cur.close()
        self.conn.commit()


# --------------------------------------------------------------------------- #
# Apresentacao                                                                 #
# --------------------------------------------------------------------------- #
def gain_pct(before_ms: float, after_ms: float) -> float:
    return (before_ms - after_ms) / before_ms * 100 if before_ms > 0 else 0.0


def speedup(before_ms: float, after_ms: float) -> float:
    return before_ms / max(after_ms, 0.001)


def show_history(settings: Settings) -> None:
    with connect(settings) as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT TO_CHAR(dt_execucao, 'YYYY-MM-DD HH24:MI:SS') AS dt, run_id, query_name, fase, "
            "elapsed_ms, logical_reads, rows_fetched "
            "FROM dba_benchmark_logs ORDER BY log_id DESC FETCH FIRST 24 ROWS ONLY"
        )
        columns = [d[0] for d in cur.description]
        rows = [dict(zip(columns, r)) for r in cur.fetchall()]
    console.print(build_table("Ultimos registros de DBA_BENCHMARK_LOGS", columns, rows, max_rows=24))


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Benchmark antes/depois do tuning Oracle")
    p.add_argument("--runs", type=int, default=3, help="execucoes por query/fase; usa a mediana (default: 3)")
    p.add_argument("--timeout", type=int, default=300, help="timeout por execucao em segundos (default: 300)")
    p.add_argument("--only", nargs="+", choices=[q[0] for q in QUERIES], help="executa apenas estas queries")
    p.add_argument("--no-reset", action="store_true", help="nao executa o RESET (usa o estado atual do banco)")
    p.add_argument("--export", choices=["md", "json", "both", "none"], default="both")
    p.add_argument("--history", action="store_true", help="mostra o historico de DBA_BENCHMARK_LOGS e sai")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    settings = get_settings()

    console.print(Panel.fit("[bold]Oracle Performance Tuning - Benchmark Antes x Depois[/bold]", border_style="cyan"))
    wait_for_database(settings, console)

    if args.history:
        show_history(settings)
        return

    lab = load_lab(settings.sql_dir / "03_tuning_lab.sql")
    selected = [q for q in QUERIES if not args.only or q[0] in args.only]
    needed = ["RESET", "TUNING"] + [f"{q[0]}_{ph}" for q in selected for ph in ("ANTES", "DEPOIS")]
    missing = [n for n in needed if n not in lab]
    if missing:
        raise SystemExit(f"Blocos ausentes em 03_tuning_lab.sql: {missing}")

    run_id = uuid.uuid4().hex[:12]
    started = datetime.now()
    plans_dir = settings.reports_dir / "plans" / run_id
    plans_dir.mkdir(parents=True, exist_ok=True)
    bench = Bench(settings, args.timeout)
    results: dict[str, dict[str, Measure]] = {q[0]: {} for q in selected}

    if not args.no_reset:
        with console.status("Restaurando estado inicial (drop de indices + estatisticas desatualizadas)..."):
            bench.apply_block(lab["RESET"])

    def run_phase(phase: str) -> None:
        for qid, name, desc in selected:
            sql = clean_query(lab[f"{qid}_{phase}"])
            with console.status(f"[{phase}] {qid} - {desc}: plano de execucao..."):
                plan = bench.capture_plan(sql, f"{qid}_{phase}_{run_id}"[:30])
            (plans_dir / f"{qid}_{phase.lower()}.txt").write_text(plan, encoding="utf-8")
            with console.status(f"[{phase}] {qid} - {desc}: medindo ({args.runs} execucoes)..."):
                results[qid][phase] = bench.measure(sql, args.runs)
            m = results[qid][phase]
            flag = " [red](TIMEOUT)[/red]" if m.timed_out else ""
            console.print(f"  [{phase}] {qid}: {fmt_duration(m.elapsed_ms)}{flag}  "
                          f"logical reads={m.logical_reads:,}  linhas={m.rows:,}")

    console.rule("[bold red]Fase ANTES (sem indices, estatisticas desatualizadas)")
    run_phase("ANTES")

    console.rule("[bold yellow]Aplicando tuning (CREATE INDEX + DBMS_STATS)")
    t0 = time.perf_counter()
    with console.status("Criando indices compostos e coletando estatisticas..."):
        bench.apply_block(lab["TUNING"])
    tuning_s = time.perf_counter() - t0
    console.print(f"Tuning aplicado em {tuning_s:.1f} s")

    console.rule("[bold green]Fase DEPOIS (indices + estatisticas atualizadas + queries reescritas)")
    run_phase("DEPOIS")

    # ---- grava historico ---------------------------------------------------- #
    for qid, name, _ in selected:
        for phase in ("ANTES", "DEPOIS"):
            m = results[qid][phase]
            obs = f"mediana de {m.runs} execucao(oes)" + ("; TIMEOUT" if m.timed_out else "")
            bench.save_logs(run_id, name, phase, m, obs)

    # ---- tabela comparativa ------------------------------------------------- #
    headers = ["Query", "Antes", "Depois", "Ganho (%)", "Speedup", "Logical reads (antes -> depois)", "Linhas (A/D)", "Mesmo resultado"]
    table_rows, json_rows = [], []
    total_before = total_after = 0.0
    for qid, name, desc in selected:
        a, d = results[qid]["ANTES"], results[qid]["DEPOIS"]
        total_before += a.elapsed_ms
        total_after += d.elapsed_ms
        same = (a.rows == d.rows) and not a.timed_out
        prefix = ">= " if a.timed_out else ""
        table_rows.append([
            f"{qid} - {desc}",
            prefix + fmt_duration(a.elapsed_ms),
            fmt_duration(d.elapsed_ms),
            f"{gain_pct(a.elapsed_ms, d.elapsed_ms):.1f}%",
            f"{speedup(a.elapsed_ms, d.elapsed_ms):.1f}x",
            f"{a.logical_reads:,} -> {d.logical_reads:,}",
            f"{a.rows:,} / {d.rows:,}",
            "sim" if same else "NAO (verifique)",
        ])
        json_rows.append({"query": name, "descricao": desc, "antes": asdict(a), "depois": asdict(d),
                          "ganho_pct": round(gain_pct(a.elapsed_ms, d.elapsed_ms), 2),
                          "speedup": round(speedup(a.elapsed_ms, d.elapsed_ms), 2), "mesmo_resultado": same})
    table_rows.append([
        "TOTAL", fmt_duration(total_before), fmt_duration(total_after),
        f"{gain_pct(total_before, total_after):.1f}%", f"{speedup(total_before, total_after):.1f}x", "", "", "",
    ])

    rich_table = Table(title="Resultado: Antes x Depois do Tuning", header_style="bold cyan", show_lines=True)
    for h in headers:
        rich_table.add_column(h, justify="left" if h in ("Query", "Mesmo resultado") else "right")
    for row in table_rows:
        style = "bold green" if row[0] == "TOTAL" else None
        rich_table.add_row(*row, style=style)
    console.print(rich_table)
    console.print(f"Run ID: [bold]{run_id}[/bold] | historico em DBA_BENCHMARK_LOGS | planos em {plans_dir}")

    # ---- exportacao --------------------------------------------------------- #
    stamp = started.strftime("%Y%m%d_%H%M%S")
    settings.reports_dir.mkdir(parents=True, exist_ok=True)
    if args.export in ("md", "both"):
        md = [
            "# Relatorio de Benchmark - Oracle Performance Tuning",
            "",
            f"- **Run ID:** `{run_id}`",
            f"- **Data:** {started:%Y-%m-%d %H:%M:%S}",
            f"- **Execucoes por query/fase:** {args.runs} (mediana)",
            f"- **Tempo para aplicar o tuning (indices + estatisticas):** {tuning_s:.1f} s",
            "",
            tabulate(table_rows, headers=headers, tablefmt="github"),
            "",
            f"Planos de execucao: `plans/{run_id}/`",
            "",
        ]
        path = settings.reports_dir / f"benchmark_{stamp}.md"
        path.write_text("\n".join(md), encoding="utf-8")
        console.print(f"Relatorio Markdown: {path}")
    if args.export in ("json", "both"):
        path = settings.reports_dir / f"benchmark_{stamp}.json"
        payload = {"run_id": run_id, "data": started.isoformat(), "runs_por_query": args.runs,
                   "tuning_segundos": round(tuning_s, 2), "resultados": json_rows}
        path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        console.print(f"Relatorio JSON: {path}")

    bench.conn.close()


if __name__ == "__main__":
    main()
