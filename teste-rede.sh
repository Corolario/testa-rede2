#!/usr/bin/env bash
#
# teste-rede.sh - Testa conectividade (ping) e largura de banda (iperf3)
#                 contra uma lista de servidores, salva os resultados em
#                 arquivos e exibe um resumo final.
#
# Uso:
#   ./teste-rede.sh            # roda todos os testes (ping + iperf3 download e upload)
#   ./teste-rede.sh -p         # somente ping
#   ./teste-rede.sh -i         # somente iperf3
#   ./teste-rede.sh -h         # ajuda
#
# Requisitos: iputils-ping (ping) e iperf3 instalados.
#   Debian/Ubuntu: sudo apt install iperf3 iputils-ping
#   Fedora:        sudo dnf install iperf3 iputils
#   Arch:          sudo pacman -S iperf3 iputils
#
# Os resultados são gravados em um diretório:
#   resultados-rede_AAAAMMDD_HHMMSS/
#       ping_<host>.log              -> saída bruta de cada ping
#       iperf_<host>_download.log    -> saída bruta do iperf3 (download)
#       iperf_<host>_upload.log      -> saída bruta do iperf3 (upload)
#       resumo.txt                   -> tabela-resumo legível
#       completo.log                 -> tudo concatenado

set -uo pipefail

# ----------------------------------------------------------------------
# Servidores: "host:porta"  (a porta é usada apenas pelo iperf3)
# ----------------------------------------------------------------------
SERVIDORES=(
    "148.230.60.200:30000"
    "speedtest.sao1.edgoo.net:9221"
    "138.199.4.1:5201"
)

PING_COUNT=10       # pacotes ICMP por teste de ping
IPERF_TIME=10       # duração de cada teste do iperf3 (segundos)
IPERF_PARALELO=4    # número de conexões/streams TCP paralelas (flag -P do iperf3)
IPERF_TENTATIVAS=5  # número máximo de tentativas em caso de falha
IPERF_RETRY_DELAY=2 # segundos de espera entre tentativas

# ----------------------------------------------------------------------
# Diretório de resultados
# ----------------------------------------------------------------------
CARIMBO="$(date '+%Y%m%d_%H%M%S')"
RESULT_DIR="resultados-rede_${CARIMBO}"
RESUMO_TXT="${RESULT_DIR}/resumo.txt"
COMPLETO_LOG="${RESULT_DIR}/completo.log"

# Arrays que acumulam os dados para o resumo final
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
# Funções auxiliares
# ----------------------------------------------------------------------
linha()    { printf '%s\n' "----------------------------------------------------------------------"; }
cabecalho(){ echo; linha; echo -e "${C_TITULO}$1${C_RESET}"; linha; }

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

# ----------------------------------------------------------------------
# Parsers para o resumo
# ----------------------------------------------------------------------
# Extrai "perda% rtt_medio_ms" de um arquivo de ping. Campos ausentes viram "?".
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

# Extrai a taxa (ex.: "944 Mbits/sec") da linha de resumo "receiver" do iperf3.
# Com -P > 1, a linha relevante é "[SUM] ... receiver"; com -P 1, é só "... receiver".
parse_iperf() {
    local f="$1" taxa="FALHOU"
    if [[ -f "$f" ]]; then
        local linha_res
        # Tenta primeiro a linha [SUM] receiver (várias streams)
        linha_res="$(grep -E '\[SUM\].*receiver' "$f" | tail -1)"
        # Se não existir, cai para a linha receiver simples (1 stream)
        [[ -z "$linha_res" ]] && linha_res="$(grep -E 'receiver' "$f" | tail -1)"
        if [[ -n "$linha_res" ]]; then
            taxa="$(echo "$linha_res" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){print $(i-1)" "$i; exit}}')"
            [[ -z "$taxa" ]] && taxa="FALHOU"
        fi
    fi
    echo "$taxa"
}

# ----------------------------------------------------------------------
# Teste de PING
# ----------------------------------------------------------------------
testa_ping() {
    cabecalho "TESTE DE PING ( ${PING_COUNT} pacotes por servidor )"
    for entrada in "${SERVIDORES[@]}"; do
        local host="${entrada%%:*}"
        local arq="${RESULT_DIR}/ping_${host}.log"
        echo -e "${C_INFO}>> Ping em ${host}${C_RESET}"
        if ping -c "$PING_COUNT" -W 2 "$host" 2>&1 | tee "$arq"; then
            echo -e "${C_OK}   [OK] ${host} respondeu.${C_RESET}"
        else
            echo -e "${C_ERRO}   [FALHA] ${host} não respondeu.${C_RESET}"
        fi
        local dados; dados="$(parse_ping "$arq")"
        PING_RESUMO+=("${host}|${dados}")
        echo
    done
}

# ----------------------------------------------------------------------
# Executa o iperf3 com retentativas em caso de falha
# Uso: roda_iperf_com_retry <arquivo_log> <args do iperf3...>
# Retorna 0 se algum dos attempts terminar bem, ou o código de erro do iperf3.
# ----------------------------------------------------------------------
roda_iperf_com_retry() {
    local arq="$1"; shift
    local tentativa=1 status=1

    : > "$arq"  # limpa o arquivo no início

    while (( tentativa <= IPERF_TENTATIVAS )); do
        if (( tentativa > 1 )); then
            echo -e "${C_INFO}   Falha. Aguardando ${IPERF_RETRY_DELAY}s e tentando de novo (${tentativa}/${IPERF_TENTATIVAS})...${C_RESET}"
            sleep "$IPERF_RETRY_DELAY"
            echo ""                                                  | tee -a "$arq"
            echo "===== Tentativa ${tentativa}/${IPERF_TENTATIVAS} =====" | tee -a "$arq"
        fi
        iperf3 "$@" 2>&1 | tee -a "$arq"
        status=${PIPESTATUS[0]}
        (( status == 0 )) && return 0
        ((tentativa++))
    done
    return $status
}

# ----------------------------------------------------------------------
# Teste de IPERF3
# ----------------------------------------------------------------------
testa_iperf() {
    cabecalho "TESTE DE IPERF3 ( ${IPERF_TIME}s por direção, ${IPERF_PARALELO} stream(s) )"
    for entrada in "${SERVIDORES[@]}"; do
        local host="${entrada%%:*}"
        local porta="${entrada##*:}"
        local arq_dl="${RESULT_DIR}/iperf_${host}_download.log"
        local arq_ul="${RESULT_DIR}/iperf_${host}_upload.log"

        echo -e "${C_INFO}>> Servidor ${host} (porta ${porta})${C_RESET}"

        echo "   --- Download (servidor -> cliente) ---"
        roda_iperf_com_retry "$arq_dl" -c "$host" -p "$porta" -t "$IPERF_TIME" -P "$IPERF_PARALELO" -R \
            || echo -e "${C_ERRO}   [FALHA] no download com ${host}:${porta} após ${IPERF_TENTATIVAS} tentativas${C_RESET}"
        echo

        echo "   --- Upload (cliente -> servidor) ---"
        roda_iperf_com_retry "$arq_ul" -c "$host" -p "$porta" -t "$IPERF_TIME" -P "$IPERF_PARALELO" \
            || echo -e "${C_ERRO}   [FALHA] no upload com ${host}:${porta} após ${IPERF_TENTATIVAS} tentativas${C_RESET}"
        echo

        local down up
        down="$(parse_iperf "$arq_dl")"
        up="$(parse_iperf "$arq_ul")"
        IPERF_RESUMO+=("${host}|${porta}|${down}|${up}")
    done
}

# ----------------------------------------------------------------------
# Resumo final (impresso na tela e gravado em resumo.txt)
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
}

# ----------------------------------------------------------------------
# Monta o completo.log concatenando tudo
# ----------------------------------------------------------------------
monta_completo() {
    {
        echo "==== LOG COMPLETO - ${CARIMBO} ===="
        echo
        for f in "${RESULT_DIR}"/ping_*.log "${RESULT_DIR}"/iperf_*.log; do
            [[ -f "$f" ]] || continue
            echo "########## $(basename "$f") ##########"
            cat "$f"
            echo
        done
        echo "########## resumo.txt ##########"
        [[ -f "$RESUMO_TXT" ]] && cat "$RESUMO_TXT"
    } > "$COMPLETO_LOG"
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

Os resultados são salvos em: resultados-rede_AAAAMMDD_HHMMSS/

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

    echo -e "${C_TITULO}Início dos testes: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
    echo -e "${C_INFO}Resultados serão salvos em: ${RESULT_DIR}/${C_RESET}"

    $rodar_ping  && testa_ping
    $rodar_iperf && testa_iperf

    gera_resumo
    monta_completo

    cabecalho "TESTES CONCLUÍDOS"
    echo -e "${C_INFO}Arquivos gravados em: ${RESULT_DIR}/${C_RESET}"
    echo -e "${C_TITULO}Fim: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
}

main "$@"
