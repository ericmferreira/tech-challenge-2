FROM golang:1.21-alpine AS builder

WORKDIR /app

COPY . .

RUN go mod tidy && go mod download

# Removendo o pacote context e adicionando o pacote os para evitar conflitos de importação
RUN sed -i 's|"context"|"os"|g' evaluator.go

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app/server .

# --- Runtime ---
FROM alpine:3.20

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app

# Copia apenas o executável final
COPY --from=builder /app/server /app/server

# Porta esperada pela aplicação
EXPOSE 8001

ENTRYPOINT ["/app/server"]
