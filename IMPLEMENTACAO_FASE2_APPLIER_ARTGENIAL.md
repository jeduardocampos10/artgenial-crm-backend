# Implementação ArtGenial — Fase 2: aplicação segura do Base v1

## 1. Arquivos criados

- `app/services/artgenial/templates/applier.rb`
- `spec/services/artgenial/templates/applier_spec.rb`
- `IMPLEMENTACAO_FASE2_APPLIER_ARTGENIAL.md` (este relatório local, **não rastreado** e fora do commit)

## 2. Arquivos modificados

Nenhum arquivo existente foi modificado. `config/artgenial/templates/base/v1.yml`, os serviços e as proteções da Fase 1, models, migrations, Rake tasks e frontend permaneceram intactos.

## 3. Interface final do Applier

```ruby
manifest = Artgenial::Templates::Loader.new.load(template_key: 'artgenial.base', version: '1')
result = Artgenial::Templates::Applier.new(
  installation_key: 'UUID explícito da instalação',
  manifest: manifest,
  actor: user_persistido
).call
```

`result` contém `status` (`:applied` ou `:already_applied`), `installation` e `plan`. O serviço aceita somente o manifesto Base v1 com o checksum publicado. Exige `installation_key` UUID e `User` persistido; não busca actor implícito nem inventa identidade de instalação. Evidência: `app/services/artgenial/templates/applier.rb`.

## 4. Transação

`ArtgenialTemplateInstallation.transaction` envolve o bloqueio da tabela `pipelines`, a consulta ao `Planner`, a criação dos 6 pipelines, 62 stages, 29 labels, 97 componentes do ledger e a instalação do ledger. A instalação passa de `applying` para `applied` com `installed_at` **dentro da mesma transação**. Exceções antes do commit revertem todas essas escritas. O lock PostgreSQL `SHARE ROW EXCLUSIVE` serializa gravações de pipeline durante a aplicação, para que o callback existente de default não desative um pipeline externo criado simultaneamente. Evidências: `app/services/artgenial/templates/applier.rb` e `app/models/pipeline.rb`.

## 5. Collision e blocked

O Applier chama `Artgenial::Templates::Planner` antes de criar registros. Ações `collision` e `blocked` causam `UnsafePlan`; o plano precisa corresponder exatamente aos componentes do manifesto. Para instalação nova, todas as ações devem ser `create`. Um default já existente também aborta antes da escrita, pois o callback de `Pipeline` desativaria esse registro externo. Não há adoção por nome, sufixo automático, renomeação, exclusão nem atualização de dados externos. Evidências: `app/services/artgenial/templates/planner.rb`, `applier.rb`, `app/models/pipeline.rb`.

## 6. Idempotência

A combinação `installation_key` + `template_key` + `template_version` identifica a aplicação; checksum diferente é rejeitado. Uma aplicação já `applied`, com ledger completo e componentes vinculados a registros reais, retorna `:already_applied` sem escrita. Ações `preserve` do Planner permitem customizações posteriores sem sobrescrevê-las; `noop` também é aceito. Ledger incompleto, componente sem vínculo e estados intermediários não são adotados nem completados automaticamente. Os índices únicos da migration da Fase 1 continuam como proteção adicional. Evidências: `app/services/artgenial/templates/applier.rb`, `db/migrate/20261022120000_create_artgenial_template_ledgers.rb`.

## 7. Ledger gravado

`ArtgenialTemplateInstallation`: UUID lógico explícito, `artgenial.base`, versão `1`, checksum aprovado, `status: applied`, `installed_at` e `metadata.actor_id`. Cada `ArtgenialTemplateComponent` guarda `component_type`, `component_key` estável, `record_type`, UUID real em `record_id`, `status: applied` e `last_applied_state` extraído dos atributos efetivamente persistidos, sem ID nem timestamps. O componente de label guarda a categoria do manifesto em `metadata.category`, sem alterar o model `Label`. Evidência: `app/services/artgenial/templates/applier.rb`.

## 8. Rollback

O spec força falha em `Label.create!` depois da criação dos pipelines e stages. Ele verifica que as contagens de Pipeline, PipelineStage, Label e dos dois ledgers voltam aos valores anteriores. **Execução deste spec está pendente** por falta de Ruby/Bundler local. Não houve tentativa de executar contra banco DEV remoto ou produção. Evidência: `spec/services/artgenial/templates/applier_spec.rb`.

## 9. Testes criados

`spec/services/artgenial/templates/applier_spec.rb` contém 16 exemplos: instalação limpa 6/62/29; instalação e 97 componentes do ledger; IDs, tipos e estado aplicado; atributos do manifesto; default e stage types; reaplicação sem escrita; preservação de stage renomeado; colisões de pipeline e label; ação blocked; default externo; registros externos preservados; rollback; UUID e actor inválidos; checksum/versão divergentes; ledger incompleto e vínculo ausente.

## 10. Testes executados e resultados

Tentado: `bundle exec rspec spec/services/artgenial/templates/applier_spec.rb spec/services/artgenial/templates/planner_spec.rb`. **Não iniciou:** PowerShell retornou `bundle: CommandNotFoundException`. Nenhum exemplo RSpec foi executado ou aprovado.

Verificações estáticas concluídas: apenas os dois arquivos novos entraram no commit; sem whitespace no fim de linha, com newline final e linhas até 150 caracteres; varredura de padrões de segredos sem achados; `git diff --cached --check` sem erro; manifesto sem diff. Um parser restrito de leitura, usando somente biblioteca padrão Python, confirmou 6 pipelines, 62 stages e 29 labels e reproduziu o checksum abaixo. Ele não substitui a execução de `Loader`, RSpec ou RuboCop no runtime Rails.

## 11. Limitações encontradas

- Ruby/Bundler e RuboCop não estão disponíveis neste Windows; testes e lint Ruby permanecem pendentes no container de homologação.
- O serviço é restrito ao Base v1 publicado. Não aplica segmentos, não atualiza v2 e não reconcilia diferenças.
- A aplicação exige actor e UUID fornecidos pelo chamador. Não foi adicionada Rake task `apply`, para não criar uma interface operacional de escrita sem autenticação e parâmetros controlados.
- O lock de tabela bloqueia gravações concorrentes em `pipelines` enquanto durar a transação; a duração e os callbacks de `Label` após commit devem ser observados na validação em homologação. Eventos externos emitidos após o commit não integram o rollback do banco.

## 12. Commit local

`2ca6fb270dc9ab0aa968219f9b9be9361df32ee0` — `feat: adiciona aplicacao segura dos templates ArtGenial` (somente os dois arquivos de código/spec).

## 13. `git status --short`

Após criar este relatório, esperado: `?? IMPLEMENTACAO_FASE2_APPLIER_ARTGENIAL.md`. Nenhum outro arquivo do backend alterado ou staged. A raiz pode mostrar o submódulo como modificado por avanço local do HEAD; o gitlink da raiz não foi adicionado nem commitado nesta tarefa.

## 14. Push

**NÃO houve push.** O commit existe somente no backend local.

## 15. Deploy

**NÃO houve deploy** nem alteração de produção ou Coolify.

## 16. Base v1

O manifesto permanece com **6 pipelines, 62 stages e 29 labels**. `sales` é o único default; `ganho = completed`, `perdido = cancelled`, `abandono_30_plus = active`. Nenhuma label ou stage foi adicionada, removida ou alterada. Evidência: `config/artgenial/templates/base/v1.yml`, sem diff no commit da Fase 2.

## 17. Checksum final

`1c22c7dc607ee0a1519c2a508affc776b570f12d9ddb8051e504d1240c0b20ad`. Igual ao checksum aprovado; reproduzido por leitura estática do manifesto com a canonicalização das chaves e ordem de arrays do serviço `app/services/artgenial/templates/checksum.rb`.
