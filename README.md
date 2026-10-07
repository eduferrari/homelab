# Homelab — ThinkPad L14

Provisionamento do ThinkPad L14 como servidor, **a partir de uma instalação limpa do Ubuntu Server**: Ubuntu endurecido, **stack de dados** (MySQL, Redis, RabbitMQ) em Docker, **proxy Traefik** com HTTPS na LAN (CA própria) e domínios públicos (Let's Encrypt), e projetos em Docker Compose com **deploy pelo GitHub Actions**.

---

## 1. Visão geral

| Camada | Componente | Porta | Acesso |
|---|---|---|---|
| Projetos | **Proxy do homelab** (Traefik v3, `proxy.sh`) | 80, 443 (+ portas extras da LAN) | apps e domínios |
| Projetos | Projetos em Docker Compose | — | `/opt/homelab/apps/<projeto>` |
| Painéis | **Painel geral**, logs (Dozzle), tráfego (GoAccess), status (Uptime Kuma), Seq | 9440, 9443, 9444, 9445, 9446 | `https://<host>:<porta>` (seção 7.6) |
| Dados | MySQL 8.4 | 3306 | clientes MySQL / apps |
| Dados | Adminer | **8088** | `http://<host>:8088` |
| Dados | Redis 7 | 6379 | clientes Redis / apps |
| Dados | RedisInsight | 5540 | `http://<host>:5540` |
| Dados | RabbitMQ 4 (AMQP / Management) | 5672 / 15672 | `http://<host>:15672` |
| Host | SSH | 22 | `ssh <usuario>@<host>` |

`<host>` é o nome mDNS do L14 — `homelab.local` — ou o IP fixo da LAN.

- A stack de dados fica em `/opt/homelab/infra` (compose `homelab`, rede `devnet`, volumes persistentes).
- Tudo que roda em container é acessível **somente pela LAN** (seção 9.2). Para a internet, apenas 80/443 do proxy, quando você ativar (seção 9.4).
- HTTPS na LAN (nome `.local` **e** IP — inclusive tablets que acessam pelo IP) usa a **CA do homelab** (seção 8).

---

## 2. Pré-requisitos

1. **Ubuntu Server 24.04 LTS** instalado no L14 (22.04 também funciona; Ubuntu Desktop funciona, mas o script muda o boot para modo texto).
   - Na instalação, marque **"Install OpenSSH server"**.
2. Um usuário comum com `sudo` (o que você criou na instalação).
3. Hardware: **2 núcleos e 4 GB de RAM** (stack de dados + projetos), **30 GB de disco** livres.
4. **Conexão por cabo de rede** (recomendado; Wi-Fi funciona, mas é menos estável). O script ativa mDNS (`<hostname>.local`); para IP fixo na LAN use `network-static.sh` depois da instalação (seção 9.3).
5. Notebook ligado na tomada.

### BIOS do ThinkPad (recomendado)

Pressione **F1** no boot:

| Opção | Valor |
|---|---|
| Config → Power → *After Power Loss* | **Power On** (liga sozinho após queda de energia) |
| Security → Virtualization → Intel VT-x / AMD-V | **Enabled** |
| Startup → Boot Mode | UEFI |

---

## 3. Antes de rodar: chave SSH (recomendado)

No seu computador principal (macOS/Linux):

```bash
ssh-keygen -t ed25519 -C "usuario@homelab"   # se ainda não tiver chave
ssh-copy-id <usuario>@<IP-do-L14>
```

Com a chave copiada **antes** do script, ele desativa automaticamente o login por senha no SSH (`DISABLE_SSH_PASSWORD=auto`).

---

## 4. Instalação

No L14:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/eduferrari/homelab.git
cd homelab
sudo ./homelab-setup.sh
sudo reboot        # na primeira instalação
```

> Pensado para uma máquina **recém-instalada** (seção 13 tem o roteiro completo). O setup precisa da pasta `scripts/` do repositório — rode sempre a partir do clone. É **idempotente**: pode rodar de novo a qualquer momento (preserva `.env`, senhas, volumes e a CA). Para atualizar: `git pull && sudo ./homelab-setup.sh`.

### Opções (variáveis de ambiente)

```bash
sudo PUBLIC_IP=203.0.113.10 ./homelab-setup.sh
```

| Variável | Padrão | Descrição |
|---|---|---|
| `HOMELAB_USER` | usuário que chamou o `sudo` | Dono dos arquivos e usuário do SSH |
| `HOMELAB_DIR` | `/opt/homelab` | Raiz da infraestrutura |
| `TIMEZONE` | `America/Sao_Paulo` | Fuso do sistema e containers |
| `DOCKER_NETWORK` | `devnet` | Rede Docker da stack de dados |
| `SSH_PORT` / `DISABLE_SSH_PASSWORD` | `22` / `auto` | SSH; `auto` desliga senha se já houver chave |
| `INSTALL_PROXY` | `true` | Sobe o proxy Traefik do homelab (se 80 e 443 estiverem livres) |
| `INSTALL_MONITOR` | `true` | Painel geral e painéis de logs, tráfego, status e Seq (seção 7.6) |
| `PUBLIC_IP` | — | IP público fixo do provedor (registrado no `.env`, informativo) |
| `CA_IMPORT_DIR` | — | Pasta com `root.crt` e `root.key` de uma CA existente; sem ela, uma CA nova é criada |
| `HEADLESS` | `true` | Desativa o boot gráfico |
| `INSTALL_TLP` / `BATTERY_*_THRESHOLD` | `true` / `75`–`80` | Limite de carga da bateria |
| `CONSOLE_BLANK_SECONDS` | `60` | Desliga a tela do console |
| `PREPARE_GH_RUNNER` | `true` | Prepara o runner self-hosted do GitHub Actions |

---

## 5. O que o script faz

| # | Etapa | Detalhes |
|---|---|---|
| 1 | Sistema base | Atualizações, pacotes (git, jq, htop, tcpdump, netcat, rsync…), mDNS (`avahi`, só IPv4), timezone, atualizações de segurança automáticas, `sysctl` |
| 2 | Modo servidor | Boot em modo texto |
| 3 | Tampa / energia | Tampa ignorada, suspensão bloqueada, TLP (bateria 75–80%) |
| 4 | SSH | Senha desligada se houver chave, fail2ban (LAN nunca é banida), **root bloqueado** |
| 5 | Docker | Docker CE + Compose; `daemon.json` com logs rotativos, `live-restore` e pool `10.0.0.0/8` (redes /24) |
| 6 | Firewall | UFW: entrada negada, SSH com rate-limit, mDNS na LAN; containers **só para redes privadas** |
| 7 | Estrutura | Diretórios e `/etc/homelab.conf` (lido pelos scripts) |
| 8 | Rede | `docker network create devnet` |
| 9 | Stack de dados | `.env` com senhas aleatórias, `docker-compose.yml`, `my.cnf` |
| 10 | Subida | `docker compose up --wait` |
| 11 | Utilitários | `scripts/*.sh` → `/opt/homelab/scripts`; timers de backup (diário) e de renovação do certificado da LAN (semanal) |
| 12 | Proxy, CA e painéis | Traefik do homelab (`proxy.sh apply`, com log de acesso); CA do homelab criada (ou importada) e certificado da LAN no proxy; painéis (`monitor.sh apply`) |
| 13 | GitHub Actions | Usuário `gh-runner` e runner baixado (registro manual com token) |

---

## 6. Estrutura

```text
/opt/homelab/
├── infra/                      # stack de dados
│   ├── docker-compose.yml
│   ├── .env                    # credenciais (640 — NÃO versionar)
│   └── mysql/{conf.d,init}/
├── ca/                         # CA do homelab + certificado da LAN (700, root)
├── apps/<projeto>/             # compose, .env e rotas públicas de cada projeto
├── proxy/                      # Traefik: proxy.conf, compose gerado, dynamic/, certs/, acme/, logs/
├── monitor/                    # painéis: monitor.conf, .env (senha), painel/ (página gerada), dados do Dozzle, GoAccess, Uptime Kuma e Seq
├── backups/                    # backups diários (750 root:<seu grupo>) + last-status.json (resultado do último)
└── scripts/
    ├── status.sh               # visão geral
    ├── proxy.sh                # proxy Traefik (portas, Let's Encrypt, versão, migração do Coolify)
    ├── monitor.sh              # painéis de logs, tráfego, status e Seq
    ├── painel.sh               # gera o painel geral (timer a cada minuto)
    ├── homelab-ca.sh           # CA e HTTPS na LAN
    ├── backup.sh / restore.sh  # backup e restauração
    ├── backup-disk-setup.sh    # prepara o SSD externo
    ├── network-static.sh       # IP fixo na LAN
    ├── public-access.sh        # libera 80/443 para a internet
    ├── public-route.sh         # publica serviços de um compose por domínio (labels Traefik)
    ├── seq-app.sh              # liga um serviço ao Seq (rede, variáveis, chave no .env, teste)
    └── register-runner.sh      # registra o runner do GitHub

/etc/homelab.conf               # configuração lida pelos scripts
/var/log/homelab-setup.log
/var/log/homelab/backup.log     # log dos backups (rotação semanal, 8 semanas)
```

Repositório:

```text
homelab-setup.sh                # provisionamento
scripts/                        # utilitários instalados em /opt/homelab/scripts
```

---

## 7. Projetos — proxy, rotas e deploy

Cada projeto roda em **Docker Compose próprio** em `/opt/homelab/apps/<projeto>`. O código fica no GitHub; no servidor ficam só o `docker-compose.yml`, o `.env` (segredos) e as rotas públicas geradas pelo `public-route.sh`. O **proxy do homelab** (Traefik v3) recebe as conexões e encaminha para os containers pelas **labels** de cada serviço.

```text
LAN  (nome .local / IP, portas 443 e extras) ─┐
                                              ├─► Traefik (proxy.sh) ─► containers dos projetos (rede "proxy")
Internet (domínio, 80/443, Let's Encrypt) ────┘                          └─► MySQL/Redis/RabbitMQ (rede "devnet")
```

### 7.1 Proxy (Traefik) — `proxy.sh`

```bash
sudo /opt/homelab/scripts/proxy.sh                         # status (versão, portas, certificados)
sudo /opt/homelab/scripts/proxy.sh entrypoint add pdv 8081 # porta extra na LAN (labels: entrypoints=pdv)
sudo /opt/homelab/scripts/proxy.sh entrypoint remove pdv
sudo /opt/homelab/scripts/proxy.sh acme tls                # Let's Encrypt pela 443 (padrão) | acme http (porta 80)
sudo /opt/homelab/scripts/proxy.sh image traefik:v3.7      # atualiza o Traefik
sudo /opt/homelab/scripts/proxy.sh logs                    # erros e ACME dos últimos 30 min
sudo /opt/homelab/scripts/proxy.sh apply                   # aplica proxy.conf editado à mão
```

| Arquivo (`/opt/homelab/proxy/`) | Conteúdo |
|---|---|
| `proxy.conf` | Configuração: imagem, rede, portas extras (`PROXY_ENTRYPOINTS`), desafio do Let's Encrypt, e-mail |
| `docker-compose.yml` | **Gerado** pelo `proxy.sh` — não edite |
| `dynamic/` | Configuração dinâmica (certificado e middlewares da LAN gerados pelo `homelab-ca.sh`; rotas em arquivo, se houver) |
| `certs/` | Certificado da LAN (CA do homelab) |
| `acme/acme.json` | Certificados Let's Encrypt (600) |

- Container `traefik`, rede Docker `proxy`. Painel/API do Traefik desligados: nada além de 80, 443 e as portas extras.
- Toda alteração passa por validação; se o proxy não ficar saudável, a configuração anterior volta sozinha.
- O `homelab-setup.sh` roda o `apply` na etapa 12.

### 7.2 Estrutura de um projeto

`/opt/homelab/apps/minhaapi/docker-compose.yml`:

```yaml
services:
  api:
    image: ghcr.io/eduferrari/minhaapi-api:latest    # imagem publicada pelo GitHub Actions (7.5)
    restart: unless-stopped
    env_file: .env
    environment:
      ASPNETCORE_ENVIRONMENT: Production
      ASPNETCORE_FORWARDEDHEADERS_ENABLED: "true"     # atrás do Traefik: esquema/IP reais do cliente
    networks: [default, proxy, devnet]
    labels:
      - traefik.enable=true
      - traefik.docker.network=proxy
      # LAN: https://homelab.local e https://<IP> (certificado da CA do homelab)
      - traefik.http.routers.minhaapi.entrypoints=https
      - traefik.http.routers.minhaapi.rule=Host(`homelab.local`) || Host(`192.168.1.10`)
      - traefik.http.routers.minhaapi.tls=true
      - traefik.http.routers.minhaapi.middlewares=homelab-lan-only@file
      - traefik.http.routers.minhaapi.service=minhaapi
      - traefik.http.services.minhaapi.loadbalancer.server.port=8080

networks:
  proxy:
    external: true
  devnet:
    external: true      # MySQL, Redis e RabbitMQ pelo nome: mysql, redis, rabbitmq
```

`.env` do projeto (no servidor, nunca no Git):

```text
ConnectionStrings__Default=Server=mysql;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis__Configuration=redis:6379,password=<REDIS_PASSWORD>
RabbitMQ__Uri=amqp://admin:<RABBITMQ_DEFAULT_PASS>@rabbitmq:5672/
```

Dockerfile de referência (.NET 8, multi-stage — imagens .NET 8+ escutam na **8080**):

```dockerfile
# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY *.sln ./
COPY src/ ./src/
RUN dotnet restore src/Api/Api.csproj
RUN dotnet publish src/Api/Api.csproj -c Release -o /app --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app .
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "Api.dll"]
```

> A imagem `aspnet` não tem `curl`. Se usar `HEALTHCHECK`, instale-o: container *unhealthy* é ignorado pelo Traefik (`no available server`).

### 7.3 Rotas na LAN

- **Pelo nome e pelo IP na 443:** entrypoint `https` com ``Host(`homelab.local`) || Host(`192.168.1.10`)`` (exemplo acima). Acessos pelo IP não enviam SNI e recebem o certificado padrão da CA do homelab (seção 8).
- **Em porta própria** (ex.: um sistema por porta): crie o entrypoint e use ``PathPrefix(`/`)``:
  ```bash
  sudo /opt/homelab/scripts/proxy.sh entrypoint add pdv 8081
  ```
  ```text
  traefik.http.routers.pdv.entrypoints=pdv
  traefik.http.routers.pdv.rule=PathPrefix(`/`)
  traefik.http.routers.pdv.tls=true
  traefik.http.routers.pdv.middlewares=homelab-lan-only@file
  traefik.http.routers.pdv.service=pdv
  traefik.http.services.pdv.loadbalancer.server.port=80
  ```
- `homelab-lan-only@file` (aceita só redes privadas e Tailscale) e `homelab-redirect-https@file` vêm de `/opt/homelab/proxy/dynamic/homelab-lan.yaml`, gerado pelo `homelab-ca.sh`.
- Em APIs com **SSE**, não use middleware de compressão (o stream precisa sair sem buffer).
- Portas extras de containers só aceitam a LAN (seção 9.2).

### 7.4 Domínio público

Com as rotas da LAN funcionando, publicar na internet é um comando na pasta do projeto (`public-route.sh`, seção 9.4):

```bash
cd /opt/homelab/apps/minhaapi
/opt/homelab/scripts/public-route.sh add api api.seudominio.com.br
```

### 7.5 Deploy automático (GitHub Actions + runner no L14)

O runner self-hosted (seção 12) busca os jobs no GitHub, então nenhuma porta precisa ser aberta. O build roda na nuvem do GitHub e publica a imagem no GHCR; o job de deploy, no L14, só baixa a imagem e recria os containers.

Preparação (uma vez por projeto):
1. Registre o runner no repositório (seção 12). Use **só em repositório privado**.
2. O runner (`gh-runner`) precisa ler o compose e o `.env`:
   ```bash
   cd /opt/homelab/apps/minhaapi
   sudo chgrp docker docker-compose*.yml .env && sudo chmod 640 .env
   ```
3. Proteja a `main` (*Settings → Branches → Require a pull request*): o deploy acontece no merge do PR.

`.github/workflows/deploy.yml` no repositório do projeto:

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency: { group: deploy-homelab, cancel-in-progress: false }
permissions: { contents: read, packages: write }

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - uses: docker/build-push-action@v6
        with:
          context: .
          file: src/Api/Dockerfile
          push: true
          tags: |
            ghcr.io/eduferrari/minhaapi-api:latest
            ghcr.io/eduferrari/minhaapi-api:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build
    runs-on: [self-hosted, homelab]
    environment: production          # opcional: aprovação manual em Settings → Environments
    defaults:
      run:
        working-directory: /opt/homelab/apps/minhaapi
    steps:
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - run: docker compose pull && docker compose up -d --no-build && docker image prune -f
      - run: sleep 15 && docker compose ps && test -z "$(docker compose ps --status exited -q)"
      - if: always()
        run: docker logout ghcr.io
```

- Só os serviços com imagem nova são recriados; o `.env` e as rotas públicas do servidor continuam valendo.
- Rode o compose **sem `-f`**: assim o Docker carrega também o `docker-compose.override.yml`, onde ficam as rotas públicas. Com `-f docker-compose.yml`, o container é recriado sem elas e o domínio passa a responder `404 page not found` (o painel geral alerta; corrija com `public-route.sh apply` na pasta do projeto). Se precisar do `-f`, liste os dois arquivos.
- Para voltar uma versão, troque `latest` pela tag do commit (`:<sha>`) no compose e rode `docker compose up -d`.

### 7.6 Painéis: geral, logs, tráfego, status e Seq — `monitor.sh`

Instalados por padrão pelo setup (`INSTALL_MONITOR=true`), atrás do proxy, com HTTPS da CA do homelab e **acessíveis só pela LAN/Tailscale**. Comece pelo **painel geral**: ele junta o resumo de tudo e tem atalhos para os outros.

| Painel | Endereço | Para quê | Login |
|---|---|---|---|
| **Geral** | `https://<host>:9440` | Uma página com tudo (detalhes abaixo), atualizada a cada minuto | usuário/senha do `monitor.sh` |
| **Logs** (Dozzle) | `https://<host>:9443` | Logs de todos os containers ao vivo, com busca e filtro por projeto — inclusive o **log do backup** (container `backup-log`) | usuário/senha do `monitor.sh` |
| **Tráfego** (GoAccess) | `https://<host>:9444` | Requisições por rota do Traefik (`<router>@docker`), status 2xx/4xx/5xx, IPs, páginas, navegadores, banda; atualiza a cada 60 s e guarda histórico | usuário/senha do `monitor.sh` |
| **Status** (Uptime Kuma) | `https://<host>:9445` | Testa domínios, portas e certificados e avisa (Telegram, e-mail, WhatsApp…) | criado no **primeiro acesso** |
| **Seq** | `https://<host>:9446` | Logs estruturados das apps .NET (Serilog), com filtro por propriedade | `admin` + senha do `monitor.sh` (troca no 1º acesso) |

```bash
sudo /opt/homelab/scripts/monitor.sh               # status e endereços
sudo /opt/homelab/scripts/monitor.sh credenciais   # usuário e senha
sudo /opt/homelab/scripts/monitor.sh apply         # aplica monitor.conf editado (liga/desliga painéis, portas)
sudo /opt/homelab/scripts/monitor.sh remove        # para os painéis e fecha as portas (dados preservados)
```

- Configuração em `/opt/homelab/monitor/monitor.conf` (`PAINEL`, `DOZZLE`, `GOACCESS`, `UPTIME_KUMA`, `SEQ`, `BACKUP_LOG` = `true`/`false`, portas, imagens, `SEQ_MEMORY`); senha em `/opt/homelab/monitor/.env` (600). Trocou a senha no `.env`? Rode `monitor.sh apply`.
- O tráfego vem do **log de acesso do proxy** (`/opt/homelab/proxy/logs/access.log`, `ACCESS_LOG="true"` no `proxy.conf`), com rotação diária (14 dias). Nenhum projeto precisa mudar.
- No Uptime Kuma, crie o usuário logo após a instalação. Monitores úteis: cada domínio público (HTTP + validade do certificado) e as portas da LAN (`https://<IP>:<porta>`, ignorando o certificado ou instalando a CA).

**Painel geral** (`painel.sh`, gerado a cada minuto pelo `homelab-painel.timer`):

| Bloco | Mostra |
|---|---|
| Atenção | Só aparece com problema: container parado com erro, reiniciando ou *unhealthy*; proxy fora do ar; domínio sem resposta ou com 5xx; certificado vencendo; backup falho ou com mais de 26 h; disco externo desconectado; disco > 80%; notebook fora da tomada |
| Atalhos | Painéis, portas dos projetos na LAN, Adminer, RedisInsight, RabbitMQ — o endereço segue o que você usou para abrir o painel (nome `.local`, IP ou Tailscale) |
| Servidor | Tempo ligado, carga, memória, discos (sistema, backups, disco externo), bateria, temperatura |
| Backup | Última execução (resultado, tamanho, duração), próxima execução, disco externo e as últimas linhas do log |
| Domínios públicos | Cada domínio de `public-routes.conf` e do Let's Encrypt: resposta HTTP pelo proxy, tempo e dias até o certificado vencer |
| Tráfego — 24 h | Requisições, 4xx e 5xx por rota do Traefik e tempo médio (detalhes no GoAccess) |
| Containers | Todos, agrupados por projeto (compose), com estado, CPU, memória e reinícios |

```bash
sudo /opt/homelab/scripts/painel.sh          # gera agora (o timer já faz a cada minuto)
sudo /opt/homelab/scripts/painel.sh json     # os mesmos dados em JSON (também em https://<host>:9440/status.json)
```

**Alerta do backup no Uptime Kuma** (avisa quando o backup falha **ou não roda**):

1. No Uptime Kuma: *Add New Monitor* → tipo **Push** → *Heartbeat Interval* `90000` s (25 h) → salve e copie a **Push URL**.
2. No servidor, cole a URL no `.env` da infra:
   ```bash
   sudo sed -i 's|^BACKUP_PUSH_URL=.*|BACKUP_PUSH_URL=https://127.0.0.1:9445/api/push/<token>|' /opt/homelab/infra/.env
   grep -q '^BACKUP_PUSH_URL=' /opt/homelab/infra/.env || echo 'BACKUP_PUSH_URL=https://127.0.0.1:9445/api/push/<token>' | sudo tee -a /opt/homelab/infra/.env
   sudo /opt/homelab/scripts/backup.sh          # testa: o monitor fica verde
   ```
   Use `https://127.0.0.1:9445/...` (o backup roda no próprio servidor; o certificado da LAN é aceito). Cada backup completo envia `up` ou `down` com a mensagem do resultado; sem aviso por 25 h, o Kuma alerta sozinho. Configure a notificação (Telegram, e-mail…) no próprio monitor.

**Enviando logs de uma API .NET para o Seq** (serviço na rede `proxy`):

```csharp
// dotnet add package Serilog.AspNetCore Serilog.Sinks.Seq
builder.Host.UseSerilog((ctx, cfg) => cfg
    .ReadFrom.Configuration(ctx.Configuration)
    .Enrich.FromLogContext()
    .WriteTo.Console()
    .WriteTo.Seq(ctx.Configuration["Seq:ServerUrl"] ?? "http://seq:5341",
                 apiKey: ctx.Configuration["Seq:ApiKey"]));
// ...
app.UseSerilogRequestLogging();
```

**No servidor: `seq-app.sh`** (na pasta do projeto; não precisa de sudo):

```bash
cd /opt/homelab/apps/<projeto>
/opt/homelab/scripts/seq-app.sh add api        # pede a chave criada no Seq (Settings → API Keys); Enter vazio = sem chave
/opt/homelab/scripts/seq-app.sh check          # rede, variáveis e evento de teste de cada serviço
```

O `add`:
1. Põe o serviço na rede `proxy`, onde o Seq está. Se o compose ainda usa a rede legada `coolify`, troca por `proxy` no arquivo todo (pede confirmação).
2. Acrescenta `Seq__ServerUrl: http://seq:5341` e `Seq__ApiKey: ${SEQ_APIKEY_<SERVIÇO>}` no `environment:` do serviço. A chave fica no `.env` do projeto, fora do Git.
3. Valida o compose. Se der erro, volta o original (há sempre um backup `docker-compose.yml.bak-<data>`).
4. Recria o serviço **sem `-f`**, mantendo as rotas públicas.
5. Envia um evento "Teste do homelab" pela rede do container.

Comentários e formatação do compose são preservados. Opções: `--key <chave>`, `--sem-chave`, `--yes`, `-C <pasta>`.

A chave não é obrigatória (o Seq aceita eventos sem ela), mas com uma chave por aplicação dá para filtrar a origem, definir nível mínimo e, se quiser, exigir chave em *Settings → Ingestion*.

### 7.7 Migrando de um homelab com Coolify

Versões anteriores deste homelab usavam o Coolify (e o Traefik dele). A migração aproveita os certificados Let's Encrypt, as portas extras da LAN, a CA e as rotas dos projetos:

```bash
cd ~/homelab && git pull
sudo ./homelab-setup.sh                               # instala os scripts novos (o proxy fica pendente)
sudo /opt/homelab/scripts/proxy.sh migrate-coolify    # backup do Coolify, importa config, troca o proxy (segundos fora do ar)
# teste a LAN (443 e portas extras) e os domínios públicos
sudo /opt/homelab/scripts/proxy.sh rollback-coolify   # só se algo der errado: volta ao Coolify
sudo /opt/homelab/scripts/proxy.sh remove-coolify     # com tudo certo: remove o Coolify (pede confirmação)
sudo ./homelab-setup.sh                               # fecha o SSH de root e as regras de firewall do Coolify
```

- O backup do Coolify (banco + `/data/coolify`) fica em `/opt/homelab/backups/coolify-final-<data>/`.
- Projetos que usam a rede `coolify` continuam funcionando, porque o proxy também entra nela (`PROXY_EXTRA_NETWORKS="coolify"`). Para padronizar, troque `coolify` por `proxy` no compose do projeto (em `networks` e em `traefik.docker.network`) e rode `docker compose up -d`. Depois de migrar todos, remova `coolify` de `PROXY_EXTRA_NETWORKS` e rode `proxy.sh apply`.

---

## 8. HTTPS na LAN — CA do homelab (`homelab-ca.sh`)

Apps na LAN são acessadas pelo nome `.local` e pelo **IP** (tablets Android não resolvem `.local` de forma confiável). Uma CA própria, instalada uma vez em cada dispositivo, emite o certificado da LAN, que o Traefik usa:

- para os nomes do certificado (`homelab.local`, IP da LAN, extras);
- **como certificado padrão**: quem acessa pelo IP não envia SNI, e o Traefik responde com este certificado — mesmo atrás do NAT do Docker (validado com Traefik v3 real).

```bash
sudo /opt/homelab/scripts/homelab-ca.sh                    # status
sudo /opt/homelab/scripts/homelab-ca.sh export             # exporta o raiz (para instalar nos dispositivos) e mostra o SHA-256
sudo /opt/homelab/scripts/homelab-ca.sh issue              # reemite e reinstala no proxy
sudo /opt/homelab/scripts/homelab-ca.sh init               # CA nova (só se não houver nenhuma)
sudo /opt/homelab/scripts/homelab-ca.sh import root.crt root.key   # CA existente (só se não houver nenhuma)
```

- O setup **cria a CA automaticamente** (ou importa a de `CA_IMPORT_DIR`) e emite o certificado da LAN.
- Certificado da LAN: 365 dias; o timer semanal `homelab-ca-renew` reemite quando faltam < 30 dias **ou quando o IP muda**.
- Nomes extras: `HOMELAB_CA_EXTRA_NAMES="pdv.local 192.168.1.11"` no `.env` + `issue`.
- A chave da CA fica em `/opt/homelab/ca/root.key` (600, root) e entra no backup (`config.tar.gz`). **Não a perca**: uma CA nova exige reinstalar o raiz em todos os dispositivos.

Instalar o raiz no Mac:

```bash
scp usuario@homelab.local:/opt/homelab/ca/homelab-root-ca.crt .   # após "export"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-root-ca.crt
```

Confira a impressão digital (SHA-256) antes de confiar.

---

## 9. Rede

### 9.1 Nome na LAN (mDNS)

O L14 responde como `<hostname>.local` (só IPv4). macOS, Windows 10+ e Linux com `libnss-mdns` resolvem. Containers **não** resolvem `.local` — use o IP.

### 9.2 Firewall

- UFW: entrada negada por padrão; SSH com rate-limit; mDNS só da LAN.
- O Docker publica portas ignorando o UFW. O bloco *ufw-docker* em `/etc/ufw/after.rules` (cadeia `DOCKER-USER`) faz **toda porta de container aceitar só redes privadas** (`10/8`, `172.16/12`, `192.168/16`, `100.64/10` — Tailscale). Vale para MySQL, Redis, RabbitMQ, o proxy (80/443 e portas extras) e os painéis (9443–9446).
- Acesso pela internet: só via `public-access.sh` (seção 9.4).

```bash
sudo ufw status numbered
sudo journalctl -k | grep "UFW DOCKER BLOCK"   # bloqueios vindos de fora
```

### 9.3 IP fixo na LAN — `network-static.sh`

O roteador encaminha o IP público para **um IP da LAN**; por isso o L14 precisa de IP fixo:

```bash
sudo /opt/homelab/scripts/network-static.sh                       # rede atual e sugestão
sudo /opt/homelab/scripts/network-static.sh 192.168.1.10/24     # fixa (gateway e DNS detectados)
```

- Escolha um IP **fora da faixa de DHCP** do roteador; o script confere com `arping` se ninguém o usa.
- Gera `/etc/netplan/90-homelab-static.yaml`, sobrepondo só o endereçamento (Wi-Fi e senha continuam no arquivo original).
- **5 minutos** para conectar no IP novo e confirmar; sem confirmação, a rede volta sozinha:

```bash
ssh usuario@192.168.1.10
sudo /opt/homelab/scripts/network-static.sh --confirm
cd ~/homelab && sudo ./homelab-setup.sh && sudo /opt/homelab/scripts/homelab-ca.sh issue
```

Voltar para DHCP: `sudo /opt/homelab/scripts/network-static.sh --dhcp`.

### 9.4 Acesso pela internet — IP público fixo

```text
Internet ─► api.seudominio.com.br (DNS A) ─► 203.0.113.10 (roteador/ONT)
         ─► 80/443 encaminhadas ─► 192.168.1.10 (L14) ─► Traefik (proxy.sh) ─► app
```

Nos exemplos: `203.0.113.10` é o IP público fixo do provedor, `192.168.1.10` o IP fixo do L14 na LAN e `api`/`app.seudominio.com.br` domínios do seu projeto.

1. **Provedor / roteador:** encaminhar `80/tcp`, `443/tcp` e `443/udp` de `203.0.113.10` para `192.168.1.10` (IP fixo do L14, seção 9.3). **Não** encaminhe 22, as portas extras da LAN, os painéis (9443–9446), 3306, 6379, 5672 nem 15672. Se o IP da WAN no roteador for `100.64.x.x` (CGNAT), o encaminhamento não funciona.
2. **DNS** (zona do seu domínio, ex.: Registro.br) — um registro por subdomínio:
   ```text
   api   A   203.0.113.10   TTL 300
   app   A   203.0.113.10   TTL 300
   ```
3. **Firewall do L14:**
   ```bash
   sudo /opt/homelab/scripts/public-access.sh enable    # status | enable | disable | check <dominio>
   ```
   Cria regras `ufw route` para 80/443 (o proxy é um container, por isso regras de *route*). O resto continua só na LAN.
4. **Rota pública para a app** — escolha **um** caminho por domínio (dois lugares declarando o mesmo domínio geram conflito):

   - **Certificado:** o Traefik emite o Let's Encrypt sozinho. Padrão: desafio TLS-ALPN-01, **só pela porta 443** (funciona mesmo se a 80 for do roteador); `sudo proxy.sh acme http` troca para HTTP-01 (porta 80).
   - **App em Docker Compose próprio:** use o `public-route.sh` na pasta do projeto — ele lê as labels Traefik que o serviço já tem (nome do serviço Traefik, middlewares), gera as rotas públicas no `docker-compose.override.yml` e recria só os serviços afetados. O `docker-compose.yml` do projeto não é alterado e as rotas da LAN continuam iguais.
     ```bash
     cd /opt/homelab/apps/<projeto>
     /opt/homelab/scripts/public-route.sh add api api.seudominio.com.br    # <serviço do compose> <domínio>
     /opt/homelab/scripts/public-route.sh add web app.seudominio.com.br
     /opt/homelab/scripts/public-route.sh list            # o que está publicado (public-routes.conf)
     /opt/homelab/scripts/public-route.sh check           # testa cada domínio e aponta conflitos
     /opt/homelab/scripts/public-route.sh remove web      # despublica
     ```
     Requisitos do serviço: container rodando, na rede do proxy (`proxy`), com `traefik.enable=true` e `traefik.http.services.<nome>.loadbalancer.server.port`. O middleware `homelab-lan-only` não vai para a rota pública; os demais (cabeçalhos, compressão) sim. Se já existir um `docker-compose.override.yml` feito à mão, o script para; revise-o e rode com `--force` (faz backup).

     **Conflitos** que o `check` aponta: containers de outros projetos com o mesmo domínio (regra mais longa, como `Host(...) && PathPrefix(/)`, **vence**; se esse container estiver parado ou reiniciando, o resultado é `no available server`) e rotas em arquivo em `/opt/homelab/proxy/dynamic`.
5. **Diagnóstico:**
   ```bash
   sudo /opt/homelab/scripts/public-access.sh check api.seudominio.com.br
   ```
   Confere DNS (via 1.1.1.1), firewall, proxy, rota no Traefik e se o certificado já é Let's Encrypt, e mostra como provar o encaminhamento do roteador com `tcpdump` + acesso pelo 4G.
6. **Teste de fora** (4G do celular): `https://api.seudominio.com.br/health`.

**APIs .NET atrás do proxy** — o TLS termina no Traefik; sem isto a app enxerga `http` e o IP do proxy (redirects, URLs geradas, logs, rate limit por IP):

```csharp
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownNetworks.Clear();   // proxy na rede Docker "proxy"
    o.KnownProxies.Clear();
});
// ...
app.UseForwardedHeaders();     // antes de UseHttpsRedirection / autenticação
```

> **NAT loopback:** muitos roteadores não deixam acessar o próprio IP público de dentro da LAN — o domínio pode abrir só de fora. Dispositivos da LAN continuam pelas rotas locais (nome `.local` ou IP e porta da LAN).
>
> **Exposição:** confira autenticação em todos os endpoints e use rate limiting (`AddRateLimiter`) nos públicos. Para administrar de fora de casa, use **Tailscale** (já liberado: `100.64.0.0/10`) em vez de expor qualquer painel.

---

## 10. Stack de dados

```bash
sudo cat /opt/homelab/infra/.env      # credenciais
```

| Serviço | Endereço | Login |
|---|---|---|
| Adminer | `http://<host>:8088` | servidor `mysql`; `root`/`MYSQL_ROOT_PASSWORD` ou `dev`/`MYSQL_PASSWORD` |
| RedisInsight | `http://<host>:5540` | banco `homelab-redis` pré-cadastrado (`REDIS_PASSWORD`) |
| RabbitMQ | `http://<host>:15672` | `admin` / `RABBITMQ_DEFAULT_PASS` |

Connection strings:

```text
# Do seu Mac / Rider (pelo nome ou IP)
MySQL     Server=homelab.local;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis     homelab.local:6379,password=<REDIS_PASSWORD>
RabbitMQ  amqp://admin:<RABBITMQ_DEFAULT_PASS>@homelab.local:5672/

# De outros projetos sem a rede devnet (pelo IP fixo da LAN)
MySQL     Server=192.168.1.10;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;

# De containers na rede devnet (compose próprio)
MySQL     Server=mysql;Port=3306;...      Redis  redis:6379,...      RabbitMQ  amqp://...@rabbitmq:5672/
```

> **MySQL 8.4** usa `caching_sha2_password`. MySqlConnector/Pomelo funcionam normalmente; clientes antigos podem precisar de `AllowPublicKeyRetrieval=True;` (só em dev).

Operação:

```bash
cd /opt/homelab/infra
docker compose ps                                # status
docker compose logs -f rabbitmq                  # logs
docker compose restart redis                     # reiniciar
docker compose pull && docker compose up -d      # atualizar imagens
/opt/homelab/scripts/status.sh                   # visão geral
```

> ⚠️ `docker compose down -v` **apaga os volumes**. As senhas do `.env` só valem na criação dos volumes do MySQL e RabbitMQ; depois, troque pelo próprio serviço e atualize o `.env` (o Redis relê a senha a cada início).

---

## 11. Backup e restauração

Um backup completo roda **todo dia às 03:00** (`homelab-backup.timer`, systemd, com até 15 min de atraso aleatório; se o L14 estiver desligado, roda ao ligar). Ele grava em `/opt/homelab/backups/AAAA-MM-DD_HHMMSS/` (disco interno) e, em seguida, **copia para o SSD externo** (veja *SSD externo*):

| Arquivo | Conteúdo | Como é gerado |
|---|---|---|
| `mysql-all.sql.gz` | Todos os bancos, usuários, rotinas, triggers e eventos | `mysqldump --single-transaction` (sem travar as tabelas) — validado pela linha `Dump completed` |
| `redis-dump.rdb.gz` | Snapshot do Redis | `BGSAVE` consistente, sem parar o serviço |
| `rabbitmq-definitions.json` | vhosts, usuários, permissões, filas, exchanges, bindings, policies | `rabbitmqctl export_definitions` |
| `config.tar.gz` | `.env`, compose, `my.cnf`, **CA do homelab** (`/opt/homelab/ca`), **proxy** (`proxy.conf`, `dynamic/`, certificados Let's Encrypt), **painéis** (`monitor.conf`, senha, usuários do Dozzle, banco do Uptime Kuma), SSH, UFW, fail2ban, Docker, avahi, TLP, tampa, sysctl, netplan (Wi-Fi), units do systemd, e de cada projeto em `/opt/homelab/apps/<projeto>`: compose, overrides, `.env` e `public-routes.conf` (sem código-fonte nem volumes) | `tar` |
| `SHA256SUMS` | Checksums de todos os arquivos | conferidos antes de qualquer restauração |

**Não entram no backup:** mensagens que estão nas filas do RabbitMQ (só as definições), código dos projetos (fica no Git), registro do runner do GitHub (registre de novo) e preferências do RedisInsight.

**Regras de segurança do processo**
- Um backup por vez (`flock`); aborta se houver menos de 1 GB livre.
- Se **qualquer** componente falhar, o comando sai com erro e a **retenção não é aplicada** — backups antigos nunca são apagados por causa de um backup ruim.
- Resultado de cada execução completa em `last-status.json` (painel geral) e, com `BACKUP_PUSH_URL` no `.env`, aviso para o Uptime Kuma — alerta se falhar ou deixar de rodar (seção 7.6).
- Retenção: `BACKUP_KEEP_DAYS` no `.env` (padrão **7** dias). O link `latest` aponta sempre para o último backup completo bem-sucedido.
- Os arquivos contêm segredos (`.env`, chave da CA): diretórios `750` e arquivos `640`, dono `root`, grupo do seu usuário — só você e o root leem.

**Comandos**

```bash
sudo /opt/homelab/scripts/backup.sh                  # backup completo agora
sudo /opt/homelab/scripts/backup.sh redis rabbitmq   # só alguns componentes

systemctl list-timers homelab-backup.timer           # próxima execução
tail -n 50 /var/log/homelab/backup.log               # log (também no painel de logs: container backup-log)
cat /opt/homelab/backups/last-status.json            # resultado da última execução (lido pelo painel geral)
ls -l /opt/homelab/backups/                          # backups disponíveis
```

**Restaurar** (pede confirmação digitando `SIM`; `--yes` pula):

```bash
sudo /opt/homelab/scripts/restore.sh latest mysql
sudo /opt/homelab/scripts/restore.sh 2026-10-01_030512 redis
sudo /opt/homelab/scripts/restore.sh latest rabbitmq
sudo /opt/homelab/scripts/restore.sh latest config   # só extrai em /tmp para comparar — não sobrescreve nada
```

| Componente | O que a restauração faz |
|---|---|
| `mysql` | Sobrescreve todos os bancos **e usuários** com o dump |
| `redis` | Para o Redis, troca os dados do volume, carrega o snapshot sem AOF, regenera o AOF a partir da memória e sobe de novo (*trocar só o `dump.rdb` não funciona com AOF ativo — o Redis ignoraria o snapshot*) |
| `rabbitmq` | Importa as definições (mescla com as existentes) |
| `config` | Só extrai — a CA fica em `opt/homelab/ca` dentro do pacote |

### SSD externo

O backup no disco interno protege contra erro humano e dados corrompidos; a cópia no **SSD externo** protege contra falha do SSD do notebook. Cada backup completo é copiado para o SSD com conferência de checksums.

**Configurar (comando separado, uma vez):**

```bash
# 1. Conecte o SSD na USB e identifique o disco (nada é alterado)
sudo /opt/homelab/scripts/backup-disk-setup.sh

# 2a. SSD novo/vazio — APAGA o disco e cria ext4 (pede para digitar o caminho do disco)
sudo /opt/homelab/scripts/backup-disk-setup.sh /dev/sdX --format

# 2b. ou: SSD que já tem uma partição Linux (ext4/xfs/btrfs) — não apaga nada
sudo /opt/homelab/scripts/backup-disk-setup.sh /dev/sdX1
```

> Use o nome que a listagem mostrar (`/dev/sda`, `/dev/sdb`…). O script **recusa** o disco do sistema e partições exFAT/NTFS (os backups precisam de permissões Unix e links).

O que ele faz:
- monta a partição **por UUID** em `/mnt/backup-ssd` via `/etc/fstab` com `nofail` — o servidor inicia normalmente mesmo sem o SSD;
- cria `/mnt/backup-ssd/homelab` (`750`, dono `root`, grupo do seu usuário);
- grava no `.env`: `BACKUP_EXTERNAL_MOUNT`, `BACKUP_EXTERNAL_DIR` e `BACKUP_EXTERNAL_KEEP_DAYS=30`;
- copia para o SSD os backups locais que já existem.

**Como a cópia funciona**
- O SSD guarda mais histórico que o disco interno: **30 dias** (`BACKUP_EXTERNAL_KEEP_DAYS`) contra 7 (`BACKUP_KEEP_DAYS`).
- Se o SSD não estiver montado, o backup local acontece normalmente, **nada é gravado no ponto de montagem vazio** e o serviço termina com erro (código 2) para aparecer no `journalctl`/`status.sh`.
- Ao reconectar o SSD, o próximo backup copia **todos** os backups locais que faltam no SSD — os dias desconectados são recuperados (enquanto ainda estiverem na retenção local de 7 dias).
- Cópias são gravadas como `*.partial` e só são renomeadas após conferir os checksums.

```bash
sudo /opt/homelab/scripts/backup.sh --sync-external   # copia agora, sem gerar backup novo
/opt/homelab/scripts/status.sh                        # mostra se o SSD está montado e o último backup nele
ls -l /mnt/backup-ssd/homelab/
```

**Restaurar a partir do SSD** — o `restore.sh` aceita caminho absoluto:

```bash
sudo /opt/homelab/scripts/restore.sh /mnt/backup-ssd/homelab/latest redis
```

**Desconectar o SSD com segurança:** `sudo umount /mnt/backup-ssd` antes de remover.

> ⚠️ O SSD guarda segredos sem criptografia (`.env`, chave privada da CA, senha do Wi-Fi, certificados Let's Encrypt). Guarde-o como guardaria as senhas.

### Recuperação total (L14 novo ou SSD interno trocado)

```bash
# 1. Instale o Ubuntu Server, clone o repositório e conecte o SSD de backup
sudo mkdir -p /mnt/backup-ssd && sudo mount /dev/sdX1 /mnt/backup-ssd

# 2. Recupere o .env ANTES do setup (as senhas antigas são reaproveitadas)
sudo mkdir -p /opt/homelab/infra
sudo tar xzf /mnt/backup-ssd/homelab/latest/config.tar.gz -C / opt/homelab/infra/.env opt/homelab/ca opt/homelab/proxy opt/homelab/apps
sudo umount /mnt/backup-ssd                      # a CA volta junto: os dispositivos continuam confiando

# 3. Rode o setup e reconfigure o SSD (sem --format!)
sudo ./homelab-setup.sh
sudo /opt/homelab/scripts/backup-disk-setup.sh /dev/sdX1

# 4. Restaure os dados
B=/mnt/backup-ssd/homelab/latest
for c in mysql redis rabbitmq; do sudo /opt/homelab/scripts/restore.sh $B $c --yes; done
sudo /opt/homelab/scripts/restore.sh $B config   # compare SSH/UFW/netplan e copie o que precisar
sudo /opt/homelab/scripts/homelab-ca.sh issue    # reinstala o certificado da LAN no proxy
```

Depois, suba cada projeto (`cd /opt/homelab/apps/<projeto> && docker compose up -d`) ou rode o workflow de deploy no GitHub. Volumes de dados próprios dos projetos vêm dos backups de cada projeto.

---

## 12. GitHub Actions — runner self-hosted

O setup cria o usuário `gh-runner` (grupo `docker`) e baixa o runner em `/opt/actions-runner`. Para registrar:

1. GitHub: **repositório → Settings → Actions → Runners → New self-hosted runner** (ou na organização). Copie o token (vale 1 hora).
2. No L14:
   ```bash
   sudo /opt/homelab/scripts/register-runner.sh https://github.com/eduferrari/<repo> <TOKEN>
   ```

Uso típico: o job de deploy roda `docker compose pull && up -d` na pasta do projeto (seção 7.5).

> ⚠️ Nunca use runner self-hosted em **repositório público** (um PR de terceiro executaria código no servidor). O `gh-runner` está no grupo `docker` — equivale a root.

---

## 13. Roteiro: do zero ao primeiro projeto

1. **BIOS** (F1): *After Power Loss = Power On* e virtualização habilitada (seção 2).
2. **Ubuntu Server 24.04 LTS**: instale com **OpenSSH server**, usuário comum (ex.: `usuario`), hostname `homelab`. Configure a rede (cabo ou Wi-Fi) no instalador.
3. **Chave SSH** do seu Mac (seção 3):
   ```bash
   ssh-copy-id usuario@homelab.local
   ```
4. *(Opcional)* **Manter uma CA existente** (dispositivos que já confiam nela): copie `root.crt` e `root.key` para o L14, por exemplo em `~/ca-antiga/`, e rode o setup com `CA_IMPORT_DIR=~/ca-antiga`. Sem isso, uma CA nova é criada.
5. **Setup**:
   ```bash
   sudo apt-get update && sudo apt-get install -y git
   git clone https://github.com/eduferrari/homelab.git && cd homelab
   sudo PUBLIC_IP=203.0.113.10 ./homelab-setup.sh
   sudo reboot
   ```
6. **IP fixo na LAN** (seção 9.3) — confirme no IP novo e rode o setup de novo:
   ```bash
   sudo /opt/homelab/scripts/network-static.sh 192.168.1.10/24
   ```
7. **CA nos dispositivos** (Mac, tablets, celulares — seção 8):
   ```bash
   sudo /opt/homelab/scripts/homelab-ca.sh export
   ```
8. **Proxy**: confira com `sudo /opt/homelab/scripts/proxy.sh`; portas próprias na LAN com `proxy.sh entrypoint add <nome> <porta>` (seção 7.1).
   **Painéis**: `sudo /opt/homelab/scripts/monitor.sh credenciais`, abra o painel geral `https://<host>:9440`, crie o usuário do Uptime Kuma (`:9445`) e o monitor Push do backup (seção 7.6).
9. **Primeiro projeto**: compose em `/opt/homelab/apps/<projeto>` na rede `proxy`, API .NET na porta 8080, `.env` no servidor (seção 7.2); rotas na LAN (7.3) e domínio público (7.4).
10. **Deploy automático**: runner + workflow do GitHub Actions (seções 7.5 e 12).
11. **Backup** — confira o primeiro backup e prepare o SSD externo (seção 11):
    ```bash
    sudo /opt/homelab/scripts/backup.sh
    sudo /opt/homelab/scripts/backup-disk-setup.sh
    ```
12. **Internet** (quando houver domínio): roteador, DNS e `public-access.sh enable` (seção 9.4).

> Reinstalando a partir de um backup? Siga *Recuperação total* (seção 11): o `.env` e a CA voltam antes do setup, então as senhas e a confiança dos dispositivos são mantidas.

---

## 14. Tampa fechada e bateria

Verificar se está correto:

```bash
systemd-analyze cat-config systemd/logind.conf | grep HandleLid
systemctl status sleep.target suspend.target   # devem estar "masked"
sudo tlp-stat -b | grep -i thresh              # faixa 75–80%
cat /sys/class/power_supply/BAT0/capacity      # carga atual
```

Teste: feche a tampa, aguarde 1 minuto e acesse o L14 via SSH de outra máquina.

Para liberar carga total temporariamente (ex.: antes de levar o notebook):

```bash
sudo tlp fullcharge BAT0
```

---

## 15. Solução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| Setup: *Proxy NÃO instalado: portas em uso* | Algo ocupa 80/443: `sudo ss -tlnp \| grep -E ':(80\|443) '`. Se for o Coolify: `sudo proxy.sh migrate-coolify` (seção 7.7) |
| Projeto não conecta no MySQL/Redis | Serviço na rede `devnet` e host `mysql`/`redis`/`rabbitmq`; sem a rede, use o **IP fixo da LAN** (não `.local`); confira usuário/senha do `.env` |
| Navegador/tablet: certificado inválido | CA não instalada no dispositivo, ou o IP mudou: `sudo /opt/homelab/scripts/homelab-ca.sh` (status) e `issue` |
| Acesso pelo IP falha com erro de TLS | `/opt/homelab/proxy/dynamic/homelab-lan.yaml` ausente: `sudo /opt/homelab/scripts/homelab-ca.sh issue` |
| `404 page not found` (Traefik) | Nenhuma rota casou: confira entrypoint/rule das labels ou do arquivo em `dynamic/`; `sudo proxy.sh logs` |
| Domínio público com `404 page not found` depois de um deploy | O container foi recriado sem o `docker-compose.override.yml` (compose com `-f`): `public-route.sh apply` na pasta do projeto e tire o `-f` do deploy (seção 7.5) |
| `502 Bad Gateway` (Traefik) | O container de destino não está na rede `proxy` (ou na de `traefik.docker.network`) ou a porta está errada |
| Painel não abre (`:9443`–`:9446`) | `sudo monitor.sh` (status); `sudo proxy.sh` mostra as portas `painel-*`; acesso só da LAN/Tailscale. Tráfego vazio: confira `ACCESS_LOG="true"` em `proxy.conf` e `docker logs goaccess` |
| `403 Forbidden` na LAN | O middleware `homelab-lan-only` não reconhece a origem (ex.: rede fora das faixas privadas) |
| Let's Encrypt não emite | `public-access.sh check <dominio>`. Log com `reader size limit exceeded` = a porta 80 do IP público é do roteador → `sudo /opt/homelab/scripts/proxy.sh acme tls` (valida só pela 443). DNS aponta para `203.0.113.10`? Portas 80/443 encaminhadas? `public-access.sh status`? Sem CGNAT? `sudo proxy.sh logs` |
| `network-static.sh`: a rede voltou sozinha | Não houve `--confirm` em 5 min. Confira IP/gateway e aplique de novo |
| `permission denied ... docker.sock` | Faltou reiniciar (ou logout/login) após a instalação |
| `Connection refused` no SSH | `sudo ss -tlnp \| grep :22` e `sudo fail2ban-client unban --all` |
| Backup terminou com código 2 | SSD externo não montado: conecte e rode `sudo /opt/homelab/scripts/backup.sh --sync-external` |
| Backup falhou | `tail -n 50 /var/log/homelab/backup.log` (ou o painel de logs, container `backup-log`) mostra o componente com `✘` |
| `<host>.local` não resolve | `systemctl status avahi-daemon`; containers nunca resolvem `.local` |

Log da instalação: `/var/log/homelab-setup.log`

---

## Licença

Distribuído sob a licença Apache 2.0 — veja [LICENSE](LICENSE).
