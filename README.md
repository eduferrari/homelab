# Homelab — ThinkPad L14

Provisionamento do ThinkPad L14 como servidor: Ubuntu endurecido, **stack de dados** (MySQL, Redis, RabbitMQ) em Docker e **Coolify** para hospedar e gerenciar os projetos (deploy do GitHub, domínios, HTTPS, logs, variáveis).

---

## 1. Visão geral

| Camada | Componente | Porta | Acesso |
|---|---|---|---|
| Projetos | **Coolify** (PaaS self-hosted) | 8000 | `http://<host>:8000` |
| Projetos | Proxy do Coolify (Traefik v3) | 80, 443 (+ 8080 painel do Traefik) | apps e domínios |
| Dados | MySQL 8.4 | 3306 | clientes MySQL / apps |
| Dados | Adminer | **8088** | `http://<host>:8088` |
| Dados | Redis 7 | 6379 | clientes Redis / apps |
| Dados | RedisInsight | 5540 | `http://<host>:5540` |
| Dados | RabbitMQ 4 (AMQP / Management) | 5672 / 15672 | `http://<host>:15672` |
| Host | SSH | 22 | `ssh <usuario>@<host>` |

`<host>` é o nome mDNS do L14 — `homelab-eduardo.local` — ou o IP fixo da LAN.

- A stack de dados fica em `/opt/homelab/infra` (compose `homelab`, rede `devnet`, volumes persistentes).
- Tudo que roda em container é acessível **somente pela LAN** (seção 9.2). Para a internet, apenas 80/443 do proxy do Coolify, quando você ativar (seção 9.4).
- HTTPS na LAN (nome `.local` **e** IP — inclusive tablets que acessam pelo IP) usa a **CA do homelab** (seção 8).

---

## 2. Pré-requisitos

1. **Ubuntu Server 24.04 LTS** instalado no L14 (22.04 também funciona; Ubuntu Desktop funciona, mas o script muda o boot para modo texto).
   - Na instalação, marque **"Install OpenSSH server"**.
2. Um usuário comum com `sudo` (o que você criou na instalação).
3. Hardware para o Coolify: **2 núcleos, 2 GB de RAM livres e 30 GB de disco** (além da stack de dados).
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
ssh-keygen -t ed25519 -C "eduardo@homelab"   # se ainda não tiver chave
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

> O setup precisa da pasta `scripts/` do repositório — rode sempre a partir do clone. É **idempotente**: pode rodar de novo a qualquer momento (preserva `.env`, senhas, volumes e a CA). Para atualizar: `git pull && sudo ./homelab-setup.sh`.

### Opções (variáveis de ambiente)

```bash
sudo PUBLIC_IP=177.101.139.43 COOLIFY_ADMIN_EMAIL=voce@exemplo.com ./homelab-setup.sh
```

| Variável | Padrão | Descrição |
|---|---|---|
| `HOMELAB_USER` | usuário que chamou o `sudo` | Dono dos arquivos e usuário do SSH |
| `HOMELAB_DIR` | `/opt/homelab` | Raiz da infraestrutura |
| `TIMEZONE` | `America/Sao_Paulo` | Fuso do sistema e containers |
| `DOCKER_NETWORK` | `devnet` | Rede Docker da stack de dados |
| `SSH_PORT` / `DISABLE_SSH_PASSWORD` | `22` / `auto` | SSH; `auto` desliga senha se já houver chave |
| `INSTALL_COOLIFY` | `true` | Instala o Coolify (se 80, 443, 8000 e 8080 estiverem livres) |
| `COOLIFY_ADMIN_EMAIL` | `admin@homelab.local` | E-mail do admin do Coolify (senha gerada no `.env`) |
| `COOLIFY_AUTOUPDATE` | `false` | Atualizações automáticas do Coolify |
| `PUBLIC_IP` | — | IP público fixo do provedor (registrado no `.env`, informativo) |
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
| 4 | SSH | Senha desligada se houver chave, fail2ban (LAN nunca é banida). **Root só por chave e só das redes Docker** — necessário para o Coolify gerenciar o próprio host |
| 5 | Docker | Docker CE + Compose; `daemon.json` com logs rotativos, `live-restore` e pool `10.0.0.0/8` (o mesmo do Coolify, que assim não reescreve o arquivo) |
| 6 | Firewall | UFW: entrada negada, SSH com rate-limit (exceto vindo do Coolify), mDNS na LAN; containers **só para redes privadas** |
| 7 | Estrutura | Diretórios, `/etc/homelab.conf`; **remove versões anteriores** (painel, Caddy da stack, Cockpit — dados preservados em `legacy/`) |
| 8 | Rede | `docker network create devnet` |
| 9 | Stack de dados | `.env` com senhas aleatórias, `docker-compose.yml`, `my.cnf` |
| 10 | Subida | `docker compose up --wait --remove-orphans` |
| 11 | Utilitários | `scripts/*.sh` → `/opt/homelab/scripts`; timers de backup (diário) e de renovação do certificado da LAN (semanal) |
| 12 | Coolify | Instalador oficial, admin já criado (sem cadastro aberto), certificado da LAN no Traefik |
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
├── apps/                       # área livre para arquivos de projetos
├── backups/                    # backups diários (750 root:<seu grupo>)
├── legacy/                     # restos de versões anteriores (pode apagar)
└── scripts/
    ├── status.sh               # visão geral
    ├── homelab-ca.sh           # CA e HTTPS na LAN
    ├── backup.sh / restore.sh  # backup e restauração
    ├── backup-disk-setup.sh    # prepara o SSD externo
    ├── network-static.sh       # IP fixo na LAN
    ├── public-access.sh        # libera 80/443 para a internet
    └── register-runner.sh      # registra o runner do GitHub

/data/coolify/                  # Coolify (gerenciado por ele)
└── proxy/{dynamic,certs}/      # Traefik: config dinâmica e certificados
/etc/homelab.conf               # configuração lida pelos scripts
/var/log/homelab-setup.log
```

Repositório:

```text
homelab-setup.sh                # provisionamento
scripts/                        # utilitários instalados em /opt/homelab/scripts
docs/exemplos/                  # configurações de exemplo (ex.: MesaFácil no Traefik)
```

---

## 7. Coolify — hospedando os projetos

### 7.1 Primeiro acesso

1. Abra `http://homelab-eduardo.local:8000`.
2. Se o proxy aparecer parado em **Servers → localhost → Proxy**, clique em **Start Proxy**.
3. Login: **e-mail** `COOLIFY_ADMIN_EMAIL` e **senha** `COOLIFY_ADMIN_PASSWORD` — `sudo grep COOLIFY /opt/homelab/infra/.env`. O admin é criado na instalação; não há tela de cadastro aberta na LAN.
4. Em **Servers → localhost**, clique em **Validate Server** — o Coolify conecta no próprio host por SSH como root (chave dele, só a partir das redes Docker).
5. Ative **2FA** no seu perfil.

> Atualizações automáticas do Coolify vêm desligadas (`COOLIFY_AUTOUPDATE=false`): atualize pelo painel quando quiser, de preferência após um backup.

### 7.2 Deploy de uma API ASP.NET Core

No Coolify: **Projects → New → Application → Public/Private Repository (GitHub)**.

| Configuração | Valor | Por quê |
|---|---|---|
| **Build Pack** | **Dockerfile** | Evite o Nixpacks automático: o .NET se comporta muito melhor com o Dockerfile oficial da Microsoft |
| **Ports Exposes** | **8080** | Imagens .NET 8+ escutam na 8080 por padrão (`ASPNETCORE_HTTP_PORTS`); a porta tem que bater com o `EXPOSE` do Dockerfile |
| **Health Check** | `/health` | Com `app.MapHealthChecks("/health")` |
| **Environment Variables** | ver abaixo | Configuração por ambiente, fora do repositório |

Variáveis recomendadas:

```text
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_FORWARDEDHEADERS_ENABLED=true      # atrás do Traefik: esquema/IP reais do cliente
ConnectionStrings__Default=Server=192.168.101.28;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis__Configuration=192.168.101.28:6379,password=<REDIS_PASSWORD>
RabbitMQ__Uri=amqp://admin:<RABBITMQ_DEFAULT_PASS>@192.168.101.28:5672/
```

> As apps do Coolify ficam em redes próprias; o caminho simples até MySQL/Redis/RabbitMQ é o **IP fixo do L14 na LAN** (o firewall libera as redes Docker). Use o IP, não o `.local` — containers não resolvem mDNS.

Dockerfile de referência (multi-stage, solução com Clean Architecture):

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

### 7.3 Domínios e HTTPS

| Onde a app vai responder | Como configurar |
|---|---|
| **Internet**, com domínio próprio | Em **Domains**: `https://api.seudominio.com.br`. O Traefik emite Let's Encrypt sozinho. Exige seção 9.4 (portas no roteador, DNS, `public-access.sh enable`) |
| **LAN**, pelo nome ou IP, em porta própria | Labels do Traefik (seção 7.5) com o middleware `homelab-lan-only@file`. O certificado da CA do homelab é servido automaticamente |

> No Coolify, uma porta dentro do domínio (`https://app.exemplo.com:3000`) indica a **porta do container**, não uma porta externa. Portas externas além de 80/443 exigem *entrypoints* extras no proxy (seção 7.4).

### 7.4 Portas extras no proxy (ex.: 8081–8083)

Para servir sistemas em portas próprias na LAN (como o MesaFácil), adicione entrypoints ao Traefik:

**Servers → localhost → Proxy → Configuration**, no `docker-compose` do proxy:

```yaml
    ports:
      # ...mantenha 80, 443 e 8080 e acrescente:
      - '8081:8081'
      - '8082:8082'
      - '8083:8083'
    command:
      # ...mantenha os existentes e acrescente:
      - '--entrypoints.p8081.address=:8081'
      - '--entrypoints.p8082.address=:8082'
      - '--entrypoints.p8083.address=:8083'
```

Salve e **Restart Proxy**. As portas publicadas por containers ficam acessíveis só pela LAN (seção 9.2).

### 7.5 Rotas na LAN com labels

Em uma aplicação/serviço do Coolify (**Container Labels**), sem preencher *Domains*:

```text
traefik.enable=true
traefik.http.routers.pdv.entrypoints=p8081
traefik.http.routers.pdv.rule=PathPrefix(`/`)
traefik.http.routers.pdv.tls=true
traefik.http.routers.pdv.middlewares=homelab-lan-only@file
traefik.http.services.pdv.loadbalancer.server.port=80
```

`homelab-lan-only@file` e o certificado padrão vêm de `/data/coolify/proxy/dynamic/homelab-lan.yaml`, gerado pelo `homelab-ca.sh` (seção 8).

### 7.6 Deploy automático a partir do GitHub

| Opção | Requisito |
|---|---|
| **GitHub App do Coolify** (push → deploy) | O GitHub precisa alcançar o webhook do Coolify pela internet: domínio público para o Coolify (*Settings → Instance's Domain*) + seção 9.4 |
| **Runner self-hosted + API do Coolify** (sem expor nada) | Runner registrado no L14 (seção 12) chama a API local |

API: **Settings → Advanced → API Access** ligado e um token em **Keys & Tokens → API tokens**. Salve como secrets do repositório: `COOLIFY_TOKEN` e `COOLIFY_APP_UUID` (UUID na URL da aplicação no Coolify).

```yaml
# .github/workflows/deploy.yml
name: build-and-deploy
on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 8.0.x
      - run: dotnet test --configuration Release

  deploy:
    needs: test
    runs-on: [self-hosted, homelab]
    steps:
      - name: Deploy no Coolify
        run: |
          curl -fsS -X POST \
            -H "Authorization: Bearer ${{ secrets.COOLIFY_TOKEN }}" \
            "http://localhost:8000/api/v1/deploy?uuid=${{ secrets.COOLIFY_APP_UUID }}"
```

---

## 8. HTTPS na LAN — CA do homelab (`homelab-ca.sh`)

Apps na LAN são acessadas pelo nome `.local` e pelo **IP** (tablets Android não resolvem `.local` de forma confiável). Uma CA própria, instalada uma vez em cada dispositivo, emite o certificado da LAN, que o Traefik usa:

- para os nomes do certificado (`homelab-eduardo.local`, IP da LAN, extras);
- **como certificado padrão**: quem acessa pelo IP não envia SNI, e o Traefik responde com este certificado — mesmo atrás do NAT do Docker (validado com Traefik v3 real).

```bash
sudo /opt/homelab/scripts/homelab-ca.sh                    # status
sudo /opt/homelab/scripts/homelab-ca.sh import-caddy       # reaproveita a CA do Caddy antigo (dispositivos continuam confiando)
sudo /opt/homelab/scripts/homelab-ca.sh init               # ou: CA nova (instale nos dispositivos)
sudo /opt/homelab/scripts/homelab-ca.sh issue              # emite e instala no Traefik do Coolify
sudo /opt/homelab/scripts/homelab-ca.sh export             # exporta o raiz e mostra o SHA-256
```

- Certificado da LAN: 365 dias; o timer semanal `homelab-ca-renew` reemite quando faltam < 30 dias **ou quando o IP muda**.
- Nomes extras: `HOMELAB_CA_EXTRA_NAMES="pdv.local 192.168.101.29"` no `.env` + `issue`.
- A chave da CA fica em `/opt/homelab/ca/root.key` (600, root) e entra no backup (`config.tar.gz`). **Não a perca**: uma CA nova exige reinstalar o raiz em todos os dispositivos.

Instalar o raiz no Mac:

```bash
scp eduardo@homelab-eduardo.local:/opt/homelab/ca/homelab-root-ca.crt .   # após "export"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-root-ca.crt
```

Confira a impressão digital (SHA-256) antes de confiar.

---

## 9. Rede

### 9.1 Nome na LAN (mDNS)

O L14 responde como `<hostname>.local` (só IPv4). macOS, Windows 10+ e Linux com `libnss-mdns` resolvem. Containers **não** resolvem `.local` — use o IP.

### 9.2 Firewall

- UFW: entrada negada por padrão; SSH com rate-limit (sem limite para as redes Docker, de onde o Coolify conecta); mDNS só da LAN.
- O Docker publica portas ignorando o UFW. O bloco *ufw-docker* em `/etc/ufw/after.rules` (cadeia `DOCKER-USER`) faz **toda porta de container aceitar só redes privadas** (`10/8`, `172.16/12`, `192.168/16`, `100.64/10` — Tailscale). Vale para MySQL, Redis, RabbitMQ, Coolify (8000) e o proxy (80/443/8080).
- Acesso pela internet: só via `public-access.sh` (seção 9.4).

```bash
sudo ufw status numbered
sudo journalctl -k | grep "UFW DOCKER BLOCK"   # bloqueios vindos de fora
```

### 9.3 IP fixo na LAN — `network-static.sh`

O roteador encaminha o IP público para **um IP da LAN**; por isso o L14 precisa de IP fixo:

```bash
sudo /opt/homelab/scripts/network-static.sh                       # rede atual e sugestão
sudo /opt/homelab/scripts/network-static.sh 192.168.101.28/24     # fixa (gateway e DNS detectados)
```

- Escolha um IP **fora da faixa de DHCP** do roteador; o script confere com `arping` se ninguém o usa.
- Gera `/etc/netplan/90-homelab-static.yaml`, sobrepondo só o endereçamento (Wi-Fi e senha continuam no arquivo original).
- **5 minutos** para conectar no IP novo e confirmar; sem confirmação, a rede volta sozinha:

```bash
ssh eduardo@192.168.101.28
sudo /opt/homelab/scripts/network-static.sh --confirm
cd ~/homelab && sudo ./homelab-setup.sh && sudo /opt/homelab/scripts/homelab-ca.sh issue
```

Voltar para DHCP: `sudo /opt/homelab/scripts/network-static.sh --dhcp`.

### 9.4 Acesso pela internet — IP público fixo `177.101.139.43`

```text
Internet ─► 177.101.139.43 (roteador/ONT) ─► 80/443 ─► IP fixo do L14 na LAN ─► Traefik (Coolify) ─► app
```

1. **Confirme que não há CGNAT:** o IP da WAN no roteador/ONT deve ser `177.101.139.43`. Se aparecer `100.64.x.x`, o encaminhamento não funciona — fale com o provedor.
2. **Roteador/ONT:** encaminhe `80/tcp`, `443/tcp` e `443/udp` para o IP fixo do L14 (seção 9.3). **Não** encaminhe 22, 8000, 8080, 3306, 6379, 5672 nem 15672.
3. **Firewall do L14:**
   ```bash
   sudo /opt/homelab/scripts/public-access.sh enable    # status | enable | disable
   ```
   Cria regras `ufw route` para 80/443 (o proxy é um container, por isso regras de *route*). O resto continua só na LAN.
4. **DNS:** registro `A` — ex.: `api.seudominio.com.br → 177.101.139.43`.
5. **Coolify:** na app, *Domains* = `https://api.seudominio.com.br` → Let's Encrypt automático.
6. **Teste de fora** (4G do celular).

> Para administrar de fora de casa, use **Tailscale** (já liberado: `100.64.0.0/10`) em vez de expor o painel do Coolify. Para expô-lo com domínio (necessário para o GitHub App), defina *Settings → Instance's Domain* e ative 2FA.

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
MySQL     Server=homelab-eduardo.local;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis     homelab-eduardo.local:6379,password=<REDIS_PASSWORD>
RabbitMQ  amqp://admin:<RABBITMQ_DEFAULT_PASS>@homelab-eduardo.local:5672/

# De apps no Coolify (pelo IP fixo da LAN)
MySQL     Server=192.168.101.28;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;

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
| `coolify-db.dump`, `coolify-data.tar.gz` | Banco do Coolify (projetos, apps, variáveis, domínios) e `/data/coolify` (APP_KEY, chaves SSH, proxy) | `pg_dump` + `tar` — volumes de dados das apps **não** entram |
| `config.tar.gz` | `.env`, compose, `my.cnf`, **CA do homelab** (`/opt/homelab/ca`), SSH, UFW, fail2ban, Docker, avahi, TLP, tampa, sysctl, netplan (Wi-Fi), units do systemd | `tar` |
| `SHA256SUMS` | Checksums de todos os arquivos | conferidos antes de qualquer restauração |

**Não entram no backup:** mensagens que estão nas filas do RabbitMQ (só as definições), código dos projetos (fica no Git), registro do runner do GitHub (registre de novo) e preferências do RedisInsight.

**Regras de segurança do processo**
- Um backup por vez (`flock`); aborta se houver menos de 1 GB livre.
- Se **qualquer** componente falhar, o comando sai com erro e a **retenção não é aplicada** — backups antigos nunca são apagados por causa de um backup ruim.
- Retenção: `BACKUP_KEEP_DAYS` no `.env` (padrão **7** dias). O link `latest` aponta sempre para o último backup completo bem-sucedido.
- Os arquivos contêm segredos (`.env`, chave da CA): diretórios `750` e arquivos `640`, dono `root`, grupo do seu usuário — só você e o root leem.

**Comandos**

```bash
sudo /opt/homelab/scripts/backup.sh                  # backup completo agora
sudo /opt/homelab/scripts/backup.sh redis rabbitmq   # só alguns componentes

systemctl list-timers homelab-backup.timer           # próxima execução
journalctl -u homelab-backup -n 50 --no-pager        # log da última execução
ls -l /opt/homelab/backups/                          # backups disponíveis
```

**Restaurar** (pede confirmação digitando `SIM`; `--yes` pula):

```bash
sudo /opt/homelab/scripts/restore.sh latest mysql
sudo /opt/homelab/scripts/restore.sh 2026-10-01_030512 redis
sudo /opt/homelab/scripts/restore.sh latest rabbitmq
sudo /opt/homelab/scripts/restore.sh latest coolify  # extrai e mostra o procedimento oficial
sudo /opt/homelab/scripts/restore.sh latest config   # só extrai em /tmp para comparar — não sobrescreve nada
```

| Componente | O que a restauração faz |
|---|---|
| `mysql` | Sobrescreve todos os bancos **e usuários** com o dump |
| `redis` | Para o Redis, troca os dados do volume, carrega o snapshot sem AOF, regenera o AOF a partir da memória e sobe de novo (*trocar só o `dump.rdb` não funciona com AOF ativo — o Redis ignoraria o snapshot*) |
| `rabbitmq` | Importa as definições (mescla com as existentes) |
| `coolify` | Guiado: extrai banco e `/data/coolify` e mostra os passos (APP_KEY, `pg_restore`) |
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

> ⚠️ O SSD guarda segredos sem criptografia (`.env`, chave privada da CA, senha do Wi-Fi, chave APP_KEY do Coolify). Guarde-o como guardaria as senhas.

### Recuperação total (L14 novo ou SSD interno trocado)

```bash
# 1. Instale o Ubuntu Server, clone o repositório e conecte o SSD de backup
sudo mkdir -p /mnt/backup-ssd && sudo mount /dev/sdX1 /mnt/backup-ssd

# 2. Recupere o .env ANTES do setup (as senhas antigas são reaproveitadas)
sudo mkdir -p /opt/homelab/infra
sudo tar xzf /mnt/backup-ssd/homelab/latest/config.tar.gz -C / opt/homelab/infra/.env opt/homelab/ca
sudo umount /mnt/backup-ssd                      # a CA volta junto: os dispositivos continuam confiando

# 3. Rode o setup e reconfigure o SSD (sem --format!)
sudo ./homelab-setup.sh
sudo /opt/homelab/scripts/backup-disk-setup.sh /dev/sdX1

# 4. Restaure os dados
B=/mnt/backup-ssd/homelab/latest
for c in mysql redis rabbitmq; do sudo /opt/homelab/scripts/restore.sh $B $c --yes; done
sudo /opt/homelab/scripts/restore.sh $B config   # compare SSH/UFW/netplan e copie o que precisar
sudo /opt/homelab/scripts/restore.sh $B coolify  # segue os passos exibidos (banco + APP_KEY)
sudo /opt/homelab/scripts/homelab-ca.sh issue    # reinstala o certificado da LAN no Traefik
```

Depois, no Coolify, faça *Redeploy* das aplicações (os volumes de dados das apps vêm dos backups de cada projeto).

---

## 12. GitHub Actions — runner self-hosted

O setup cria o usuário `gh-runner` (grupo `docker`) e baixa o runner em `/opt/actions-runner`. Para registrar:

1. GitHub: **repositório → Settings → Actions → Runners → New self-hosted runner** (ou na organização). Copie o token (vale 1 hora).
2. No L14:
   ```bash
   sudo /opt/homelab/scripts/register-runner.sh https://github.com/eduferrari/<repo> <TOKEN>
   ```

Uso típico: o job de deploy chama a API local do Coolify (seção 7.6).

> ⚠️ Nunca use runner self-hosted em **repositório público** (um PR de terceiro executaria código no servidor). O `gh-runner` está no grupo `docker` — equivale a root.

---

## 13. Migração da versão anterior (Caddy + painel → Coolify)

Para o L14 que já rodava a versão anterior **com o MesaFácil em produção** (tablets acessando pelo IP). Tudo é feito em duas etapas, com rollback.

### Etapa 1 — trocar o proxy (Caddy → Traefik do Coolify), MesaFácil continua igual

Janela estimada: 15–30 min com o MesaFácil fora do ar.

```bash
# 0. Backup e impressão digital da CA atual (anote)
sudo /opt/homelab/scripts/backup.sh
docker exec mesafacil-caddy cat /data/caddy/pki/authorities/local/root.crt | openssl x509 -noout -fingerprint -sha256

# 1. Código novo
cd ~/homelab && git fetch && git checkout feature/coolify && git pull

# 2. Importa a CA do Caddy do MesaFácil (com o Caddy ainda rodando — só lê o volume)
sudo mkdir -p /opt/homelab/scripts && sudo install -m 750 scripts/homelab-ca.sh /opt/homelab/scripts/
sudo /opt/homelab/scripts/homelab-ca.sh import-caddy mesafacil_caddy_data    # SHA-256 deve ser IGUAL ao passo 0

# 3. Libera 80/443: para o Caddy do MesaFácil  ── início da indisponibilidade ──
cd /opt/homelab/apps/mesafacil && docker compose stop caddy

# 4. Setup: remove painel/Caddy da stack, instala o Coolify e o certificado da LAN no Traefik
cd ~/homelab && sudo ./homelab-setup.sh
```

5. **Coolify:** primeiro acesso (seção 7.1) e **portas extras 8081–8083 no proxy** (seção 7.4) → *Restart Proxy*.
6. **Containers do MesaFácil na rede do Coolify** (o Traefik os alcança pelo nome) — no `docker-compose.yml` do MesaFácil, nos serviços `site`, `pdv`, `crm` e `api`:
   ```yaml
       networks: [default, coolify]
   # ...e no fim do arquivo:
   networks:
     coolify:
       external: true
   ```
   ```bash
   cd /opt/homelab/apps/mesafacil && docker compose up -d site pdv crm api
   ```
7. **Rotas do MesaFácil no Traefik** (porta 80 → 443, site na 443, PDV 8081, CRM 8082, API 8083 com SSE sem buffer, somente LAN):
   ```bash
   sudo cp ~/homelab/docs/exemplos/mesafacil-traefik.yaml /data/coolify/proxy/dynamic/mesafacil.yaml
   ```
   O Traefik recarrega sozinho. Ajuste o IP no arquivo se não for `192.168.101.28`.
8. **Teste nos tablets e no Mac**: `https://192.168.101.28`, `:8081`, `:8082`, `:8083` (sem aviso de certificado) e a chamada de garçom (SSE).  ── fim da indisponibilidade ──

**Rollback** (volta ao estado anterior em segundos):

```bash
docker stop coolify-proxy
cd /opt/homelab/apps/mesafacil && docker compose start caddy
```

Depois de validar: remova o serviço `caddy` e o `Caddyfile` do repositório do MesaFácil (o volume `mesafacil_caddy_data` pode ficar como cópia da CA por um tempo).

### Etapa 2 — MesaFácil gerenciado pelo Coolify (quando a etapa 1 estiver estável)

1. **Projects → New → Docker Compose** apontando para o repositório do MesaFácil (APIs .NET com Dockerfile — seção 7.2). Variáveis de ambiente no Coolify.
2. Rotas por **labels** nos serviços (seção 7.5), uma por sistema (`p8081` PDV, `p8082` CRM, `p8083` API, `https` + `Host(...)` para o site).
3. Pare o compose antigo, faça o deploy pelo Coolify, teste e **remova** `/data/coolify/proxy/dynamic/mesafacil.yaml` (as labels o substituem).
4. Deploy automático: runner + API (seção 7.6).

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
| Setup: *Coolify NÃO instalado: portas em uso* | Algo ocupa 80/443/8000/8080 (ex.: `mesafacil-caddy`). `sudo ss -tlnp \| grep -E ':(80\|443\|8000\|8080) '`, pare o processo e rode o setup de novo (seção 13) |
| Coolify: *Server is not reachable* ao validar | SSH do root a partir dos containers: `sudo sshd -T \| grep -E 'permitrootlogin\|allowusers'` (deve ter `prohibit-password` e `root@10.0.0.0/8`) e `sudo grep coolify /root/.ssh/authorized_keys` |
| Adminer não abre na 8080 | Mudou para **8088** (a 8080 é do painel do Traefik) |
| App no Coolify não conecta no MySQL/Redis | Use o **IP fixo da LAN** (não `.local`); confira usuário/senha do `.env` |
| Navegador/tablet: certificado inválido | CA não instalada no dispositivo, ou o IP mudou: `sudo /opt/homelab/scripts/homelab-ca.sh` (status) e `issue` |
| Acesso pelo IP falha com erro de TLS | `/data/coolify/proxy/dynamic/homelab-lan.yaml` ausente: `sudo /opt/homelab/scripts/homelab-ca.sh issue` |
| `404 page not found` (Traefik) | Nenhuma rota casou: confira entrypoint/rule das labels ou do arquivo em `dynamic/`; `docker logs coolify-proxy --tail 50` |
| `502 Bad Gateway` (Traefik) | O container de destino não está numa rede do Coolify ou a porta está errada |
| `403 Forbidden` na LAN | O middleware `homelab-lan-only` não reconhece a origem (ex.: rede fora das faixas privadas) |
| Let's Encrypt não emite | DNS aponta para `177.101.139.43`? Portas 80/443 encaminhadas? `public-access.sh status`? Sem CGNAT? `docker logs coolify-proxy \| grep -i acme` |
| `network-static.sh`: a rede voltou sozinha | Não houve `--confirm` em 5 min. Confira IP/gateway e aplique de novo |
| `permission denied ... docker.sock` | Faltou reiniciar (ou logout/login) após a instalação |
| `Connection refused` no SSH | `sudo ss -tlnp \| grep :22` e `sudo fail2ban-client unban --all` |
| Backup terminou com código 2 | SSD externo não montado: conecte e rode `sudo /opt/homelab/scripts/backup.sh --sync-external` |
| Backup falhou | `journalctl -u homelab-backup -n 50` mostra o componente com `✘` |
| `<host>.local` não resolve | `systemctl status avahi-daemon`; containers nunca resolvem `.local` |

Log da instalação: `/var/log/homelab-setup.log`

---

## Licença

Distribuído sob a licença Apache 2.0 — veja [LICENSE](LICENSE).
