# Auth Service - Infraestrutura e Kubernetes (Desafio FIAP)

> ⚠️ **Aviso de Laboratório:** Este repositório é um fork criado exclusivamente para fins educacionais, como parte da resolução do desafio de fase do curso de Pós-graduação. Dados, credenciais e configurações de infraestrutura aqui presentes são destinados a um ambiente de laboratório local.

## 🎓 Contexto do Projeto
Este projeto faz parte do desafio de fase do curso **Pós Tech em DevOps e Arquitetura Cloud da FIAP**. 

O objetivo principal deste repositório foi receber uma aplicação de exemplo e desenhar, do zero, toda a esteira de conteinerização e orquestração utilizando as melhores práticas de infraestrutura moderna.

O código-fonte base é um fork do projeto original [FIAP-TCs/auth-service](https://github.com/FIAP-TCs/auth-service). As instruções de execução da aplicação nativa, documentação de requisitos e dependências do código original foram preservadas e podem ser consultadas no arquivo [README-original.md](./README-original.md).

## 🚀 Minhas Implementações

O foco do trabalho consistiu em preparar a aplicação para rodar de forma escalável e resiliente em um cluster Kubernetes. As principais entregas incluem:

* **Conteinerização:** A imagem Docker foi construída seguindo as instruções base do projeto, empacotando a aplicação e suas dependências de forma isolada.
* **Orquestração com Kubernetes:** Criação de todos os manifestos necessários (Deployments, Services, ConfigMaps, Ingress e Persistent Volume Claims) para a implantação da aplicação.
* **Automação de Tarefas:** Criação de utilitários em shell script (pasta `scripts/`) para provisionar e destruir o ambiente no cluster rapidamente.
* **Troubleshooting e Refatoração:** Durante o processo de build, realizamos manutenções pontuais no código-fonte, como a limpeza de imports não utilizados e adequações de processos, garantindo uma compilação otimizada e sem warnings.

## 🛠️ Tecnologias Utilizadas
* **Docker Desktop:** Para criação da imagem da aplicação e provisionamento do cluster Kubernetes local.
* **Kubernetes:** Orquestração dos containers nativa via Docker Desktop.
* **Shell Script:** Automação de apply/delete dos manifestos K8s.

## ⚙️ Como executar este laboratório

### Pré-requisitos
Para rodar este projeto, você precisará ter instalado em sua máquina o [Docker Desktop](https://docs.docker.com/desktop/) e garantir que a opção **"Enable Kubernetes"** esteja ativada nas configurações (*Settings > Kubernetes*). O utilitário `kubectl` já vem embutido na instalação.

### Passo a Passo

1. **Clone o repositório:**
   ```bash
   git clone <url-do-seu-fork>
   cd auth-service