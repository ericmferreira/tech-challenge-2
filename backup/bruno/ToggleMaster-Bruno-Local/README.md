# ToggleMaster — Bruno (Docker Compose)

Collection baseada nos cinco READMEs dos microserviços.

## URLs locais
- Auth: `http://localhost:8001`
- Flag: `http://localhost:8002`
- Targeting: `http://localhost:8003`
- Evaluation: `http://localhost:8004`
- Analytics: `http://localhost:8005`

## Variáveis
- `MASTER_KEY`: chave administrativa do Auth Service.
- `TOKEN`: chave de API retornada por `POST /admin/keys`.

Execute nesta ordem: Auth health → criar TOKEN → validar TOKEN → criar flag → criar regra → avaliar usuários. Os health checks dos cinco serviços podem ser executados a qualquer momento.

O Analytics só documenta o endpoint HTTP `/health`; a validação do processamento de eventos é feita por logs e pela tabela DynamoDB.
