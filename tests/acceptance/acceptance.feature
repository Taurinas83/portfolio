Feature: Agente Assessor Pessoal (ADHD-Focused PWA)
  Como um usuário com TDAH
  Quero que meus compromissos e tarefas sejam organizados automaticamente
  Para que eu não perca prazos importantes devido a dificuldades de organização

  Background:
    Given o usuário está autenticado via OAuth2 PKCE
    And o consentimento LGPD foi registrado para "google_calendar_sync" e "ai_processing"
    And o perfil TDAH está ativo com buffer de 15min e foco de 45min

  @FR-01 @sync @critical
  Scenario: Sync bidirecional Google Calendar com resolução de conflitos
    Given existem 3 eventos locais no IndexedDB
    And existem 2 eventos remotos no Google Calendar com sobreposição de horário
    When o sistema executa sync delta via webhook
    Then os eventos são mesclados usando estratégia "last_write_wins"
    And o log de auditoria registra "conflict_resolved" com timestamp UTC
    And a latência P95 do sync não excede 300ms
    And o status do sync é atualizado para "synced" em < 5s

  @FR-01 @sync
  Scenario: Sync Google Tasks com atualização de status
    Given o usuário possui 5 tarefas pendentes no Google Tasks
    When uma tarefa é marcada como "completed" remotamente
    And o sync delta é processado
    Then a tarefa local é atualizada para status "completed"
    And a prioridade é recalculada pelo agente IA
    And o sync_token é atualizado para próximo delta

  @FR-02 @intelligence @ai
  Scenario: Priorização IA com contexto TDAH - deadline iminente
    Given o usuário possui 5 tarefas pendentes
    And uma tarefa tem deadline em < 2 horas
    When o agente processa via LLM proxy com contexto TDAH
    Then a tarefa com deadline < 2h recebe prioridade "crítica" (score 10)
    And o JSON de resposta contém "reason_code": "time_pressure"
    And o custo da inferência é logado em "ai_metering" com modelo usado
    And as demais tarefas são reordenadas conforme novo contexto

  @FR-02 @intelligence @ai
  Scenario: Priorização IA com agrupamento por contexto
    Given o usuário possui tarefas de diferentes contextos ("casa", "trabalho", "estudo")
    When o agente processa triagem com "context_grouping": true
    Then tarefas do mesmo contexto são agrupadas sequencialmente
    And buffers de transição são inseridos entre mudanças de contexto
    And o motivo "context_match" é registrado no reason_code

  @FR-02 @intelligence @fallback
  Scenario: Fallback heurístico quando AI provider indisponível
    Given o AI provider retorna erro 503
    When o sistema tenta triagem de tarefas
    Then o fallback heurístico é ativado
    And a priorização usa regras baseadas em deadline e peso configurado
    And "fallback_used": true é registrado no metadata
    And o usuário não percebe interrupção no serviço

  @FR-03 @notification @adhd
  Scenario: Alerta escalonado com compromisso em 30 minutos
    Given um compromisso está agendado para daqui 30 minutos
    And o dispositivo está online
    When o service worker dispara notificação push
    Then a notificação é exibida com título e corpo descritivos
    And o som ADHD-optimized é reproduzido (padrão variado)
    And o delivery ocorre em < 5s (SLA 95%)

  @FR-03 @notification @offline
  Scenario: Notificação offline com fila local e retry
    Given um compromisso está agendado para daqui 30 minutos
    And o dispositivo está sem conectividade (offline)
    When o service worker dispara notificação local
    Then a notificação é exibida imediatamente via Web Push API local
    And a notificação é enfileirada no IndexedDB para sync posterior
    And ao reconectar, o sistema tenta push remoto com retry exponencial
    And o backoff segue padrão: 1m, 5m, 15m, 1h
    And o SLA de delivery é mantido em < 95%

  @FR-03 @notification @escalation
  Scenario: Escalonamento completo (push → som → email)
    Given um compromisso crítico em 1 hora
    And o usuário não interagiu com a notificação inicial
    When passam-se 5 minutos sem resposta
    Then o nível de escalonamento sobe para "sound"
    And um som mais alto é reproduzido
    When passam-se 15 minutos totais sem resposta
    Then o nível de escalonamento sobe para "email"
    And um email de fallback é enviado
    And cada nível é registrado no audit trail

  @FR-04 @compliance @lgpd
  Scenario: Direito ao esquecimento (LGPD/GDPR Art. 18/17)
    Given o usuário solicita deleção via DELETE /api/v1/compliance/erase
    And o consentimento foi validado previamente
    When o job de limpeza é executado
    Then todos os dados PII são criptografados com chave efêmera
    And o índice é removido em ≤ 7 dias (SLA regulatório)
    And um webhook de confirmação é disparado
    And o audit trail registra "data_erased" com job_id
    And o usuário recebe email de confirmação

  @FR-04 @compliance @gdpr
  Scenario: Exportação de dados (LGPD/GDPR Art. 20)
    Given o usuário solicita export via POST /api/v1/compliance/export
    And o formato solicitado é "json" com audit trail
    When a exportação é processada
    Then um arquivo JSON contendo todos os dados é gerado
    And uma URL temporária válida por 24h é retornada
    And o arquivo inclui events, tasks, consents e audit_trail
    And o download_url é retornado no response

  @FR-04 @compliance
  Scenario: Gestão de consentimentos explícitos
    Given o usuário acessa a tela de configurações pela primeira vez
    When concede consentimento para "google_calendar_sync"
    Then o consentimento é registrado com timestamp e IP
    And a versão do termo é registrada
    And o usuário pode retirar o consentimento a qualquer momento
    And a retirada é registrada com "withdrawn_at" timestamp

  @NFR-01 @performance
  Scenario: Latência P95 da API < 300ms
    Given 100 requisições consecutivas ao endpoint /api/v1/sync/calendar
    When as requisições são processadas
    Then a latência P95 não excede 300ms
    And a latência média é < 150ms
    And métricas são enviadas para OpenTelemetry

  @NFR-02 @reliability
  Scenario: Sync convergence < 5s após reconnect
    Given o dispositivo ficou offline por 10 minutos
    When a conexão é restabelecida
    And o sync delta é iniciado
    Then a convergência completa ocorre em < 5s
    And RPO ≤ 5min (nenhum dado perdido além de 5min)
    And RTO ≤ 15min (serviço restaurado em 15min)

  @NFR-03 @pwa
  Scenario: Service Worker cache hit > 85%
    Given o usuário acessa a PWA pela segunda vez
    When os recursos são carregados
    Then o cache hit do Service Worker é > 85%
    And First Contentful Paint < 1.2s
    And Lighthouse score > 90 em Performance

  @security @owasp
  Scenario: Proteção contra XSS via CSP strict-dynamic
    Given um atacante injeta script malicioso via campo de descrição de evento
    When o evento é renderizado na PWA
    Then o CSP header bloqueia execução de scripts não autorizados
    E apenas scripts com nonce válido são executados
    E o ataque é registrado no security log

  @security @auth
  Scenario: Refresh token rotation (max 30 dias)
    Given o usuário autenticou há 29 dias
    When o access token expira
    Then o refresh token é usado para obter novo par de tokens
    And o refresh token antigo é invalidado (rotation)
    And após 30 dias, o usuário deve reautenticar

  @security @rate-limit
  Scenario: Rate limiting por IP/token (100 req/min)
    Given um cliente faz 101 requisições em 1 minuto
    When a 101ª requisição chega
    Then o servidor retorna HTTP 429 Too Many Requests
    And o header Retry-After indica quando retry é permitido
    And a requisição é logada para análise de abuso

  @metering @billing
  Scenario: Metering de chamadas AI para billing
    Given o usuário está no tier "free_mvp"
    And o limite mensal é 100 ai_triage_runs
    When o usuário executa a 100ª triagem do mês
    Then o uso é registrado em /api/v1/metering/usage
    And o contador "ai_triage_runs" é incrementado
    When o usuário tenta a 101ª triagem
    Then o sistema retorna erro de quota excedida
    And sugere upgrade para "pro_ai_scheduling"

  @feature-flags @upsell
  Scenario: Feature flag habilita upsell sem deploy
    Given o usuário está no tier "free_mvp"
    And a feature flag "ai_scheduling" está desabilitada para free
    When o usuário faz upgrade para "pro_ai_scheduling"
    Then a feature flag é atualizada via Stripe webhook
    And o usuário ganha acesso imediato a "ai_scheduling"
    And não há necessidade de deploy ou restart

  @integration @google-oauth
  Scenario: Fluxo OAuth2 PKCE completo
    Given o usuário clica em "Conectar com Google"
    When é redirecionado para Google OAuth consent screen
    And concede permissões para Calendar e Tasks
    Then o código de autorização é recebido no callback
    And o code_verifier é validado (PKCE)
    And o access token e refresh token são armazenados criptografados
    And o usuário é redirecionado para a PWA autenticado

  @offline-first @indexeddb
  Scenario: Offline-first com IndexedDB encryptado
    Given o usuário cria um evento enquanto offline
    When o evento é salvo no IndexedDB
    Then os dados são criptografados com Web Crypto AES-GCM
    And a operação de escrita é enfileirada para sync
    And ao reconectar, a fila é processada em ordem
    And o sync com Google Calendar é realizado

  @adhhd-specific @buffer
  Scenario: Buffer de transição entre compromissos
    Given o usuário tem buffer_minutes configurado como 15
    And existe um evento das 14:00 às 15:00
    And existe outro evento das 15:00 às 16:00
    When o agente analisa a agenda
    Then um buffer de 15min é inserido automaticamente entre os eventos
    And o segundo evento é marcado como "precisa de buffer"
    And o usuário é notificado sobre o ajuste

  @adhhd-specific @focus-block
  Scenario: Blocos de foco com limite de tarefas
    Given o usuário tem focus_block_minutes = 45
    And max_tasks_per_block = 3
    When o agente agenda tarefas para um bloco de foco
    Então no máximo 3 tarefas são agendadas no bloco de 45min
    E uma pausa é sugerida após o bloco
    E o break_frequency_minutes (90min) é respeitado
