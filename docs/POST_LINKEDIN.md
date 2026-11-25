# Sugestão de post para o LinkedIn

---

Uma query que levava segundos passou a responder em milissegundos, e o SQL "novo" retorna exatamente as mesmas linhas. ⚡

Montei um laboratório completo de tuning em Oracle para mostrar, com números, por que consultas de ERP degradam quando o volume cresce:

🔹 Ambiente 100% em Docker (Oracle Database Free + Python), subindo com um único comando
🔹 3,65 milhões de linhas: 100 mil clientes, 50 mil produtos, 1 milhão de pedidos e 2,5 milhões de itens
🔹 Gargalos propositais: sem índices em FKs, estatísticas desatualizadas, funções no WHERE
🔹 3 queries críticas de negócio (faturamento, pendências de entrega, estoque x demanda) em versão "antes" e "depois"

O que fez diferença:
✅ Filtros SARGable: trocar TRUNC(data) por intervalo de datas deixa o índice trabalhar
✅ Índices compostos "covering": a consulta é atendida sem ir à tabela
✅ DBMS_STATS: com cardinalidade correta, o otimizador escolhe um plano melhor
✅ EXISTS no lugar de IN: intenção explícita e semi-join previsível
✅ Leitura do EXPLAIN PLAN: full scan x index range scan, lado a lado

Também construí uma package PL/SQL de monitoramento (locks, sessões bloqueadoras, tablespaces e Top SQL, com log em transação autônoma) e um monitor em Python que simula uma contenção entre duas sessões e detecta o bloqueio em tempo real.

O benchmark roda sozinho: mede, aplica o tuning, mede de novo e grava o histórico no próprio banco. 📊

O que aprendi: tuning não é "criar índice e torcer". É medir, entender o plano, corrigir o predicado, atualizar estatísticas e provar o ganho com dados. No negócio, isso significa relatórios que não travam o fechamento do mês e menos custo de infraestrutura para compensar SQL ruim.

Código, README e instruções para rodar na sua máquina: [link do GitHub]

Já enfrentou uma query "que sempre foi rápida" e um dia deixou de ser? Conta nos comentários qual foi a causa. 👇

#Oracle #PLSQL #PerformanceTuning #SQL #DBA #EngenhariaDeDados #Python #Docker #BancoDeDados #DataEngineering

---

**Dica:** troque a primeira linha pelos seus números reais depois de rodar o benchmark (ex.: "De 2,4 s para 38 ms") e anexe o print da tabela comparativa como imagem do post.
