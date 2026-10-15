# ToggleMaster — ambiente reproduzível em AWS EKS

Este repositório contém a aplicação e sua infraestrutura para um cluster novo do laboratório. A configuração de runtime Kubernetes tem **um único local canônico: `eks/`**. Os dois states Terraform já existentes foram mantidos: `iac-req/` é dono do SQS/DynamoDB e `iac-eks/` é dono do EKS, ECR, IAM e add-ons.

## Fluxo operacional reduzido

Após configurar uma única vez o Secret local, o caminho recomendado para criar o ambiente completo é um comando. O script valida AWS, Docker e o Secret antes de criar recursos; depois provisiona a infraestrutura, publica as imagens e implanta as aplicações:

```powershell
.\start-togglemaster.ps1
```

Pré-requisitos: AWS CLI autenticado na conta esperada, Terraform, kubectl, Docker Desktop em execução e `eks/global-files/secrets-togglemaster.yaml` preenchido com os valores reais. O arquivo de Secret nunca é incluído no ZIP. Para uma atualização limitada a uma única imagem, use `publish-images.ps1 -Services analytics-service`; isso não é necessário num start completo após destroy, pois o ECR terá sido recriado.

### 1. Infraestrutura: um comando

Na raiz do repositório, em PowerShell:

```powershell
.\provision-infrastructure.ps1
```

O script detecta o IP público atual para restringir o endpoint Kubernetes a esse `/32`; não abre o endpoint para `0.0.0.0/0`. Se a rede bloquear a consulta de IP, informe o CIDR explicitamente:

```powershell
.\provision-infrastructure.ps1 -AdminCidr "SEU_IPV4/32"
```

O bootstrap executa automaticamente os dois roots Terraform na ordem necessária. O node group mantém dois workers `m7i-flex.large`, pois um único nó chegava a 88% de CPU reservada antes da estabilização das aplicações. Isso melhora a margem para réplicas/metrics/add-ons, com custo adicional de EC2. No root `iac-eks`, o script cria VPC/EKS, configura `kubectl`, instala o AWS Load Balancer Controller e espera os endpoints do webhook ficarem prontos; só então instala os demais add-ons, incluindo KEDA. O `keda.tf` também declara a dependência entre os releases e usa `atomic = true` no KEDA. O provider Terraform Helm instala os charts; `helm.exe` não é pré-requisito. O CIDR usado para o endpoint administrativo é salvo em `.togglemaster-admin-cidr` para permitir o destroy sem pedir uma variável ausente.

### 2. Imagens: reutilize o script do projeto

Inicie o Docker Desktop e, na raiz do repositório, execute:

```powershell
.\iac-eks\scripts\publish-images.ps1
```

Por padrão, constrói e publica as cinco imagens (`auth-service`, `flag-service`, `targeting-service`, `evaluation-service`, `analytics-service`) no ECR criado pelo Terraform. Para publicar apenas um serviço: `.\iac-eks\scripts\publish-images.ps1 -Services analytics-service`. Os manifests usam a tag `latest` com `imagePullPolicy: Always`. O Analytics usa Boto3 `1.43.114` numa base Python 3.12, compatível com EKS Pod Identity; a documentação AWS exige Boto3/Botocore 1.34.41 ou posterior.

### 3. Secret: um arquivo local por ambiente

Copie o sample para o nome local ignorado pelo Git:

```powershell
Copy-Item .\eks\global-files\secrets-togglemaster-sample.yaml .\eks\global-files\secrets-togglemaster.yaml
notepad .\eks\global-files\secrets-togglemaster.yaml
```

Substitua todos os valores `CHANGE_ME` por credenciais fortes e consistentes. Se a senha PostgreSQL contiver caracteres reservados de URL (por exemplo `@`, `:`, `/`, `#` ou `?`), codifique-os percentualmente dentro da `DATABASE_URL`. Não adicione `AWS_ACCESS_KEY_ID` nem `AWS_SECRET_ACCESS_KEY`: as workloads usam EKS Pod Identity.

O arquivo local `secrets-togglemaster.yaml` está no `.gitignore`. Não versione esse arquivo nem compartilhe o conteúdo. O sample não contém credenciais válidas.

### 4. Aplicações: um comando

Na raiz do repositório:

```powershell
.\deploy-applications.ps1
```

O orquestrador:
- valida que as cinco imagens existem no ECR e configura o kubeconfig para o cluster esperado;
- cria o Secret apenas se ainda não existir, evitando sobrescrever uma chave gerada em uma execução anterior;
- aplica os ConfigMaps, PVCs, Services e Deployments do Auth/PostgreSQL, espera o Auth ficar saudável e cria/valida a chave de API usada pelo Evaluation;
- implanta Flag e Targeting, depois Redis/Evaluation, depois Analytics;
- aplica os HPAs existentes, aplica o `ScaledObject`/`TriggerAuthentication` do Analytics e aplica o ALB Ingress ao final;
- espera os recursos críticos e mostra o estado final.

O script não imprime o valor da `EVALUATION_TM_KEY`. Ao executar novamente no mesmo ambiente, mantém um Secret existente e reutiliza a chave se ela ainda for válida.

## O que é automatizado dentro do bootstrap (26 etapas documentadas)

Estas são as operações internas da infraestrutura. Elas continuam documentadas para auditoria/entendimento, mas não são 26 tarefas manuais:

1. Verificar autenticação AWS e descobrir a conta.
2. Detectar o IPv4 público administrativo ou aceitar um CIDR explícito.
3. Inicializar o state Terraform de dependências.
4. Validar o código do root `iac-req`.
5. Criar/atualizar a fila SQS `analytics-queue`.
6. Criar/atualizar a tabela DynamoDB `ToggleMasterAnalytics`.
7. Inicializar o state Terraform do EKS.
8. Formatar e validar a configuração Terraform.
9. Criar a VPC e subnets públicas.
10. Criar o cluster EKS e restringir seu endpoint público ao CIDR administrativo.
11. Criar o managed node group.
12. Habilitar EKS Pod Identity Agent junto dos add-ons básicos do EKS.
13. Criar os cinco repositórios ECR.
14. Criar a role e associação de identidade do EBS CSI.
15. Instalar o EBS CSI Driver para os PVCs PostgreSQL.
16. Criar a role/policy de IAM do AWS Load Balancer Controller.
17. Instalar o AWS Load Balancer Controller pelo provider Helm do Terraform e esperar o webhook ficar pronto.
18. Criar uma role IAM própria para leitura de métricas da SQS pelo KEDA.
19. Associar essa role ao ServiceAccount `keda/keda-operator`.
20. Instalar o KEDA pelo provider Helm do Terraform.
21. Criar a role e a associação de Pod Identity do `evaluation-service` (somente `sqs:SendMessage`).
22. Criar a role e a associação do `analytics-service` (receber/excluir mensagens da fila e `dynamodb:PutItem`).
23. Instalar o Metrics Server usado pelos HPAs de CPU.
24. Configurar `kubectl` para o cluster e aguardar os nodes ficarem `Ready`.
25. Aplicar o `StorageClass gp3` depois do EBS CSI Driver estar disponível e antes de criar PVCs.
26. Verificar o estado dos deployments de infraestrutura (EBS CSI, Metrics Server, AWS Load Balancer Controller e KEDA).

As roles do EBS CSI, KEDA, Evaluation e Analytics são declaradas no Terraform com trust policy restrita à conta e ao cluster. O KEDA tem apenas `sqs:GetQueueAttributes` e `sqs:GetQueueUrl`; o Evaluation pode enviar eventos; o Analytics pode consumir a fila e gravar na tabela. **Nenhuma dessas permissões depende da role dos nodes ou de chaves AWS estáticas em Kubernetes Secrets.**


## Destruir o laboratório com segurança

Use um único comando na raiz quando for realmente remover todo o ambiente:

```powershell
.\destroy-infrastructure.ps1
```

O script valida conta/DNS, confirma que os dois states locais existem, resolve `admin_cidr`, executa `terraform init`, `validate` e **planos de destroy antes de tocar em workloads ou PVCs**, e passa explicitamente `-var=aws_region` e `-var=admin_cidr` ao `terraform destroy`. Esse último parâmetro corrige a falha em que a versão anterior apagava Deployments/PVCs e depois parava com `No value for required variable admin_cidr`. Se o DNS falhar ou um plano não for válido, o script para antes da limpeza Kubernetes. Após a aprovação, remove primeiro o Ingress para o controller eliminar o ALB, encerra Deployments e PVCs, espera a remoção de volumes EBS e então destrói os dois states na ordem inversa: EKS/VPC/ECR/add-ons e depois SQS/DynamoDB.

Os dois providers AWS estão configurados com `max_retries = 5`, em vez do padrão de 25 tentativas. Isso reduz esperas prolongadas quando a API não pode ser alcançada por problemas de rede/DNS. **Não corrige uma conexão quebrada**: se a rede cair durante a exclusão, Terraform poderá remover parte dos recursos e falhar nos restantes. Nesse caso, restaure a conectividade e rode o mesmo comando novamente; não apague nem edite os arquivos `terraform.tfstate` manualmente.

Se a versão antiga do script já removeu Deployments/PVCs e falhou no Terraform por falta de `admin_cidr`, não precisa recriar manualmente os recursos Kubernetes. Extraia este pacote sobre o diretório de projeto existente, preservando os states, e execute `.\destroy-infrastructure.ps1` novamente: ele detectará o CIDR atual do EKS e prosseguirá com o destroy após validar os planos.

O erro `lookup ec2.us-east-2.amazonaws.com: no such host` significa falha de resolução DNS local, não uma falha de dependência de subnet do Terraform. Antes de uma nova tentativa manual, você pode confirmar a resolução com:

```powershell
Resolve-DnsName ec2.us-east-2.amazonaws.com
Test-NetConnection ec2.us-east-2.amazonaws.com -Port 443
aws sts get-caller-identity
```

O destroy remove também o ALB, os volumes persistentes e os dados dos bancos, além de imagens/repositórios ECR, SQS e DynamoDB. Execute somente quando quiser descartar o ambiente e seus dados. O pacote não inclui `terraform.tfstate`, `terraform.tfvars` nem o Secret real; extraia os arquivos sobre o checkout existente, preservando esses arquivos locais.

## Organização canônica

- `iac-req/`: fila SQS e tabela DynamoDB (state preexistente preservado).
- `iac-eks/`: VPC, EKS, node group, ECR, IAM, Pod Identity, EBS CSI, Metrics Server, KEDA e AWS Load Balancer Controller.
- `eks/`: manifests ativos de ConfigMaps, Secrets de exemplo, PVCs, Deployments, Services, HPAs, ScaledObject e ALB Ingress.
- `src/`: código e Dockerfiles das cinco aplicações.
- `start-togglemaster.ps1`: orquestrador de ponta a ponta para provisionamento, publicação de imagens e implantação.
- `provision-infrastructure.ps1`: entry point da infraestrutura.
- `deploy-applications.ps1`: entry point de validação/deploy das aplicações.
- `iac-eks/scripts/publish-images.ps1`: publicação das cinco imagens por padrão, ou somente dos serviços listados em `-Services`.

O `k8s/` antigo e os scripts manuais de instalação/patch não são mais o caminho de deploy. A pasta `eks/` é a fonte única dos manifests usados pelo orquestrador.

## Verificação após o deploy

```powershell
kubectl get nodes
kubectl get pods -A
kubectl get pvc -n default
kubectl get hpa -n default
kubectl get scaledobject,triggerauthentication -n default
kubectl get ingress -n default
```

Para validar o KEDA, coloque carga pelo fluxo real de Evaluation (o arquivo `eks/load-test-togglemaster.py` chama `/evaluation/evaluate`) e acompanhe:

```powershell
kubectl get hpa analytics-service-hpa -n default -w
kubectl get deployment analytics-service-app -n default -w
```

O `ScaledObject` do Analytics gerencia o HPA existente chamado `analytics-service-hpa`; não há um segundo manifesto HPA de CPU competindo pelo mesmo Deployment.

## Estados locais, migração e segurança

O ZIP de entrega **não inclui** `terraform.tfstate`, backups de state, `.terraform/`, `*.tfplan`, `terraform.tfvars`, `.togglemaster-admin-cidr` nem o Secret real. Isso evita distribuir estado/cache local ou informações específicas do ambiente.

Antes de substituir os arquivos no seu checkout, faça backup e preserve os arquivos locais necessários para continuar gerenciando recursos já criados:
- `iac-req/terraform.tfstate` e `iac-eks/terraform.tfstate` (e backups, se precisar);
- seus `terraform.tfvars` locais;
- `.togglemaster-admin-cidr`, se já criado;
- `eks/global-files/secrets-togglemaster.yaml`, se já contém credenciais válidas.

Extraia/integre os arquivos do pacote sobre o diretório de projeto existente para conservar esses arquivos ignorados. Não inicialize um checkout sem state apontando para recursos que ainda existem na AWS; nesse caso o Terraform pode tentar criar SQS/DynamoDB/recursos com nomes já ocupados. Em qualquer operação de destroy/recreate, use primeiro a configuração que corresponde ao state existente e revise o plano antes de confirmar.

Na migração, remova as cópias antigas que já existiam no seu checkout:
- a pasta raiz `k8s/` (manifests antigos com `:latest` local e Ingress NGINX);
- `src/auth-service/k8s/` (manifestos antigos que não fazem parte do deploy canônico);
- `iac-eks/k8s-aws/`;
- os scripts antigos `iac-eks/scripts/install-keda-sqs.ps1`, `install-lab-addons.ps1` e `patch-k8s-manifests.ps1`;
- `eks/keda-sqs-policy.json` (substituído pelo IAM declarado no Terraform).

Antes de executar o bootstrap, confira que `aws sts get-caller-identity` retorna a conta AWS esperada. O Terraform pode criar recursos cobrados: EKS control plane, EC2, EBS, ECR, endereço público, ALB e tráfego. O ECR está configurado como recurso descartável com `force_delete = true`; não use `terraform destroy` sem confirmar que realmente deseja remover imagens e infraestrutura.
