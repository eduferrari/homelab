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
| 9 | Stack | Gera `.env` com senhas aleatórias, `docker-compose.yml`, `my.cnf` e scripts utilitários |
| 10 | Subida | `docker compose up -d --wait` (aguarda os healthchecks) |
| 11 | GitHub Actions | Usuário `gh-runner`, download da última versão do runner e script de registro |

---

## 6. Estrutura de diretórios

```text
/opt/homelab/
├── infra/
│   ├── docker-compose.yml      # stack de serviços
│   ├── .env                    # credenciais (chmod 640 — NÃO versionar)
│   └── mysql/
│       ├── conf.d/homelab.cnf  # utf8mb4, buffer pool, etc.
│       └── init/               # .sql/.sh executados na 1ª criação do banco
├── apps/                       # destino de deploy dos seus projetos (CI/CD)
├── backups/mysql/              # dumps gerados pelo backup-mysql.sh
└── scripts/
    ├── status.sh               # visão rápida do homelab
    ├── backup-mysql.sh         # backup de todos os bancos (retém 7 dias)
    └── register-runner.sh      # registra o runner do GitHub Actions

~/projects/
├── apps/      # clones de aplicações
├── libs/      # bibliotecas / pacotes
└── sandbox/   # experimentos

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

### 7.4 Conexão a partir das aplicações

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
sudo ufw allow 9000/tcp comment 'Portainer'   # liberar porta do HOST
sudo journalctl -k | grep "UFW DOCKER BLOCK"  # ver bloqueios
```

> Para acesso remoto fora de casa, prefira **Tailscale** ou WireGuard em vez de abrir portas no roteador.

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

### Backup do MySQL

```bash
/opt/homelab/scripts/backup-mysql.sh
```

Agendar diariamente às 3h (`crontab -e`):

```cron
0 3 * * * /opt/homelab/scripts/backup-mysql.sh >> /opt/homelab/backups/backup.log 2>&1
```

Restaurar:

```bash
gunzip -c /opt/homelab/backups/mysql/mysql-AAAA-MM-DD_HHMM.sql.gz \
  | docker exec -i -e MYSQL_PWD='<MYSQL_ROOT_PASSWORD>' mysql mysql -uroot
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
