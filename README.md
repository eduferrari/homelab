# Homelab — ThinkPad L14

Manual de instalação e uso do script `homelab-setup.sh`, que transforma o ThinkPad L14 em um servidor de desenvolvimento com Docker, MySQL, Redis e RabbitMQ.

---

## 1. Visão geral

| Componente | Versão / Imagem | Porta | Acesso |
|---|---|---|---|
| Ubuntu Server | 24.04 LTS (recomendado) | — | — |
| Docker Engine + Compose | repositório oficial Docker | — | `docker compose` |
| MySQL | `mysql:8.4` | 3306 | cliente MySQL / aplicações |
| Adminer | `adminer:latest` | 8080 | `http://<host>:8080` |
| Redis | `redis:7-alpine` | 6379 | cliente Redis / aplicações |
| RedisInsight | `redis/redisinsight:latest` | 5540 | `http://<host>:5540` |
| RabbitMQ (AMQP) | `rabbitmq:4-management` | 5672 | aplicações |
| RabbitMQ Management | (mesma imagem) | 15672 | `http://<host>:15672` |
| Caddy (proxy + HTTPS) | `caddy:2-alpine` | 80, 443, 8081–8089 | `https://<host>` — sites de cada projeto (seção 8.3) |
| **Homepage** (painel) | `ghcr.io/gethomepage/homepage` | 9000 | `https://<host>:9000` — página inicial do homelab |
| **Portainer CE** | `portainer/portainer-ce:lts` | 9001 | `https://<host>:9001` — containers, logs, console |
| **Uptime Kuma** | `louislam/uptime-kuma:1` | 9002 | `https://<host>:9002` — monitoramento e alertas |
| **Cockpit** | pacote `cockpit` (host) | 9090 | `https://<host>:9090` — serviços, discos, atualizações |
| SSH | OpenSSH | 22 | `ssh <usuario>@<host>` |

`<host>` é o nome mDNS do servidor: `<hostname>.local` (ex.: `homelab-eduardo.local`). Ele continua válido mesmo quando o IP muda — veja a seção 8.1.

Todos os containers ficam na rede Docker **`devnet`** e usam **volumes nomeados persistentes** — os dados sobrevivem a `docker compose down`, reboots e atualizações de imagem.

---

## 2. Pré-requisitos

1. **Ubuntu Server 24.04 LTS** instalado no L14 (22.04 também funciona; Ubuntu Desktop funciona, mas o script muda o boot para modo texto).
   - Na instalação, marque **"Install OpenSSH server"**.
2. Um usuário comum com `sudo` (o que você criou na instalação).
3. **Conexão por cabo de rede** (recomendado; Wi-Fi funciona, mas é menos estável). IP fixo é opcional: o script ativa mDNS, então o servidor é acessado por `<hostname>.local`. Se tiver acesso ao roteador, uma *reserva DHCP* pelo MAC (`ip link`) ainda ajuda.
4. Notebook ligado na tomada.

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

No L14, clone o repositório e execute:

```bash
ssh <usuario>@<IP>
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/eduferrari/homelab.git
cd homelab
chmod +x homelab-setup.sh
sudo ./homelab-setup.sh
```

Alternativa sem git (download direto do script):

```bash
curl -fsSLO https://raw.githubusercontent.com/eduferrari/homelab/develop/homelab-setup.sh
chmod +x homelab-setup.sh && sudo ./homelab-setup.sh
```

Ao final, **reinicie**:

```bash
sudo reboot
```

O reboot aplica: grupo `docker` para o seu usuário, boot em modo texto, configuração da tampa e desligamento automático da tela.

> O script é **idempotente**: pode ser executado de novo sem perder dados nem regerar senhas.

### Opções (variáveis de ambiente)

```bash
sudo HOMELAB_USER=eduardo INSTALL_TLP=false ./homelab-setup.sh
```

| Variável | Padrão | Descrição |
|---|---|---|
| `HOMELAB_USER` | usuário que chamou o `sudo` | Dono dos arquivos e único usuário permitido no SSH |
| `HOMELAB_DIR` | `/opt/homelab` | Raiz da infraestrutura |
| `TIMEZONE` | `America/Sao_Paulo` | Fuso horário do sistema e containers |
| `DOCKER_NETWORK` | `devnet` | Nome da rede Docker |
| `SSH_PORT` | `22` | Porta do SSH |
| `DISABLE_SSH_PASSWORD` | `auto` | `auto` / `true` / `false` |
| `HEADLESS` | `true` | Desativa o boot gráfico se existir |
| `INSTALL_TLP` | `true` | Instala TLP e limita carga da bateria |
| `BATTERY_START_THRESHOLD` / `BATTERY_STOP_THRESHOLD` | `75` / `80` | Faixa de carga da bateria (%) |
| `CONSOLE_BLANK_SECONDS` | `60` | Desliga a tela após N segundos (0 = nunca) |
| `PREPARE_GH_RUNNER` | `true` | Baixa e prepara o runner do GitHub Actions |
| `GH_RUNNER_USER` | `gh-runner` | Usuário dedicado do runner |

---

## 5. O que o script faz (passo a passo)

| # | Etapa | Detalhes |
|---|---|---|
| 1 | Sistema base | `apt upgrade`, pacotes úteis (git, jq, htop, btop, tmux, tcpdump, netcat…), mDNS (`avahi-daemon`), timezone, atualizações automáticas de segurança, `sysctl` (swappiness 10, `vm.overcommit_memory=1` para o Redis, limites de inotify) |
| 2 | Modo servidor | Boot em `multi-user.target` (sem interface gráfica) |
| 3 | Tampa / energia | `logind` ignora a tampa; suspensão e hibernação mascaradas; tela desliga em 60s; **TLP** limita a bateria a 75–80% (ela não fica em 100% o tempo todo) e desliga economia de energia de Wi-Fi/USB |
| 4 | SSH | Serviço clássico (`ssh.service`, sem socket), root bloqueado, `MaxAuthTries 3`, só `HOMELAB_USER` pode entrar, senha desativada se houver chave; **fail2ban** bane após 5 falhas por 1h (IPs da LAN ficam de fora) |
| 5 | Docker | Docker CE + Buildx + Compose plugin do repositório oficial; rotação de logs (10 MB × 3); `live-restore` |
| 6 | Firewall | UFW: entrada negada, saída liberada, SSH com rate-limit, mDNS só da LAN; integração UFW+Docker (ver seção 8.2) |
| 7 | Diretórios | Estrutura da seção 6 |
| 8 | Rede | `docker network create devnet` |
| 9 | Stack | Gera `.env` com senhas aleatórias, `docker-compose.yml`, `my.cnf`, Caddyfile base + snippets, painel (Homepage, Portainer, Uptime Kuma, Cockpit), scripts utilitários e o backup diário (`homelab-backup.timer`) |
| 10 | Subida | `docker compose up -d --wait` (aguarda os healthchecks) |
| 11 | GitHub Actions | Usuário `gh-runner`, download da última versão do runner e script de registro |

---

## 6. Estrutura de diretórios

```text
/opt/homelab/
├── infra/
│   ├── docker-compose.yml      # stack de serviços
│   ├── .env                    # credenciais (chmod 640 — NÃO versionar)
│   ├── mysql/
│   │   ├── conf.d/homelab.cnf  # utf8mb4, buffer pool, etc.
│   │   └── init/               # .sql/.sh executados na 1ª criação do banco
│   ├── homepage/               # config do Homepage (services/settings/bookmarks são seus)
│   ├── portainer/admin_password # senha inicial do admin (do .env)
│   └── caddy/
│       ├── Caddyfile           # base da plataforma (gerado — não editar)
│       └── sites/
│           ├── 00-snippets.caddy      # snippets: sse, security_headers
│           ├── 10-homelab-admin.caddy # sites do painel (gerado)
│           ├── _exemplo.caddy.txt     # modelo de site de projeto
│           └── <projeto>.caddy        # um arquivo por projeto
├── apps/                       # destino de deploy dos seus projetos (CI/CD)
├── backups/                    # root:<seu grupo> 750 — contém segredos
│   ├── AAAA-MM-DD_HHMMSS/      # um diretório por backup (ver seção 9.1)
│   └── latest -> ...           # último backup COMPLETO bem-sucedido
└── scripts/
    ├── status.sh               # visão rápida do homelab
    ├── backup.sh               # backup completo ou por componente (root)
    ├── restore.sh              # restauração por componente (root)
    ├── backup-disk-setup.sh    # prepara o SSD externo (comando separado)
    ├── backup-mysql.sh         # atalho para "backup.sh mysql" (compatibilidade)
    ├── caddy-reload.sh         # valida e recarrega o Caddy
    ├── caddy-ca.sh             # exporta a CA interna + impressão digital
    └── register-runner.sh      # registra o runner do GitHub Actions

~/projects/
├── apps/      # clones de aplicações
├── libs/      # bibliotecas / pacotes
└── sandbox/   # experimentos

/mnt/backup-ssd/homelab/        # cópia dos backups no SSD externo (seção 9.1)
/opt/actions-runner/            # runner do GitHub Actions
/var/log/homelab-setup.log      # log da instalação
```

---

## 7. Acesso aos serviços

Veja as credenciais geradas:

```bash
cat /opt/homelab/infra/.env
```

Substitua `<host>` por `<hostname>.local` (ex.: `homelab-eduardo.local`) ou pelo IP atual (`hostname -I`).

### 7.1 Adminer (MySQL) — `http://<host>:8080`

| Campo | Valor |
|---|---|
| Sistema | MySQL |
| Servidor | `mysql` |
| Usuário | `root` ou `dev` |
| Senha | `MYSQL_ROOT_PASSWORD` ou `MYSQL_PASSWORD` |
| Base de dados | `appdb` (ou em branco) |

### 7.2 RedisInsight — `http://<host>:5540`

O banco **homelab-redis** já deve aparecer pré-configurado. Se não aparecer, clique em **Add Redis database**:

| Campo | Valor |
|---|---|
| Host | `redis` |
| Port | `6379` |
| Username | *(em branco)* |
| Password | `REDIS_PASSWORD` |

### 7.3 RabbitMQ Management — `http://<host>:15672`

| Campo | Valor |
|---|---|
| Username | `admin` (`RABBITMQ_DEFAULT_USER`) |
| Password | `RABBITMQ_DEFAULT_PASS` |

### 7.4 Painel de administração

Quatro ferramentas, cada uma no que faz melhor, todas servidas pelo Caddy com o HTTPS da CA interna (instale a CA no dispositivo — seção 8.3) e acessíveis **somente pela LAN**:

| Endereço | Ferramenta | Login |
|---|---|---|
| `https://<host>:9000` | **Homepage** — início: links, status dos containers, CPU/RAM/temperatura/disco (inclusive o SSD de backup) | sem login (somente leitura) |
| `https://<host>:9001` | **Portainer** — containers, logs, console, volumes, imagens | `admin` / `PORTAINER_ADMIN_PASSWORD` do `.env` |
| `https://<host>:9002` | **Uptime Kuma** — monitores e alertas | crie o admin **no primeiro acesso** |
| `https://<host>:9090` | **Cockpit** — host: serviços systemd, logs (`journalctl`), discos, atualizações, terminal | seu usuário Linux (`eduardo`) |

> ⚠️ Faça o primeiro acesso ao **Uptime Kuma** logo após a instalação: até o admin ser criado, qualquer um na LAN pode criá-lo.

#### Homepage

- `services.yaml`, `settings.yaml` e `bookmarks.yaml` em `/opt/homelab/infra/homepage/` são **seus**: o setup só os cria se não existirem. Adicione seus sistemas em *Projetos*; as mudanças aparecem ao recarregar a página.
- `docker.yaml` e `widgets.yaml` são da plataforma (regenerados pelo setup). O widget do SSD de backup aparece depois de configurar o SSD e rodar o setup de novo.
- O status dos containers vem de um **socket proxy somente leitura** (`dockerproxy`, rede interna `mgmt` sem saída): o Homepage não consegue alterar nada no Docker.

#### Uptime Kuma — alerta de backup

O `backup.sh` avisa o Kuma ao fim de cada backup completo (`up` = OK, `down` = falhou ou SSD indisponível). Para ativar:

1. No Kuma: **Add New Monitor → Push**, nome `Backup homelab`, **Heartbeat Interval = 93600** (26 h) — sem aviso nesse prazo, ele alerta.
2. Copie o token do *Push URL* (o trecho depois de `/api/push/`, antes do `?`).
3. No L14:
   ```bash
   sudo sed -i 's|^UPTIME_KUMA_PUSH_TOKEN=.*|UPTIME_KUMA_PUSH_TOKEN=<token>|' /opt/homelab/infra/.env
   sudo /opt/homelab/scripts/backup.sh     # testa: o monitor fica verde
   ```
4. Em **Settings → Notifications**, configure Telegram/e-mail/Discord e associe ao monitor.

Monitores sugeridos (o Kuma está na `devnet`, então usa os nomes dos containers):

| Tipo | Alvo |
|---|---|
| TCP Port | `mysql:3306`, `redis:6379`, `rabbitmq:5672` |
| HTTP(s) | `http://rabbitmq:15672`, `http://<container-do-projeto>:<porta>` (seus sistemas) |
| Docker Container | *opcional* — exige montar o socket no Kuma; prefira TCP/HTTP |

#### Segurança

- **Portainer tem controle total do Docker** (equivale a root no servidor): senha forte (gerada) e acesso só pela LAN. Ative 2FA em *My account*.
- O Cockpit escuta em `:9091` apenas para as redes Docker (regra UFW); o acesso do usuário é sempre pelo Caddy (HTTPS).
- Os dados do Portainer e do Kuma entram no backup diário (componente `mgmt`).

### 7.5 Conexão a partir das aplicações

**De fora do Docker** (sua máquina, Rider, testes locais) — use o nome `.local` do L14:

```text
MySQL     Server=<host>;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis     <host>:6379,password=<REDIS_PASSWORD>
RabbitMQ  amqp://admin:<RABBITMQ_DEFAULT_PASS>@<host>:5672/
```

**De dentro da rede `devnet`** (containers das suas APIs) — use o nome do serviço:

```text
MySQL     Server=mysql;Port=3306;Database=appdb;User=dev;Password=<MYSQL_PASSWORD>;
Redis     redis:6379,password=<REDIS_PASSWORD>
RabbitMQ  amqp://admin:<RABBITMQ_DEFAULT_PASS>@rabbitmq:5672/
```

Exemplo de `docker-compose.yml` de um projeto usando a rede:

```yaml
services:
  api:
    build: .
    ports:
      - "5000:8080"
    environment:
      ConnectionStrings__Default: "Server=mysql;Database=appdb;User=dev;Password=${MYSQL_PASSWORD}"
    networks: [devnet]

networks:
  devnet:
    external: true
```

> **MySQL 8.4:** o plugin `mysql_native_password` vem desativado; o padrão é `caching_sha2_password`. `MySqlConnector` e Pomelo (EF Core) suportam normalmente. Se algum cliente antigo reclamar, adicione `AllowPublicKeyRetrieval=True;SslMode=None;` na connection string (apenas em ambiente de dev).

---

## 8. Rede

### 8.1 Acesso por nome (mDNS)

O script instala o `avahi-daemon`: o L14 anuncia `<hostname>.local` na LAN e libera `5353/udp` no UFW apenas para redes privadas. macOS resolve `.local` nativamente; Linux precisa de `libnss-mdns`; Windows 10+ também resolve.

```bash
ping -c 2 homelab-eduardo.local       # do Mac
```

O anúncio é **só IPv4** (`use-ipv6=no` no avahi): pelo IPv6 as portas dos containers seriam barradas pelo UFW e cada conexão esperaria um timeout antes de cair no IPv4.

Use sempre o nome nas connection strings: sem acesso ao roteador, o IP pode mudar a cada reboot (DHCP).

> Containers **dentro** do Docker (rede `devnet`) não resolvem `.local` — entre containers use os nomes dos serviços (`mysql`, `redis`, `rabbitmq`).

### 8.2 Firewall — como funciona

O Docker publica portas diretamente no `iptables` e **ignora as regras do UFW**. Para evitar que os bancos fiquem expostos, o script adiciona o bloco padrão *ufw-docker* em `/etc/ufw/after.rules`:

- Portas dos containers são acessíveis **somente de redes privadas**: `192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12` e `100.64.0.0/10` (Tailscale).
- Acessos vindos de IPs públicos são **bloqueados e registrados** (`[UFW DOCKER BLOCK]` no `journalctl -k`).
- Portas do próprio host (SSH) seguem as regras normais do UFW.

Comandos úteis:

```bash
sudo ufw status verbose
sudo ufw allow 9100/tcp comment 'Exemplo'     # liberar porta do HOST
sudo journalctl -k | grep "UFW DOCKER BLOCK"  # ver bloqueios
```

> Para acesso remoto fora de casa, prefira **Tailscale** ou WireGuard em vez de abrir portas no roteador.

---

### 8.3 Proxy reverso e HTTPS (Caddy)

O Caddy roda como container da stack, na rede `devnet`, e é a **porta de entrada HTTPS** dos projetos. Ele usa uma **CA interna** (`local_certs`) para emitir certificados válidos para `<hostname>.local` **e** para o IP da LAN.

**Divisão de responsabilidades**

| Onde | O quê |
|---|---|
| Este repositório (plataforma) | Container, Caddyfile base, snippets, volume da CA, scripts de reload/exportação |
| Cada projeto (`deploy/homelab/*.caddy`) | Os sites: portas, upstreams, SSE, headers |

**Portas publicadas:** `80` (redireciona para HTTPS), `443` e a faixa `CADDY_APP_PORTS` (padrão `8081-8089`, no `.env`) para sistemas em porta própria. Não é preciso regra no UFW: como são portas de container, valem as regras da seção 8.2 (somente LAN).

#### Publicar um projeto

1. O container do projeto entra na rede `devnet` **sem publicar portas** (o Caddy chega a ele pelo nome):
   ```yaml
   services:
     api:
       build: .
       container_name: api
       networks: [devnet]
   networks:
     devnet:
       external: true
   ```
2. Crie o site em `/opt/homelab/infra/caddy/sites/<projeto>.caddy` (modelo em `_exemplo.caddy.txt`). Use `{$HOMELAB_HOST}` e `{$HOMELAB_IP}` — o setup atualiza o IP no `.env` a cada execução:
   ```caddyfile
   # Site principal (443; a 80 redireciona)
   {$HOMELAB_HOST}, {$HOMELAB_IP} {
   	import security_headers
   	reverse_proxy site:8080
   }

   # API com SSE, sem buffer
   {$HOMELAB_HOST}:8083, {$HOMELAB_IP}:8083 {
   	reverse_proxy api:8080 {
   		import sse
   	}
   }
   ```
   Arquivos de site têm **só blocos de site** — opções globais (`local_certs` etc.) já estão no Caddyfile base.
3. Recarregue (valida antes; se houver erro, nada é aplicado):
   ```bash
   /opt/homelab/scripts/caddy-reload.sh
   ```

> Se o IP mudar (DHCP), rode o setup novamente para atualizar `HOMELAB_IP` e recrie o Caddy (`docker compose up -d caddy`). O nome `.local` não é afetado.

#### Instalar a CA nos dispositivos

```bash
/opt/homelab/scripts/caddy-ca.sh      # gera infra/caddy/homelab-root-ca.crt e mostra o SHA-256
scp eduardo@<host>:/opt/homelab/infra/caddy/homelab-root-ca.crt .   # no Mac
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain homelab-root-ca.crt         # macOS
```

Confira a impressão digital antes de confiar. Instruções para Windows, Firefox e Android ficam no `deploy/homelab/README.md` de cada projeto. A CA vive no volume `homelab_caddy_data`: **não o apague**, ou todos os dispositivos precisarão da CA nova.

#### Migrar um Caddy existente

Se já existir um Caddy rodando (instalado via `apt` ou em outro compose), o setup **não sobe** o container da stack para não disputar a porta 443 — e avisa. Para migrar **mantendo a mesma CA** (os dispositivos continuam confiando):

```bash
cd /opt/homelab/infra
docker compose create caddy                         # cria o volume homelab_caddy_data

# A) Caddy instalado no host (apt)
sudo systemctl disable --now caddy
docker run --rm -v homelab_caddy_data:/data -v /var/lib/caddy/.local/share/caddy:/src:ro \
  alpine sh -c 'mkdir -p /data/caddy && cp -a /src/. /data/caddy/'

# B) Caddy em outro compose — copie do volume de dados dele (/data)
# docker stop <caddy-antigo>
# docker run --rm -v homelab_caddy_data:/data -v <volume-antigo>:/src:ro \
#   alpine sh -c 'cp -a /src/. /data/'

# Sites: mova os blocos do Caddyfile antigo para sites/<projeto>.caddy,
# removendo opções globais e trocando upstreams localhost:PORTA pelo nome do container na devnet
docker compose up -d caddy && /opt/homelab/scripts/caddy-reload.sh
/opt/homelab/scripts/caddy-ca.sh                    # a impressão digital deve ser a mesma de antes
```

---

## 9. Operação do dia a dia

```bash
cd /opt/homelab/infra

docker compose ps                     # status
docker compose logs -f rabbitmq       # logs de um serviço
docker compose restart redis          # reiniciar um serviço
docker compose pull && docker compose up -d   # atualizar imagens
docker compose down                   # parar tudo (dados preservados)

/opt/homelab/scripts/status.sh        # resumo geral (containers, firewall, disco, bateria)
```

### 9.1 Backup e restauração

Um backup completo roda **todo dia às 03:00** (`homelab-backup.timer`, systemd, com até 15 min de atraso aleatório; se o L14 estiver desligado, roda ao ligar). Ele grava em `/opt/homelab/backups/AAAA-MM-DD_HHMMSS/` (disco interno) e, em seguida, **copia para o SSD externo** (veja *SSD externo* abaixo):

| Arquivo | Conteúdo | Como é gerado |
|---|---|---|
| `mysql-all.sql.gz` | Todos os bancos, usuários, rotinas, triggers e eventos | `mysqldump --single-transaction` (sem travar as tabelas) — validado pela linha `Dump completed` |
| `redis-dump.rdb.gz` | Snapshot do Redis | `BGSAVE` consistente, sem parar o serviço |
| `rabbitmq-definitions.json` | vhosts, usuários, permissões, filas, exchanges, bindings, policies | `rabbitmqctl export_definitions` |
| `caddy-data.tar.gz` | **CA interna** + certificados do Caddy | cópia do volume `caddy_data` (ou de `/var/lib/caddy` se o Caddy for do host) |
| `portainer-data.tar.gz`, `uptime-kuma-data.tar.gz` | Usuários, configurações, monitores e histórico do painel | para o container por alguns segundos (bancos embarcados) e copia o volume |
| `config.tar.gz` | `.env`, compose, `my.cnf`, Caddyfile e sites, SSH, UFW, fail2ban, Docker, avahi, TLP, tampa, sysctl, netplan (Wi-Fi), units do backup | `tar` |
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
sudo /opt/homelab/scripts/restore.sh latest caddy
sudo /opt/homelab/scripts/restore.sh latest mgmt     # Portainer + Uptime Kuma
sudo /opt/homelab/scripts/restore.sh latest config   # só extrai em /tmp para comparar — não sobrescreve nada
```

| Componente | O que a restauração faz |
|---|---|
| `mysql` | Sobrescreve todos os bancos **e usuários** com o dump |
| `redis` | Para o Redis, troca os dados do volume, carrega o snapshot sem AOF, regenera o AOF a partir da memória e sobe de novo (*trocar só o `dump.rdb` não funciona com AOF ativo — o Redis ignoraria o snapshot*) |
| `rabbitmq` | Importa as definições (mescla com as existentes) |
| `caddy` | Substitui a CA e os certificados — confira depois com `caddy-ca.sh` |
| `mgmt` | Substitui os dados do Portainer e do Uptime Kuma |

#### SSD externo

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

> ⚠️ O SSD guarda segredos sem criptografia (`.env`, chave privada da CA do Caddy, senha do Wi-Fi). Guarde-o como guardaria as senhas.

#### Recuperação total (L14 novo ou SSD interno trocado)

```bash
# 1. Instale o Ubuntu Server, clone o repositório e conecte o SSD de backup
sudo mkdir -p /mnt/backup-ssd && sudo mount /dev/sdX1 /mnt/backup-ssd

# 2. Recupere o .env ANTES do setup (as senhas antigas são reaproveitadas)
sudo mkdir -p /opt/homelab/infra
sudo tar xzf /mnt/backup-ssd/homelab/latest/config.tar.gz -C / opt/homelab/infra/.env
sudo umount /mnt/backup-ssd

# 3. Rode o setup e reconfigure o SSD (sem --format!)
sudo ./homelab-setup.sh
sudo /opt/homelab/scripts/backup-disk-setup.sh /dev/sdX1

# 4. Restaure os dados
B=/mnt/backup-ssd/homelab/latest
for c in mysql redis rabbitmq caddy mgmt; do sudo /opt/homelab/scripts/restore.sh $B $c --yes; done
sudo /opt/homelab/scripts/restore.sh $B config   # compare SSH/UFW/netplan e copie o que precisar
```

### Volumes

```bash
docker volume ls | grep homelab
# homelab_mysql_data, homelab_redis_data, homelab_redisinsight_data, homelab_rabbitmq_data
```

> ⚠️ `docker compose down -v` **apaga os volumes** e todos os dados.

### Trocar senhas

As senhas no `.env` só são usadas na **primeira criação** dos volumes do MySQL e RabbitMQ. Para trocar depois, altere dentro do serviço (Adminer / RabbitMQ UI) **e** atualize o `.env`. O Redis lê a senha a cada início: basta editar o `.env` e rodar `docker compose up -d`.

---

## 10. GitHub Actions (self-hosted runner)

O script já baixou o runner em `/opt/actions-runner` com o usuário dedicado `gh-runner` (membro do grupo `docker`).

### Registrar

1. No GitHub: **repositório → Settings → Actions → Runners → New self-hosted runner** (ou na organização, para usar em vários repositórios).
2. Copie o **token** exibido (válido por 1 hora).
3. No L14:

```bash
sudo /opt/homelab/scripts/register-runner.sh https://github.com/eduferrari/<repo> <TOKEN>
# opcionais: [NOME] [LABELS]  — padrão de labels: homelab,linux,x64,docker
```

O runner é instalado como serviço `systemd` e sobe sozinho no boot.

### Exemplo de workflow (.NET 8 + deploy no homelab)

`.github/workflows/deploy.yml`:

```yaml
name: build-and-deploy

on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest          # build/test na nuvem do GitHub
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 8.0.x
      - run: dotnet test --configuration Release

  deploy:
    needs: test
    runs-on: [self-hosted, homelab]  # deploy no L14
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        run: |
          mkdir -p /opt/homelab/apps/${{ github.event.repository.name }}
          rsync -a --delete ./ /opt/homelab/apps/${{ github.event.repository.name }}/
          cd /opt/homelab/apps/${{ github.event.repository.name }}
          docker compose up -d --build
      - name: Publicar site no Caddy
        run: |
          cp deploy/homelab/*.caddy /opt/homelab/infra/caddy/sites/
          /opt/homelab/scripts/caddy-reload.sh
```

### Segurança do runner

- ⚠️ **Nunca** use runner self-hosted em **repositórios públicos**: um PR de terceiro poderia executar código no seu servidor.
- O usuário `gh-runner` está no grupo `docker`, o que equivale a acesso root. Mantenha o runner restrito aos seus repositórios privados.

Gerenciar o serviço:

```bash
cd /opt/actions-runner
sudo ./svc.sh status
sudo ./svc.sh stop | start
```

---

## 11. Tampa fechada e bateria

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

## 12. Solução de problemas

| Sintoma | Causa provável / solução |
|---|---|
| `permission denied ... docker.sock` | Faltou reiniciar após a instalação (ou faça logout/login) |
| UI não abre de outra máquina | Teste `ping <hostname>.local`; confira o IP atual (`hostname -I`) e `docker compose ps` |
| `Connection refused` em **todas** as portas, mas o SSH pelo Terminal funciona | Permissão de **Rede Local** do macOS: *Ajustes do Sistema → Privacidade e Segurança → Rede Local* — libere o app (Rider, Claude, iTerm…) e reabra-o |
| 1ª tentativa dá *timeout* e a 2ª conecta | O nome resolveu para IPv6. Confira `use-ipv6=no` em `/etc/avahi/avahi-daemon.conf` e limpe o cache no Mac: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder` |
| `<hostname>.local` não resolve | `systemctl status avahi-daemon` e `sudo ufw status \| grep 5353` |
| Servidor mudou de IP | Esperado com DHCP — use `<hostname>.local` |
| Diagnóstico de rede | `sudo tcpdump -ni any host <IP-do-cliente> -c 20` no L14 e `nc -vz <host> 3306` no cliente |
| Container `unhealthy` | `docker compose logs <serviço>` |
| Homepage mostra *Host validation failed* | Acesse pelo nome `.local` ou pelo IP atual; se o IP mudou, rode o setup (atualiza `HOMEPAGE_ALLOWED_HOSTS`) |
| Cockpit: tela em branco ou *Connection failed* | Origem fora da lista: rode o setup (atualiza `Origins` em `/etc/cockpit/cockpit.conf`) e confira `sudo ufw status \| grep 9091` |
| Portainer pede para criar admin / senha não funciona | A senha do `.env` só vale na 1ª inicialização; depois troque pela UI. Para recomeçar: `docker compose rm -sf portainer && docker volume rm homelab_portainer_data && docker compose up -d portainer` |
| Uptime Kuma não recebe o aviso do backup | `UPTIME_KUMA_PUSH_TOKEN` no `.env` e `curl -s http://127.0.0.1:3001/api/push/<token>` no L14 |
| `502 Bad Gateway` no Caddy | O upstream não está na `devnet` ou o nome/porta estão errados: `docker network inspect devnet` e confira `reverse_proxy <container>:<porta-interna>` |
| Container `caddy` não subiu no setup | Outro Caddy/servidor ocupa a 443 — veja *Migrar um Caddy existente* (seção 8.3) |
| Navegador acusa certificado inválido | A CA não está instalada no dispositivo, ou o volume `caddy_data` foi recriado (CA nova) — rode `caddy-ca.sh` e reinstale |
| Certificado não vale para o IP novo | Rode o setup (atualiza `HOMELAB_IP`) e `docker compose up -d caddy` |
| Backup falhou | `journalctl -u homelab-backup -n 50` mostra o componente com `✘`; corrija e rode `sudo /opt/homelab/scripts/backup.sh <componente>` |
| Backup terminou com código 2 / `SSD externo não está montado` | Conecte o SSD e rode `sudo mount /mnt/backup-ssd && sudo /opt/homelab/scripts/backup.sh --sync-external` |
| SSD não monta no boot | `lsblk -f` (o UUID mudou? reformatado?) — rode de novo `backup-disk-setup.sh /dev/sdX1`; o fstab anterior fica em `/etc/fstab.homelab.bak` |
| `Checksum inválido` no restore | Arquivo do backup corrompido — use outro backup (`ls /opt/homelab/backups`) |
| `Permission denied` ao listar backups | Esperado para outros usuários; use o seu usuário ou `sudo` |
| RabbitMQ perdeu filas após recriar | O `hostname: rabbitmq` foi alterado — o nó grava os dados pelo nome |
| RedisInsight sem o banco pré-cadastrado | Adicione manualmente (seção 7.2) |
| Notebook suspendeu com a tampa fechada | Rode `systemctl status systemd-logind` e reinicie; confirme a seção 11 |
| `Connection refused` no SSH | `sudo ss -tlnp \| grep :22` (sshd escutando?) e `sudo fail2ban-client unban --all` |
| Bloqueado fora do SSH | Acesse pelo teclado local e revise `/etc/ssh/sshd_config.d/00-homelab.conf` |
| Porta 8080 conflita com uma API | Altere `ADMINER_PORT` no `.env` e rode `docker compose up -d` |

Log completo da instalação: `/var/log/homelab-setup.log`

---

## Licença

Distribuído sob a licença Apache 2.0 — veja [LICENSE](LICENSE).
