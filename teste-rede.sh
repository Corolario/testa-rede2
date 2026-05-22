#!/usr/bin/env bash
#
# teste-rede.sh - Testa conectividade (ping) e largura de banda (iperf3)
#                 contra uma lista de servidores e gera dois arquivos de log.
#
# Uso:
#   ./teste-rede.sh            # ping + iperf3 (download e upload)
#   ./teste-rede.sh -p         # somente ping
#   ./teste-rede.sh -i         # somente iperf3
#   ./teste-rede.sh -h         # ajuda
#
# Requisitos: iputils-ping (ping) e iperf3 instalados.
#   Debian/Ubuntu: sudo apt install iperf3 iputils-ping
#   Fedora:        sudo dnf install iperf3 iputils
#   Arch:          sudo pacman -S iperf3 iputils
#
# Saída (em resultados-rede_AAAAMMDD_HHMMSS/):
#   resumo.txt    -> tabela-resumo legível
#   completo.log  -> saída bruta de todos os testes + resumo, na ordem

set -uo pipefail

# ----------------------------------------------------------------------
# Configuração
# ----------------------------------------------------------------------
SERVIDORES=(
    "148.230.60.200:30000"
    "speedtest.sao1.edgoo.net:9221"
    "138.199.4.1:5201"
)

PING_COUNT=10               # pacotes ICMP por teste de ping
IPERF_TIME=10               # duração de cada teste do iperf3 (segundos)
IPERF_CONNECT_TIMEOUT=5000  # ms para o handshake de controle do iperf3
PAUSA_ENTRE_DIRECOES=2      # segundos entre download e upload — evita
                            # "Connection reset by peer" enquanto o
                            # iperf3-server ainda finaliza a sessão anterior

CARIMBO="$(date '+%Y%m%d_%H%M%S')"
RESULT_DIR="resultados-rede_${CARIMBO}"
RESUMO_TXT="${RESULT_DIR}/resumo.txt"
COMPLETO_LOG="${RESULT_DIR}/completo.log"

declare -a PING_RESUMO=()    # "host|perda|rtt_medio"
declare -a IPERF_RESUMO=()   # "host|porta|download|upload"

# ----------------------------------------------------------------------
# Cores (desativadas se a saída não for um terminal)
# ----------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_TITULO="\033[1;36m" ; C_OK="\033[1;32m" ; C_ERRO="\033[1;31m"
    C_INFO="\033[0;33m" ; C_RESET="\033[0m"
else
    C_TITULO="" ; C_OK="" ; C_ERRO="" ; C_INFO="" ; C_RESET=""
fi

# ----------------------------------------------------------------------
# Auxiliares
# ----------------------------------------------------------------------
linha()     { printf '%s\n' "----------------------------------------------------------------------"; }
cabecalho() { echo; linha; echo -e "${C_TITULO}$1${C_RESET}"; linha; }

verifica_dependencias() {
    local faltando=()
    command -v ping   >/dev/null 2>&1 || faltando+=("ping")
    command -v iperf3 >/dev/null 2>&1 || faltando+=("iperf3")
    if (( ${#faltando[@]} > 0 )); then
        echo -e "${C_ERRO}Erro: comando(s) não encontrado(s): ${faltando[*]}${C_RESET}" >&2
        echo "Instale-os antes de continuar. Ex.: sudo apt install iperf3 iputils-ping" >&2
        exit 1
    fi
}

# Anota um cabeçalho de seção no completo.log
secao() {
    {
        echo
        echo "########## $1 ##########"
    } >> "$COMPLETO_LOG"
}

# ----------------------------------------------------------------------
# Parsers (recebem caminho de arquivo com a saída do comando)
# ----------------------------------------------------------------------
parse_ping() {
    local f="$1" perda="?" rtt="?"
    if [[ -f "$f" ]]; then
        perda="$(grep -oE '[0-9]+(\.[0-9]+)?% packet loss' "$f" | grep -oE '^[0-9.]+' | head -1)"
        rtt="$(grep -E 'rtt|round-trip' "$f" | sed -E 's#.*= *##; s# *ms.*##' | cut -d'/' -f2 | head -1)"
        [[ -z "$perda" ]] && perda="?"
        [[ -z "$rtt"   ]] && rtt="?"
    fi
    echo "${perda}|${rtt}"
}

parse_iperf() {
    local f="$1" taxa="FALHOU"
    if [[ -f "$f" ]]; then
        local linha_res
        linha_res="$(grep -E 'receiver' "$f" | tail -1)"
        if [[ -n "$linha_res" ]]; then
            taxa="$(echo "$linha_res" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){print $(i-1)" "$i; exit}}')"
            [[ -z "$taxa" ]] && taxa="FALHOU"
        fi
    fi
    echo "$taxa"
}

# ----------------------------------------------------------------------
# Testes
# ----------------------------------------------------------------------
testa_ping() {
    cabecalho "TESTE DE PING ( ${PING_COUNT} pacotes por servidor )"
    for entrada in "${SERVIDORES[@]}"; do
        local host="${entrada%%:*}"
        local tmp; tmp="$(mktemp)"
        echo -e "${C_INFO}>> Ping em ${host}${C_RESET}"
        secao "ping ${host}"
        if ping -c "$PING_COUNT" -W 2 "$host" 2>&1 | tee -a "$COMPLETO_LOG" "$tmp"; then
            echo -e "${C_OK}   [OK] ${host} respondeu.${C_RESET}"
        else
            echo -e "${C_ERRO}   [FALHA] ${host} não respondeu.${C_RESET}"
        fi
        PING_RESUMO+=("${host}|$(parse_ping "$tmp")")
        rm -f "$tmp"
        echo
    done
}

testa_iperf() {
    cabecalho "TESTE DE IPERF3 ( ${IPERF_TIME}s por direção )"
    for entrada in "${SERVIDORES[@]}"; do
        local host="${entrada%%:*}"
        local porta="${entrada##*:}"
        local tmp_dl tmp_ul
        tmp_dl="$(mktemp)"; tmp_ul="$(mktemp)"

        echo -e "${C_INFO}>> Servidor ${host} (porta ${porta})${C_RESET}"

        echo "   --- Download (servidor -> cliente) ---"
        secao "iperf ${host}:${porta} download"
        iperf3 -c "$host" -p "$porta" -t "$IPERF_TIME" -R \
               --connect-timeout "$IPERF_CONNECT_TIMEOUT" 2>&1 \
               | tee -a "$COMPLETO_LOG" "$tmp_dl" \
            || echo -e "${C_ERRO}   [FALHA] no download com ${host}:${porta}${C_RESET}"
        echo

        sleep "$PAUSA_ENTRE_DIRECOES"

        echo "   --- Upload (cliente -> servidor) ---"
        secao "iperf ${host}:${porta} upload"
        iperf3 -c "$host" -p "$porta" -t "$IPERF_TIME" \
               --connect-timeout "$IPERF_CONNECT_TIMEOUT" 2>&1 \
               | tee -a "$COMPLETO_LOG" "$tmp_ul" \
            || echo -e "${C_ERRO}   [FALHA] no upload com ${host}:${porta}${C_RESET}"
        echo

        IPERF_RESUMO+=("${host}|${porta}|$(parse_iperf "$tmp_dl")|$(parse_iperf "$tmp_ul")")
        rm -f "$tmp_dl" "$tmp_ul"
    done
}

# ----------------------------------------------------------------------
# Resumo (tela + resumo.txt + anexado ao completo.log)
# ----------------------------------------------------------------------
gera_resumo() {
    cabecalho "RESUMO"
    {
        echo "Resumo dos testes de rede - ${CARIMBO}"
        echo

        if (( ${#PING_RESUMO[@]} > 0 )); then
            echo "PING:"
            printf '  %-28s %-10s %-12s\n' "Servidor" "Perda" "RTT medio"
            printf '  %-28s %-10s %-12s\n' "--------" "-----" "---------"
            for item in "${PING_RESUMO[@]}"; do
                IFS='|' read -r host perda rtt <<< "$item"
                local perda_fmt="$perda" rtt_fmt="$rtt"
                [[ "$perda" != "?" ]] && perda_fmt="${perda}%"
                [[ "$rtt"   != "?" ]] && rtt_fmt="${rtt} ms"
                printf '  %-28s %-10s %-12s\n' "$host" "$perda_fmt" "$rtt_fmt"
            done
            echo
        fi

        if (( ${#IPERF_RESUMO[@]} > 0 )); then
            echo "IPERF3:"
            printf '  %-28s %-7s %-16s %-16s\n' "Servidor" "Porta" "Download" "Upload"
            printf '  %-28s %-7s %-16s %-16s\n' "--------" "-----" "--------" "------"
            for item in "${IPERF_RESUMO[@]}"; do
                IFS='|' read -r host porta down up <<< "$item"
                printf '  %-28s %-7s %-16s %-16s\n' "$host" "$porta" "$down" "$up"
            done
            echo
        fi
    } | tee "$RESUMO_TXT"

    # Anexa o resumo ao final do completo.log
    {
        echo
        echo "########## resumo.txt ##########"
        cat "$RESUMO_TXT"
    } >> "$COMPLETO_LOG"
}

# ----------------------------------------------------------------------
# Ajuda
# ----------------------------------------------------------------------
ajuda() {
    cat <<EOF
Uso: $(basename "$0") [opção]

Sem opção   Roda ping + iperf3 (download e upload) em todos os servidores.
  -p        Somente teste de ping.
  -i        Somente teste de iperf3.
  -h        Mostra esta ajuda.

Saída em: ${RESULT_DIR:-resultados-rede_AAAAMMDD_HHMMSS}/
  resumo.txt    -> tabela-resumo legível
  completo.log  -> saída bruta de todos os testes + resumo

Servidores configurados:
$(for s in "${SERVIDORES[@]}"; do echo "  - ${s%%:*} (porta iperf3: ${s##*:})"; done)
EOF
}

# ----------------------------------------------------------------------
# Programa principal
# ----------------------------------------------------------------------
main() {
    verifica_dependencias

    local rodar_ping=true rodar_iperf=true
    case "${1:-}" in
        -p) rodar_iperf=false ;;
        -i) rodar_ping=false  ;;
        -h|--help) ajuda; exit 0 ;;
        "" ) ;;
        *  ) echo -e "${C_ERRO}Opção inválida: $1${C_RESET}"; echo; ajuda; exit 1 ;;
    esac

    mkdir -p "$RESULT_DIR"
    echo "==== LOG COMPLETO - ${CARIMBO} ====" > "$COMPLETO_LOG"

    echo -e "${C_TITULO}Início dos testes: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
    echo -e "${C_INFO}Resultados serão salvos em: ${RESULT_DIR}/${C_RESET}"

    $rodar_ping  && testa_ping
    $rodar_iperf && testa_iperf

    gera_resumo

    cabecalho "TESTES CONCLUÍDOS"
    echo -e "${C_INFO}Arquivos gravados em: ${RESULT_DIR}/${C_RESET}"
    echo -e "${C_TITULO}Fim: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
}

main "$@"
