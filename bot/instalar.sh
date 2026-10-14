#!/usr/bin/env bash
# Instala o "atende" v4 no lugar do bot atual (porta 3100), sem trocar o webhook do Chatwoot.
# Usa o MESMO arquivo .env do bot antigo (lido no lugar, não copiado). O bot antigo fica parado e guardado.
# Uso (como root):  curl -fsSL https://privoutlets.com.br/bot/instalar.sh | bash -s <segredo-do-webhook>
# Voltar ao antigo: bash /opt/atende/voltar.sh
set -euo pipefail

SECRET_ARG="${1:-}"
SRC="${ATENDE_SRC:-https://privoutlets.com.br/bot/atende-v4.tgz}"
DEST="${ATENDE_DIR:-/opt/atende}"
PORT="${ATENDE_PORT:-3100}"
TEST_PORT=3199
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mERRO: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "rode como root"

say "1/7 Node.js"
NODE="$(command -v node || true)"
if [ -z "$NODE" ] || [ "$("$NODE" -p 'process.versions.node.split(".")[0]')" -lt 18 ]; then
  echo "Node 18+ não encontrado; instalando Node 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
  apt-get install -y nodejs >/dev/null
  NODE="$(command -v node)"
fi
echo "node $("$NODE" -v)"

say "2/7 Bot atual na porta $PORT"
OLD_KIND=none; OLD_REF=""; OLD_DIR=""; OLD_PID=""; PM2="pm2"
CID="$(docker ps --format '{{.ID}} {{.Ports}}' 2>/dev/null | grep -E "[:.]$PORT->" | awk '{print $1}' | head -1 || true)"
if [ -n "$CID" ]; then
  OLD_KIND=docker; OLD_REF="$CID"
else
  OLD_PID="$(ss -ltnpH "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)"
  if [ -n "$OLD_PID" ]; then
    OLD_DIR="$(readlink -f "/proc/$OLD_PID/cwd" || true)"
    UNIT="$(grep -o '[^/]*\.service' "/proc/$OLD_PID/cgroup" 2>/dev/null | head -1 || true)"
    PARENT="$(ps -o ppid= -p "$OLD_PID" | tr -d ' ')"
    if [ "$UNIT" = "atende.service" ]; then
      OLD_KIND=self; OLD_REF=atende
    elif ps -o args= -p "$PARENT" 2>/dev/null | grep -q 'PM2'; then
      PM2_HOME_="$(ps -o args= -p "$PARENT" | grep -o '(/[^)]*)' | tr -d '()' || true)"
      NODEBIN="$(dirname "$(readlink -f "/proc/$PARENT/exe")")"
      PM2BIN="$(command -v pm2 || true)"; [ -x "$NODEBIN/pm2" ] && PM2BIN="$NODEBIN/pm2"
      PM2="env ${PM2_HOME_:+PM2_HOME=$PM2_HOME_} PATH=$NODEBIN:$PATH $PM2BIN"
      NAME="$($PM2 jlist 2>/dev/null | "$NODE" -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s.slice(s.indexOf("["))).find(x=>x.pid==process.argv[1]);if(p)console.log(p.name)}catch{}})' "$OLD_PID" || true)"
      if [ -n "$NAME" ] && [ -n "$PM2BIN" ]; then OLD_KIND=pm2; OLD_REF="$NAME"; else OLD_KIND=process; OLD_REF="$OLD_PID"; fi
    elif [ -n "$UNIT" ] && ! echo "$UNIT" | grep -qE '^(session-|user@|ssh|cron|pm2-)'; then
      OLD_KIND=systemd; OLD_REF="$UNIT"
    else
      OLD_KIND=process; OLD_REF="$OLD_PID"
    fi
  fi
fi
echo "encontrado: $OLD_KIND ${OLD_REF} ${OLD_DIR}"

say "3/7 Baixando a versão nova"
TMPD="$(mktemp -d)"
curl -fsSL "$SRC" -o "$TMPD/atende.tgz"
[ -d "$DEST/src" ] && cp -a "$DEST" "${DEST}.anterior.$(date +%Y%m%d%H%M)"
mkdir -p "$DEST"
tar xzf "$TMPD/atende.tgz" -C "$DEST" --strip-components=1
mkdir -p "$DEST/data"

say "4/7 Configuração"
if [ ! -f "$DEST/.env" ]; then
  OLD_ENV=""
  for f in "$OLD_DIR/.env" "$OLD_DIR/../.env"; do [ -n "$OLD_DIR" ] && [ -f "$f" ] && { OLD_ENV="$(readlink -f "$f")"; break; }; done
  {
    echo "# atende v4. Chaves e tokens continuam no arquivo do bot antigo (ENV_EXTRA)."
    echo "PORT=$PORT"
    echo "DATA_DIR=$DEST/data"
    [ -n "$SECRET_ARG" ] && echo "HOOK_SECRET=$SECRET_ARG"
    [ -n "$OLD_ENV" ] && echo "ENV_EXTRA=$OLD_ENV"
  } > "$DEST/.env"
  chmod 600 "$DEST/.env"
  echo "usando configuração de: ${OLD_ENV:-(nenhum .env antigo encontrado)}"
elif [ -n "$SECRET_ARG" ] && ! grep -q '^HOOK_SECRET=' "$DEST/.env"; then
  echo "HOOK_SECRET=$SECRET_ARG" >> "$DEST/.env"
fi

say "5/7 Teste da versão nova (porta $TEST_PORT)"
livre() { kill $(ss -ltnpH "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2) 2>/dev/null || true; }
livre "$TEST_PORT"; sleep 1
( cd "$DEST" && PORT=$TEST_PORT DATA_DIR="$TMPD/data" exec "$NODE" src/server.js > "$TMPD/teste.log" 2>&1 ) &
echo $! > "$TMPD/pid"
H=""
for i in $(seq 1 20); do sleep 1; H="$(curl -fsS "http://127.0.0.1:$TEST_PORT/health" 2>/dev/null || true)"; echo "$H" | grep -q '"versao":4' && break; done
kill "$(cat "$TMPD/pid")" 2>/dev/null || true; sleep 1; livre "$TEST_PORT"
echo "$H" | grep -q '"versao":4' || { cat "$TMPD/teste.log"; die "a versão nova não subiu no teste; o bot antigo continua ativo, nada foi trocado"; }
echo "$H"
echo "$H" | grep -q '"chatwoot":true' || die "token do robô do Chatwoot não encontrado. Coloque CHATWOOT_BOT_TOKEN=... em $DEST/.env e rode de novo. Nada foi trocado."
echo "$H" | grep -q '"intencoes":0' && die "pacote de respostas vazio; nada foi trocado"
echo "$H" | grep -q '"ia":true' || echo "AVISO: sem chave de IA. O bot responde o que já sabe e passa o resto para a equipe."

say "6/7 Trocando o bot (o antigo fica guardado)"
case "$OLD_KIND" in
  self)    STOP=":"; START="" ;;
  docker)  STOP="docker update --restart=no $OLD_REF >/dev/null; docker stop $OLD_REF >/dev/null"; START="docker update --restart=unless-stopped $OLD_REF >/dev/null; docker start $OLD_REF >/dev/null" ;;
  pm2)     STOP="$PM2 stop '$OLD_REF' >/dev/null; $PM2 save >/dev/null"; START="$PM2 start '$OLD_REF' >/dev/null; $PM2 save >/dev/null" ;;
  systemd) STOP="systemctl disable --now '$OLD_REF'"; START="systemctl enable --now '$OLD_REF'" ;;
  process) CMDLINE="$(tr '\0' ' ' < "/proc/$OLD_PID/cmdline")"; STOP="kill $OLD_PID"; START="cd '$OLD_DIR' && nohup $CMDLINE > /var/log/bot-antigo.log 2>&1 &" ;;
  *)       STOP=":"; START=":" ;;
esac
if [ "$OLD_KIND" != self ]; then
  cat > "$DEST/voltar.sh" <<EOF
#!/usr/bin/env bash
# Volta para o bot antigo ($OLD_KIND $OLD_REF)
systemctl disable --now atende 2>/dev/null || true
$START
echo "bot antigo religado"
EOF
  chmod +x "$DEST/voltar.sh"
fi
bash -c "$STOP" || true
sleep 1
cat > /etc/systemd/system/atende.service <<EOF
[Unit]
Description=atende v4 - bot de atendimento
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$DEST
ExecStart=$NODE src/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable atende >/dev/null 2>&1
systemctl restart atende

say "7/7 Conferindo"
H=""
for i in $(seq 1 20); do sleep 1; H="$(curl -fsS "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"; echo "$H" | grep -q '"versao":4' && break; done
if ! echo "$H" | grep -q '"versao":4'; then
  journalctl -u atende -n 30 --no-pager || true
  [ -f "$DEST/voltar.sh" ] && bash "$DEST/voltar.sh"
  die "a versão nova não respondeu na porta $PORT; voltei o bot antigo"
fi
echo "$H"
printf '\n\033[32mPRONTO: atende v4 no ar na porta %s.\033[0m\n' "$PORT"
echo "Logs:      journalctl -u atende -f"
echo "Relatório: cd $DEST && node src/tools/relatorio.js 7"
echo "Voltar:    bash $DEST/voltar.sh"
