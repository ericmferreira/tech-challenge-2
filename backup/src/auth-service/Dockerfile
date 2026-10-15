FROM golang:1.23-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# 1. Copia os arquivos originais (intocados) para o container
COPY . .

# 2. Patch de Infraestrutura (Resolve os erros de compilação em tempo de build)
# - Corrige a versão do driver no go.mod
# - Remove os imports não utilizados apontados pelo compilador
# - Adiciona o blank identifier (_) no driver do Postgres no main.go para habilitar a conexão
RUN sed -i 's|github.com/jackc/pgx/v4/stdlib|github.com/jackc/pgx/v4|g' go.mod && \
    sed -i '/"crypto\/sha256"/d' handlers.go && \
    sed -i '/"encoding\/hex"/d' handlers.go && \
    sed -i '/"fmt"/d' key.go && \
    sed -i '/"fmt"/d' main.go && \
    sed -i 's|"github.com/jackc/pgx/v4/stdlib"|_ "github.com/jackc/pgx/v4/stdlib"|g' main.go

# 3. Baixa as dependências com o go.mod já corrigido
RUN go mod tidy && go mod download

# 4. Compila o binário estático
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/server .

# --- Runtime ---
# Usando alpine em vez de scratch para permitir debug via terminal se necessário no desafio
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

# Copia apenas o executável final
COPY --from=builder /app/server /app/server

# Porta esperada pela aplicação
EXPOSE 8001

ENTRYPOINT ["/app/server"]