#!/usr/bin/env bash
#
# Copyright (c) 2026, syameimaru-ayaya. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

# ----------------- 0. 安全防呆拦截与帮助信息 -----------------
# 原因：
# 1. 最小权限原则：多媒体拉流与播放是高风险操作，绝不能以超级用户执行；
# 2. VLC 官方二进制程序内置安全校验，硬编码拒绝以 root 身份启动 (报 "VLC is not supposed to be run as root. Sorry.")。
if [[ $EUID -eq 0 ]]; then
    echo -e "\n\033[1;31m[安全拦截] 严禁以 root 身份直接执行本脚本！\033[0m"
    echo -e "\033[1;33m说明：VLC 播放器原生拒绝 root 权限运行。安装依赖时脚本会自动按需提权，无需手动加 sudo。\033[0m"
    echo -e "\033[1;32m请切换为普通用户后重新执行: ./thmr-cli-linux.sh\033[0m\n"
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "用法: $0 [频道序号或ID] [音频源 1/2] [码率序号或ID] [网络协议 1/2/3]"
    echo "  频道:   启动时自动从服务端拉取最新启用频道 (支持传序号 1..N 或频道 ID 如 touhou)"
    echo "  音频源: 1 = 国内音频源 (默认), 2 = 国际音频源"
    echo "  码率:   按所选频道可用码率动态列表 (默认 1 = 最高音质，通常 1=320k, 2=128k, 3=96k)"
    echo "  协议:   1 = 强制 IPv4, 2 = 强制 IPv6, 3 = 自动双栈 (默认)"
    echo "示例:"
    echo "  $0                # 全交互式引导启动"
    echo "  $0 1 1 1 3        # 第1个频道 + 国内源 + 最高音质 + 自动双栈 (快速启动)"
    echo "  $0 touhou-curated 1 128k 3  # 按频道 ID 与码率 ID 直接启动"
    exit 0
fi

API_BASE="https://radio.yunmoan.cn"
ACCOUNT_API_BASE="https://thmr.yunmoan.cn"
API_CHANNELS_URL="${ACCOUNT_API_BASE}/api/channels"
API_STATIONS_URL="${API_BASE}/api/stations"
CACHE_DIR="$HOME/.cache/thmr-cli"
CONTACT_CACHE_FILE="$CACHE_DIR/contact"
FIFO_PATH="/tmp/radio_stream_${UID}.fifo"
VLC_SOCK="/tmp/vlc_ctrl_${UID}.sock"
LOG_FILE=$(mktemp /tmp/curl_radio_log.XXXXXX)
STATUS_FILE=$(mktemp /tmp/thmr_status.XXXXXX)
STATUS_RAW=$(mktemp /tmp/thmr_raw.XXXXXX)
CHANNELS_RAW=$(mktemp /tmp/thmr_channels.XXXXXX)
STATIONS_RAW=$(mktemp /tmp/thmr_stations.XXXXXX)

MAIN_PID=$$
CURL_PID=""
VLC_PID=""
STATUS_FETCHER_PID=""
JSON_TOOL=""
MPRIS_PLAYER=""

# ----------------- 1. 依赖检测与「按需局部提权」自动安装 -----------------
detect_json_tool() {
    if command -v jq >/dev/null 2>&1; then
        JSON_TOOL="jq"
    elif command -v python3 >/dev/null 2>&1; then
        JSON_TOOL="python3"
    else
        JSON_TOOL=""
    fi
}

check_dependencies() {
    local missing_deps=()
    local missing_pkgs_deb=()
    local missing_pkgs_rhel=()

    # 1. 探测 curl (流媒体网络拉流与 API 请求)
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
        missing_pkgs_deb+=("curl")
        missing_pkgs_rhel+=("curl")
    fi

    # 2. 探测 vlc / cvlc (流媒体播放核心依赖)
    if ! command -v cvlc >/dev/null 2>&1 && ! command -v vlc >/dev/null 2>&1; then
        missing_deps+=("vlc (cvlc)")
        missing_pkgs_deb+=("vlc")
        missing_pkgs_rhel+=("vlc")
    fi

    # 3. 探测套接字控制工具 (socat 或 nc，用于音量调节)
    if ! command -v socat >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1; then
        missing_deps+=("socat")
        missing_pkgs_deb+=("socat")
        missing_pkgs_rhel+=("socat")
    fi

    # 4. 探测 JSON 解析工具 (jq 或 python3，用于曲目状态与反馈交互)
    detect_json_tool
    if [[ -z "$JSON_TOOL" ]]; then
        missing_deps+=("jq")
        missing_pkgs_deb+=("jq")
        missing_pkgs_rhel+=("jq")
    fi

    # 如有全部依赖：完全不触碰 sudo/root 权限，直接进入后续播放流程
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        return 0
    fi

    # 如没有：探测系统发行版并准备按需提权安装
    echo -e "\033[1;33m[$(date '+%H:%M:%S')] 检测到系统缺少以下依赖: ${missing_deps[*]}\033[0m"
    echo -e "\033[1;34m[$(date '+%H:%M:%S')] 正在探测当前 Linux 发行版类型...\033[0m"

    local os_family=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|linuxmint|kali|deepin|pop|raspbian)
                os_family="debian"
                ;;
            rhel|centos|fedora|rocky|almalinux|ol|amzn)
                os_family="rhel"
                ;;
            *)
                if [[ "${ID_LIKE:-}" =~ debian|ubuntu ]]; then
                    os_family="debian"
                elif [[ "${ID_LIKE:-}" =~ rhel|fedora|centos ]]; then
                    os_family="rhel"
                fi
                ;;
        esac
    fi

    # 备选：根据包管理器命令兜底检测
    if [[ -z "$os_family" ]]; then
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            os_family="debian"
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            os_family="rhel"
        fi
    fi

    local pkg_mgr=""
    local pkgs_to_install=()
    if [[ "$os_family" == "debian" ]]; then
        echo -e "\033[1;32m[$(date '+%H:%M:%S')] 识别为 Debian 系列发行版 (Debian / Ubuntu 等)\033[0m"
        pkg_mgr="apt-get"
        pkgs_to_install=("${missing_pkgs_deb[@]}")
    elif [[ "$os_family" == "rhel" ]]; then
        echo -e "\033[1;32m[$(date '+%H:%M:%S')] 识别为 RHEL 系列发行版 (RHEL / CentOS / Fedora / Rocky 等)\033[0m"
        pkg_mgr="dnf"
        command -v dnf >/dev/null 2>&1 || pkg_mgr="yum"
        pkgs_to_install=("${missing_pkgs_rhel[@]}")
    else
        echo -e "\033[1;31m[错误] 未能识别为 Debian 或 RHEL 系列发行版，无法自动安装依赖。\033[0m"
        echo -e "\033[1;33m请手动安装以下必要工具后重新运行: ${missing_deps[*]}\033[0m"
        exit 1
    fi

    # 核心设计：仅对包管理器单独使用 sudo 提权（按需提权）
    local sudo_cmd=""
    if command -v sudo >/dev/null 2>&1; then
        sudo_cmd="sudo"
        echo -e "\033[1;36m[$(date '+%H:%M:%S')] 正在通过 sudo 申请临时权限安装系统依赖（若有提示请输入当前用户的登录密码）...\033[0m"
        if ! $sudo_cmd -v; then
            echo -e "\n\033[1;31m[错误] sudo 认证失败或当前用户不在 sudoers 白名单中。\033[0m"
            echo -e "\033[1;33m请联系系统管理员代为执行以下安装命令后重新运行：\033[0m"
            if [[ "$os_family" == "debian" ]]; then
                echo -e "  \033[1mapt-get update && apt-get install -y ${pkgs_to_install[*]}\033[0m\n"
            else
                echo -e "  \033[1m$pkg_mgr install -y ${pkgs_to_install[*]}\033[0m\n"
            fi
            exit 1
        fi
    else
        echo -e "\n\033[1;31m[错误] 系统中未安装 sudo 工具，当前普通用户无法自动安装系统软件包。\033[0m"
        echo -e "\033[1;33m请联系系统管理员安装以下依赖后再行运行：\033[0m"
        if [[ "$os_family" == "debian" ]]; then
            echo -e "  \033[1mapt-get update && apt-get install -y ${pkgs_to_install[*]}\033[0m\n"
        else
            echo -e "  \033[1m$pkg_mgr install -y ${pkgs_to_install[*]}\033[0m\n"
        fi
        exit 1
    fi

    # 执行特权安装
    if [[ "$os_family" == "debian" ]]; then
        echo -e "\033[1;34m[$(date '+%H:%M:%S')] 正在通过 apt-get 自动安装: ${pkgs_to_install[*]} ...\033[0m"
        $sudo_cmd apt-get update -y && $sudo_cmd apt-get install -y "${pkgs_to_install[@]}"
    elif [[ "$os_family" == "rhel" ]]; then
        echo -e "\033[1;34m[$(date '+%H:%M:%S')] 正在通过 $pkg_mgr 自动安装: ${pkgs_to_install[*]} ...\033[0m"
        $sudo_cmd "$pkg_mgr" install -y "${pkgs_to_install[@]}"
    fi

    # 安装完成校验
    local still_missing=()
    ! command -v curl >/dev/null 2>&1 && still_missing+=("curl")
    ! command -v cvlc >/dev/null 2>&1 && ! command -v vlc >/dev/null 2>&1 && still_missing+=("vlc")
    ! command -v socat >/dev/null 2>&1 && ! command -v nc >/dev/null 2>&1 && still_missing+=("socat")
    detect_json_tool
    [[ -z "$JSON_TOOL" ]] && still_missing+=("jq")

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        echo -e "\n\033[1;31m[错误] 自动安装未能成功就绪以下工具: ${still_missing[*]}\033[0m"
        echo -e "\033[1;33m请检查网络连接、软件源或手动安装后再次尝试。\033[0m\n"
        exit 1
    fi

    echo -e "\033[1;32m[$(date '+%H:%M:%S')] 依赖安装完成，临时特权已释放，即将以普通用户进入播放流程...\033[0m"
    sleep 1
}

# ----------------- 2. 全局清理钩子 (彻底防残留) -----------------
CLEANED_UP=0
cleanup() {
    [[ "$CLEANED_UP" -eq 1 ]] && exit 0
    CLEANED_UP=1
    trap - INT TERM EXIT

    if [[ -z "$VLC_PID" && -z "$CURL_PID" && ! -S "$VLC_SOCK" ]]; then
        rm -f "$FIFO_PATH" "$VLC_SOCK" "$LOG_FILE" "$STATUS_FILE" "$STATUS_RAW" "$CHANNELS_RAW" "$STATIONS_RAW" 2>/dev/null
        tput cnorm 2>/dev/null
        exit 0
    fi

    echo -e "\n\n\033[1;33m[$(date '+%H:%M:%S')] 正在停止播放并彻底回收资源...\033[0m"

    # 1. 终止状态拉取轮询守护进程
    if [[ -n "$STATUS_FETCHER_PID" ]] && kill -0 "$STATUS_FETCHER_PID" 2>/dev/null; then
        kill -TERM "$STATUS_FETCHER_PID" 2>/dev/null
        wait "$STATUS_FETCHER_PID" 2>/dev/null
    fi

    # 2. 杀死后台 curl 守护进程及子进程
    if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then
        pkill -P "$CURL_PID" 2>/dev/null
        kill -9 "$CURL_PID" 2>/dev/null
    fi

    # 3. 杀死后台 VLC
    if [[ -n "$VLC_PID" ]] && kill -0 "$VLC_PID" 2>/dev/null; then
        if [[ -S "$VLC_SOCK" ]]; then
            send_vlc "quit"
            sleep 0.1
        fi
        kill -9 "$VLC_PID" 2>/dev/null
    fi

    # 4. 关闭文件描述符 3 (释放写端)
    exec 3>&- 2>/dev/null

    # 5. 清理管道文件、套接字、状态缓存与临时日志
    rm -f "$FIFO_PATH" "$VLC_SOCK" "$LOG_FILE" "$STATUS_FILE" "$STATUS_RAW" "$CHANNELS_RAW" "$STATIONS_RAW" 2>/dev/null

    # 6. 恢复终端光标
    tput cnorm 2>/dev/null

    echo -e "\033[1;32m[$(date '+%H:%M:%S')] 进程、套接字与管道已全部清理完毕，安全退出。\033[0m"
    exit 0
}
trap cleanup INT TERM EXIT

# 执行依赖检测与安装
check_dependencies

# ----------------- 3. JSON 解析与交互辅助函数 -----------------
read_prompt() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="${3:-}"
    local input_val=""

    if [ -t 0 ]; then
        read -rp "$prompt_text" input_val
    elif [ -r /dev/tty ] && [ -t 1 ]; then
        read -rp "$prompt_text" input_val < /dev/tty
    else
        input_val="$default_val"
    fi

    printf -v "$var_name" '%s' "$input_val"
}

read_key() {
    local timeout_sec="$1"
    local var_name="$2"
    local pressed=""

    if [ -t 0 ]; then
        if IFS= read -r -s -n 1 -t "$timeout_sec" pressed; then
            printf -v "$var_name" '%s' "$pressed"
            return 0
        fi
    elif [ -r /dev/tty ]; then
        if IFS= read -r -s -n 1 -t "$timeout_sec" pressed < /dev/tty; then
            printf -v "$var_name" '%s' "$pressed"
            return 0
        fi
    else
        sleep "$timeout_sec"
    fi

    printf -v "$var_name" '%s' ""
    return 1
}

parse_status_json() {
    local raw_file="$1"
    if [[ "$JSON_TOOL" == "jq" ]]; then
        jq -r '
            def clean: tostring | gsub("[\t\r\n\u001f]+"; " ");
            [
                ((.current.artist // "") | if . == "" then "未知艺术家" else . end | clean),
                ((.current.title // "") | if . == "" then "未知曲目" else . end | clean),
                (.current.startedAtMs // 0 | tostring),
                (.current.durationSec // 0 | tostring),
                (.totals.listeners // 0 | tostring),
                ((.previous.artist // "") | clean),
                ((.previous.title // "") | clean)
            ] | join("\u001f")
        ' "$raw_file" 2>/dev/null
    else
        python3 - "$raw_file" << 'EOF' 2>/dev/null
import json, sys

def clean(v):
    return " ".join(str(v).replace("\x1f", " ").replace("\t", " ").splitlines())

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    cur = d.get("current") or {}
    prev = d.get("previous") or {}
    totals = d.get("totals") or {}
    artist = clean(cur.get("artist") or "") or "未知艺术家"
    title = clean(cur.get("title") or "") or "未知曲目"
    started = cur.get("startedAtMs") or 0
    dur = cur.get("durationSec") or 0
    listeners = totals.get("listeners")
    if listeners is None:
        listeners = 0
    prev_artist = clean(prev.get("artist") or "")
    prev_title = clean(prev.get("title") or "")
    print("\x1f".join([artist, title, str(started), str(dur), str(listeners), prev_artist, prev_title]))
except Exception:
    pass
EOF
    fi
}

build_feedback_json() {
    local fb_type="$1"
    local fb_contact="$2"
    local fb_msg="$3"
    if [[ "$JSON_TOOL" == "jq" ]]; then
        jq -nc --arg t "$fb_type" --arg c "$fb_contact" --arg m "$fb_msg" \
            '{type: $t, contact: $c, message: $m, pageUrl: "thmr-cli-linux"}' 2>/dev/null
    else
        python3 - "$fb_type" "$fb_contact" "$fb_msg" << 'EOF' 2>/dev/null
import json, sys
print(json.dumps({
    "type": sys.argv[1],
    "contact": sys.argv[2],
    "message": sys.argv[3],
    "pageUrl": "thmr-cli-linux"
}, ensure_ascii=False))
EOF
    fi
}

parse_feedback_json() {
    local resp="$1"
    if [[ "$JSON_TOOL" == "jq" ]]; then
        local parsed
        parsed=$(printf '%s' "$resp" | jq -r '
            if .ok then
                ["OK", (.feedbackId // ""), ((.feedbackCountForTrack // 1) | tostring), ((.autoSkipThreshold // 5) | tostring), (if .autoSkipRequested then "1" else "0" end)] | join("\u001f")
            else
                ["ERR", (.error // "未知错误")] | join("\u001f")
            end
        ' 2>/dev/null)
        if [[ -n "$parsed" ]]; then
            printf '%s\n' "$parsed"
        else
            printf 'ERR\x1f解析响应失败\n'
        fi
    else
        python3 - "$resp" << 'EOF' 2>/dev/null
import json, sys
try:
    d = json.loads(sys.argv[1])
    if d.get("ok"):
        print("\x1f".join([
            "OK",
            str(d.get("feedbackId") or ""),
            str(d.get("feedbackCountForTrack") or 1),
            str(d.get("autoSkipThreshold") or 5),
            "1" if d.get("autoSkipRequested") else "0"
        ]))
    else:
        print("\x1f".join(["ERR", str(d.get("error") or "未知错误")]))
except Exception:
    print("ERR\x1f解析响应失败")
EOF
    fi
}

parse_channels_and_stations() {
    local ch_file="$1"
    local st_file="$2"
    if [[ "$JSON_TOOL" == "jq" ]]; then
        jq -e 'type == "array"' "$ch_file" >/dev/null 2>&1 || printf '[]' > "$ch_file"
        jq -e 'type == "array"' "$st_file" >/dev/null 2>&1 || printf '[]' > "$st_file"
        jq -rn --slurpfile ch "$ch_file" --slurpfile st "$st_file" '
            def clean: tostring | gsub("[\t\r\n\u001f]+"; " ");
            ($ch[0] | if type == "array" then . else [] end) as $channels |
            ($st[0] | if type == "array" then . else [] end) as $stations |
            (reduce $stations[] as $s ({}; if ($s.id // "") != "" then .[$s.id] = $s else . end)) as $stmap |
            ([ $channels[] | select(.enabled == true and (.categorize // "") != "") ]) as $enabled_ch |
            if ($enabled_ch | length) > 0 then
                $enabled_ch[] |
                (.categorize | tostring) as $id |
                ($stmap[$id] // {}) as $s |
                [
                    ($id | clean),
                    ((.name // $s.name // $id) | clean),
                    (if $s.trackCount != null then ($s.trackCount | tostring) else "" end),
                    (if $s.listeners != null then ($s.listeners | tostring) else "" end)
                ] | join("\u001f")
            else
                $stations[] |
                select(.enabled == true and .publicEnabled != false and (.id // "") != "") |
                [
                    (.id | clean),
                    ((.name // .id) | clean),
                    (if .trackCount != null then (.trackCount | tostring) else "" end),
                    (if .listeners != null then (.listeners | tostring) else "" end)
                ] | join("\u001f")
            end
        ' 2>/dev/null
    else
        python3 - "$ch_file" "$st_file" << 'EOF' 2>/dev/null
import json, sys

def clean(v):
    return " ".join(str(v).replace("\x1f", " ").replace("\t", " ").splitlines())

def load_list(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except Exception:
        return []

channels = load_list(sys.argv[1])
stations = load_list(sys.argv[2])
stmap = {str(s["id"]): s for s in stations if isinstance(s, dict) and s.get("id")}

enabled_ch = [c for c in channels if isinstance(c, dict) and c.get("enabled") is True and c.get("categorize")]
if enabled_ch:
    for c in enabled_ch:
        cid = str(c["categorize"])
        s = stmap.get(cid) or {}
        name = clean(c.get("name") or s.get("name") or cid)
        tc = "" if s.get("trackCount") is None else str(s["trackCount"])
        ls = "" if s.get("listeners") is None else str(s["listeners"])
        print("\x1f".join([clean(cid), name, tc, ls]))
else:
    for s in stations:
        if isinstance(s, dict) and s.get("enabled") is True and s.get("publicEnabled") is not False and s.get("id"):
            sid = str(s["id"])
            name = clean(s.get("name") or sid)
            tc = "" if s.get("trackCount") is None else str(s["trackCount"])
            ls = "" if s.get("listeners") is None else str(s["listeners"])
            print("\x1f".join([clean(sid), name, tc, ls]))
EOF
    fi
}

parse_station_bitrates() {
    local st_file="$1"
    local target_id="$2"
    if [[ "$JSON_TOOL" == "jq" ]]; then
        jq -e 'type == "array"' "$st_file" >/dev/null 2>&1 || return 1
        jq -r --arg sid "$target_id" '
            def clean: tostring | gsub("[\t\r\n\u001f]+"; " ");
            (first(.[] | select(.id == $sid)) // empty) |
            (.bitrates // []) |
            [ .[] | select(.enabled != false and (.id // "") != "") ] |
            sort_by(-(.bitrateKbps // 0)) |
            .[] |
            [(.id | clean), ((.bitrateKbps // 0) | tostring)] | join("\u001f")
        ' "$st_file" 2>/dev/null
    else
        python3 - "$st_file" "$target_id" << 'EOF' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        stations = json.load(f)
    if not isinstance(stations, list):
        sys.exit(1)
    sid = sys.argv[2]
    target = next((s for s in stations if isinstance(s, dict) and s.get("id") == sid), None)
    if not target:
        sys.exit(0)
    bitrates = [b for b in (target.get("bitrates") or []) if isinstance(b, dict) and b.get("enabled", True) is not False and b.get("id")]
    bitrates.sort(key=lambda b: -(b.get("bitrateKbps") or 0))
    for b in bitrates:
        bid = str(b["id"]).replace("\x1f", " ").strip()
        kbps = str(b.get("bitrateKbps") or 0)
        print(f"{bid}\x1f{kbps}")
except Exception:
    pass
EOF
    fi
}

resolve_ip_flag() {
    case "$1" in
        1)
            IP_FLAG="-4"
            IP_NAME="IPv4 Only"
            ;;
        2)
            IP_FLAG="-6"
            IP_NAME="IPv6 Only"
            ;;
        *)
            IP_FLAG=""
            IP_NAME="Dual-Stack (Auto)"
            ;;
    esac
}

# ----------------- 4. 启动前交互式配置 (动态频道、音频源、动态码率 & IP协议) -----------------
CHANNEL_CHOICE=""
SOURCE_CHOICE=""
BITRATE_CHOICE=""
USER_CHOICE=""
IP_FLAG=""
IP_NAME="Dual-Stack (Auto)"

# 参数兼容：支持 4 参数、3 参数、2 参数或无参数交互
if [[ $# -ge 4 ]]; then
    CHANNEL_CHOICE="$1"
    SOURCE_CHOICE="$2"
    BITRATE_CHOICE="$3"
    USER_CHOICE="$4"
    resolve_ip_flag "$USER_CHOICE"
elif [[ $# -eq 3 ]]; then
    CHANNEL_CHOICE="$1"
    SOURCE_CHOICE="$2"
    BITRATE_CHOICE=1
    USER_CHOICE="$3"
    resolve_ip_flag "$USER_CHOICE"
elif [[ $# -eq 2 ]]; then
    CHANNEL_CHOICE=1
    SOURCE_CHOICE="$1"
    BITRATE_CHOICE=1
    USER_CHOICE="$2"
    resolve_ip_flag "$USER_CHOICE"
fi

# 并发拉取最新频道与站点摘要 (超时 4 秒，失败自动兜底)
CHANNEL_IDS=()
CHANNEL_NAMES=()
CHANNEL_TRACKS=()
CHANNEL_LISTENERS=()
CHANNELS_FROM_FALLBACK=0

fetch_channels() {
    curl -sS --connect-timeout 3 --max-time 4 $IP_FLAG "$API_CHANNELS_URL" > "$CHANNELS_RAW" 2>/dev/null &
    local pid_ch=$!
    curl -sS --connect-timeout 3 --max-time 4 $IP_FLAG "$API_STATIONS_URL" > "$STATIONS_RAW" 2>/dev/null &
    local pid_st=$!
    wait "$pid_ch" 2>/dev/null
    wait "$pid_st" 2>/dev/null

    local lines
    lines=$(parse_channels_and_stations "$CHANNELS_RAW" "$STATIONS_RAW")
    if [[ -n "$lines" ]]; then
        while IFS=$'\x1f' read -r cid cname ctracks clisteners; do
            [[ -z "$cid" ]] && continue
            CHANNEL_IDS+=("$cid")
            CHANNEL_NAMES+=("$cname")
            CHANNEL_TRACKS+=("$ctracks")
            CHANNEL_LISTENERS+=("$clisteners")
        done <<< "$lines"
    fi

    if [[ ${#CHANNEL_IDS[@]} -eq 0 ]]; then
        CHANNELS_FROM_FALLBACK=1
        CHANNEL_IDS=("touhou" "touhou-curated")
        CHANNEL_NAMES=("东方综合频道" "东方综合精选频道")
        CHANNEL_TRACKS=("" "")
        CHANNEL_LISTENERS=("" "")
    fi
}

if [[ -z "$CHANNEL_CHOICE" ]]; then
    clear
    echo "=================================================="
    echo "       THMR东方网络电台流媒体播放端 (Linux版)     "
    echo "         Maintainer: syameimaru-ayaya         "
    echo "=================================================="
    echo -e "\033[1;34m正在从服务端获取最新频道列表...\033[0m"
fi

fetch_channels

if [[ -z "$CHANNEL_CHOICE" ]]; then
    clear
    echo "=================================================="
    echo "       THMR东方网络电台流媒体播放端 (Linux版)     "
    echo "         Maintainer: syameimaru-ayaya         "
    echo "=================================================="
    if [[ $CHANNELS_FROM_FALLBACK -eq 1 ]]; then
        echo -e "\033[1;33m[提示] 无法拉取在线频道列表，已使用本地默认频道。\033[0m"
    fi
    echo "步骤 1/4：请选择播放电台频道："
    for ((i = 0; i < ${#CHANNEL_IDS[@]}; i++)); do
        local_idx=$((i + 1))
        local_meta=""
        if [[ -n "${CHANNEL_TRACKS[i]}" && -n "${CHANNEL_LISTENERS[i]}" ]]; then
            local_meta=" [${CHANNEL_TRACKS[i]} 首 · 🎧 ${CHANNEL_LISTENERS[i]}人]"
        elif [[ -n "${CHANNEL_TRACKS[i]}" ]]; then
            local_meta=" [${CHANNEL_TRACKS[i]} 首]"
        elif [[ -n "${CHANNEL_LISTENERS[i]}" ]]; then
            local_meta=" [🎧 ${CHANNEL_LISTENERS[i]}人]"
        else
            local_meta=" (${CHANNEL_IDS[i]})"
        fi
        echo "  ${local_idx}) ${CHANNEL_NAMES[i]}${local_meta}"
    done
    echo "--------------------------------------------------"

    read_prompt "请输入选项 [1-${#CHANNEL_IDS[@]}，直接回车默认选 1]: " CHANNEL_CHOICE 1
fi

SELECTED_CH_IDX=0
if [[ -n "$CHANNEL_CHOICE" ]]; then
    if [[ "$CHANNEL_CHOICE" =~ ^[0-9]+$ ]] && [[ "$CHANNEL_CHOICE" -ge 1 && "$CHANNEL_CHOICE" -le ${#CHANNEL_IDS[@]} ]]; then
        SELECTED_CH_IDX=$((CHANNEL_CHOICE - 1))
    else
        matched_ch=0
        for ((i = 0; i < ${#CHANNEL_IDS[@]}; i++)); do
            if [[ "${CHANNEL_IDS[i]}" == "$CHANNEL_CHOICE" ]]; then
                SELECTED_CH_IDX=$i
                matched_ch=1
                break
            fi
        done
        if [[ $matched_ch -eq 0 ]]; then
            echo -e "\033[1;33m[提示] 未匹配到频道 \"$CHANNEL_CHOICE\"，默认使用第 1 个频道。\033[0m"
            SELECTED_CH_IDX=0
        fi
    fi
fi

STATION_ID="${CHANNEL_IDS[$SELECTED_CH_IDX]}"
STATION_NAME="${CHANNEL_NAMES[$SELECTED_CH_IDX]}"
API_STATUS_URL="${API_BASE}/api/stations/${STATION_ID}/status"

if [[ -z "$SOURCE_CHOICE" ]]; then
    echo -e "\n已选定频道: \033[1;35m$STATION_NAME ($STATION_ID)\033[0m"
    echo "--------------------------------------------------"
    echo "步骤 2/4：请选择音频源线路："
    echo "  1) 国内音频源 (radio.zyghit.cn) [低延迟，国内推荐]"
    echo "  2) 国际音频源 (radio.yunmoan.cn) [海外优质节点]"
    echo "--------------------------------------------------"

    read_prompt "请输入选项 [1/2，直接回车默认选 1]: " SOURCE_CHOICE 1
fi

case "$SOURCE_CHOICE" in
    2)
        SOURCE_HOST="https://radio.yunmoan.cn"
        SOURCE_NAME="国际音频源 (yunmoan.cn)"
        ;;
    *)
        SOURCE_HOST="https://radio.zyghit.cn"
        SOURCE_NAME="国内音频源 (zyghit.cn)"
        ;;
esac

PROFILE_IDS=()
PROFILE_NAMES=()
bitrate_lines=$(parse_station_bitrates "$STATIONS_RAW" "$STATION_ID")
if [[ -n "$bitrate_lines" ]]; then
    while IFS=$'\x1f' read -r bid bkbps; do
        [[ -z "$bid" ]] && continue
        PROFILE_IDS+=("$bid")
        if [[ "$bkbps" -ge 256 ]]; then
            PROFILE_NAMES+=("${bkbps} kbps (极高音质)")
        elif [[ "$bkbps" -ge 128 ]]; then
            PROFILE_NAMES+=("${bkbps} kbps (标准音质)")
        elif [[ "$bkbps" -gt 0 ]]; then
            PROFILE_NAMES+=("${bkbps} kbps (轻量弱网)")
        else
            PROFILE_NAMES+=("$bid")
        fi
    done <<< "$bitrate_lines"
fi

if [[ ${#PROFILE_IDS[@]} -eq 0 ]]; then
    PROFILE_IDS=("320k" "128k" "96k")
    PROFILE_NAMES=("320 kbps (极高音质)" "128 kbps (标准音质)" "96 kbps (轻量弱网)")
fi

if [[ -z "$BITRATE_CHOICE" ]]; then
    echo -e "\n已选定音频源: \033[1;32m$SOURCE_NAME\033[0m"
    echo "--------------------------------------------------"
    echo "步骤 3/4：请选择音频码率档案："
    for ((i = 0; i < ${#PROFILE_IDS[@]}; i++)); do
        local_idx=$((i + 1))
        if [[ $i -eq 0 ]]; then
            echo "  ${local_idx}) ${PROFILE_NAMES[i]} [默认推荐]"
        else
            echo "  ${local_idx}) ${PROFILE_NAMES[i]}"
        fi
    done
    echo "--------------------------------------------------"

    read_prompt "请输入选项 [1-${#PROFILE_IDS[@]}，直接回车默认选 1]: " BITRATE_CHOICE 1
fi

SELECTED_BR_IDX=0
if [[ -n "$BITRATE_CHOICE" ]]; then
    if [[ "$BITRATE_CHOICE" =~ ^[0-9]+$ ]] && [[ "$BITRATE_CHOICE" -ge 1 && "$BITRATE_CHOICE" -le ${#PROFILE_IDS[@]} ]]; then
        SELECTED_BR_IDX=$((BITRATE_CHOICE - 1))
    else
        matched_br=0
        for ((i = 0; i < ${#PROFILE_IDS[@]}; i++)); do
            if [[ "${PROFILE_IDS[i]}" == "$BITRATE_CHOICE" ]]; then
                SELECTED_BR_IDX=$i
                matched_br=1
                break
            fi
        done
        if [[ $matched_br -eq 0 ]]; then
            echo -e "\033[1;33m[提示] 未匹配到码率 \"$BITRATE_CHOICE\"，默认使用第 1 个档位。\033[0m"
            SELECTED_BR_IDX=0
        fi
    fi
fi

PROFILE_ID="${PROFILE_IDS[$SELECTED_BR_IDX]}"
PROFILE_NAME="${PROFILE_NAMES[$SELECTED_BR_IDX]}"
STREAM_URL="${SOURCE_HOST}/radio/${STATION_ID}/${PROFILE_ID}"

if [[ -z "$USER_CHOICE" ]]; then
    echo -e "\n已选定音质: \033[1;33m$PROFILE_NAME\033[0m"
    echo "--------------------------------------------------"
    echo "步骤 4/4：请选择拉流的网络协议："
    echo "  1) 强制 IPv4 (-4)"
    echo "  2) 强制 IPv6 (-6)"
    echo "  3) 自动双栈 (由系统调度)"
    echo "--------------------------------------------------"

    read_prompt "请输入选项 [1/2/3，直接回车默认选 3]: " USER_CHOICE 3
fi

resolve_ip_flag "$USER_CHOICE"

VLC_BIN=cvlc
command -v cvlc >/dev/null 2>&1 || VLC_BIN=vlc

render_main_header() {
    clear
    echo "=================================================="
    echo "       THMR东方网络电台流媒体播放端 (Linux版)     "
    echo "         Maintainer: syameimaru-ayaya         "
    echo "=================================================="
    echo -e "  频道: \033[1;35m$STATION_NAME ($STATION_ID)\033[0m"
    echo -e "  音质: \033[1;33m$PROFILE_NAME\033[0m"
    echo -e "  线路: \033[1;32m$SOURCE_NAME\033[0m | 模式: \033[1;32m$IP_NAME\033[0m"
    echo -e "  引擎: \033[1;36mVLC 无头解码 ($VLC_BIN)\033[0m"
    if [[ -n "$MPRIS_PLAYER" ]]; then
        echo -e "  媒体: \033[1;32mMPRIS 已启用\033[0m (playerctl --player=${MPRIS_PLAYER} play-pause)"
    fi
    echo "=================================================="
    echo "操作提示："
    echo "  [+] / [=] 增加音量    [-] / [_] 降低音量"
    echo "  [Space] / [p] 暂停/播放  [m] 静音切换"
    echo "  [h] 上一曲/历史查询    [f] / [r] 曲目反馈"
    echo "  [q] 退出播放          [Ctrl+C] 强制退出"
    echo "=================================================="
    echo ""
    tput civis 2>/dev/null
}

render_main_header

# ----------------- 5. 初始化管道与拉流守护进程 -----------------
rm -f "$FIFO_PATH" "$VLC_SOCK"
mkfifo "$FIFO_PATH"
# 锁定描述符 3 读写端，屏蔽 EOF，防止断流或切歌导致 VLC 退出
exec 3<> "$FIFO_PATH"

echo -ne "\r\033[K\033[1;34m[$(date '+%H:%M:%S')] 正在通过 curl 连接音频流...\033[0m"

curl_fetcher() {
    local retry_delay=2
    local fail_count=0
    while true; do
        local start_time=$(date +%s)

        # 启动 curl 拉流
        curl -sS -L -N --connect-timeout 10 $IP_FLAG "$STREAM_URL" >&3 2>>"$LOG_FILE"
        local exit_code=$?

        # 若收到退出信号则退出守护循环
        [[ $exit_code -eq 130 || $exit_code -eq 143 || $exit_code -eq 137 ]] && break

        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        # 正常播放超过 10 秒后断流，重置连续失败计数
        if [[ $duration -ge 10 ]]; then
            fail_count=0
        else
            ((fail_count++))
        fi

        # 连续快速失败达到 5 次，判定为网络不可达或地址失效，停止重试
        if [[ $fail_count -ge 5 ]]; then
            echo -e "\n[$(date '+%H:%M:%S')] 连续拉流失败达到上限，停止重连。" >> "$LOG_FILE"
            break
        fi

        echo -e "\r\033[K\033[1;33m[$(date '+%H:%M:%S')] 网络中断，${retry_delay}秒后尝试自动重连 (连续失败: ${fail_count}/5)...\033[0m" >&2
        sleep "$retry_delay"
        echo -e "\r\033[K\033[1;34m[$(date '+%H:%M:%S')] 正在重新连接音频流...\033[0m" >&2
    done
}

curl_fetcher &
CURL_PID=$!

# ----------------- 6. 启动 VLC 并挂载 UNIX 控制套接字与可选 MPRIS -----------------
# MPRIS 使用当前用户的会话总线；缺少工具、模块或总线时显式关闭
ENABLE_MPRIS=0
VLC_MPRIS_ARGS=("--no-dbus")
if command -v dbus-send >/dev/null 2>&1 &&
   dbus-send --session --print-reply --reply-timeout=1000 \
       --dest=org.freedesktop.DBus /org/freedesktop/DBus \
       org.freedesktop.DBus.ListNames >/dev/null 2>&1 &&
   "$VLC_BIN" --list 2>/dev/null | grep -q '^[[:space:]]*dbus[[:space:]]'; then
    ENABLE_MPRIS=1
    # VLC 在 Linux 下默认会自动加载一次 dbus 模块，切勿再传 --control dbus 或 oldrc:dbus，否则会导致注册两份 MPRIS 服务
    VLC_MPRIS_ARGS=()
fi

# 注意：VLC 3.x 下旧版 RC 接口名为 oldrc，且需要 --rc-fake-tty 避免无输入时退出
"$VLC_BIN" -q -I dummy \
     --no-one-instance \
     "${VLC_MPRIS_ARGS[@]}" \
     --extraintf oldrc \
     --rc-unix "$VLC_SOCK" \
     --rc-fake-tty \
     --no-video \
     --meta-title "THMR 东方音乐电台" \
     "$FIFO_PATH" >/dev/null 2>&1 &
VLC_PID=$!

# 等待套接字文件生成
for ((i = 0; i < 30; i++)); do
    [[ -S "$VLC_SOCK" ]] && break
    sleep 0.1
done

if [[ ! -S "$VLC_SOCK" ]]; then
    echo -e "\n\033[1;31m[错误] VLC 控制套接字创建失败！\033[0m"
    cleanup
fi

# VLC 名称可能已被其他实例占用，按进程 ID 确认本次启动的播放器
if [[ $ENABLE_MPRIS -eq 1 ]]; then
    for ((i = 0; i < 30; i++)); do
        for name in org.mpris.MediaPlayer2.vlc "org.mpris.MediaPlayer2.vlc.instance${VLC_PID}"; do
            owner=$(dbus-send --session --print-reply --reply-timeout=1000 \
                --dest=org.freedesktop.DBus /org/freedesktop/DBus \
                org.freedesktop.DBus.GetConnectionUnixProcessID string:"$name" 2>/dev/null)
            if [[ "$owner" == *"uint32 $VLC_PID" ]]; then
                MPRIS_PLAYER="${name#org.mpris.MediaPlayer2.}"
                break 2
            fi
        done
        kill -0 "$VLC_PID" 2>/dev/null || break
        sleep 0.1
    done
fi

# 套接字控制函数（兼容 openbsd-netcat 与 socat）
send_vlc() {
    local cmd="$1"
    if command -v socat >/dev/null 2>&1; then
        echo "$cmd" | socat - UNIX-CONNECT:"$VLC_SOCK" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        echo "$cmd" | nc -U "$VLC_SOCK" >/dev/null 2>&1
    fi
}

send_vlc_and_get_vol() {
    local cmd="$1"
    if command -v socat >/dev/null 2>&1; then
        local out
        out=$(printf '%s\nstatus\n' "$cmd" | socat -t 0.08 - UNIX-CONNECT:"$VLC_SOCK" 2>/dev/null)
        if [[ "$out" =~ audio\ volume:\ ([0-9]+) ]]; then
            local raw_vol="${BASH_REMATCH[1]}"
            echo $(( (raw_vol * 100 + 128) / 256 ))
            return 0
        fi
    else
        send_vlc "$cmd"
    fi
    return 1
}

render_main_header
echo -ne "\r\033[K\033[1;32m[$(date '+%H:%M:%S')] 播放已就绪，正在获取当前曲目信息...\033[0m"

# ----------------- 7. 后台曲目状态轮询与 UI 组件 -----------------
format_time() {
    local s=$1
    printf "%02d:%02d" $((s / 60)) $((s % 60))
}

render_vol_bar() {
    local vol=$1
    local width=15
    local bar_pct=$vol
    [[ $bar_pct -gt 100 ]] && bar_pct=100
    [[ $bar_pct -lt 0 ]] && bar_pct=0
    local filled=$((bar_pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    for ((j = 0; j < filled; j++)); do bar+="█"; done
    for ((j = 0; j < empty; j++)); do bar+="░"; done
    echo -ne "\r\033[K\033[1;36m[$(date '+%H:%M:%S')] 音量: [${bar}] ${vol}%\033[0m"
}

render_track_bar() {
    local artist="$1"
    local title="$2"
    local pos=$3
    local dur=$4
    local listeners=$5

    local pos_str=$(format_time "$pos")
    local dur_str=$(format_time "$dur")

    local width=12
    local pct=0
    if [[ $dur -gt 0 ]]; then
        pct=$((pos * 100 / dur))
    fi
    [[ $pct -gt 100 ]] && pct=100
    [[ $pct -lt 0 ]] && pct=0

    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    for ((j = 0; j < filled; j++)); do bar+="█"; done
    for ((j = 0; j < empty; j++)); do bar+="░"; done

    local track="${artist} - ${title}"
    if [[ ${#track} -gt 32 ]]; then
        track="${track:0:29}..."
    fi

    echo -ne "\r\033[K\033[1;35m🎵 ${track}\033[0m \033[36m[${pos_str}/${dur_str}]\033[0m \033[32m[${bar}]\033[0m \033[33m🎧 ${listeners}人\033[0m"
}

PREV_TRACK=""
CUR_ARTIST=""
CUR_TITLE=""
LAST_SEEN_TITLE=""
SESSION_HISTORY=()

handle_feedback() {
    tput cnorm 2>/dev/null
    clear
    echo "=================================================="
    echo "       THMR 东方音乐电台 - 曲目问题反馈              "
    echo "=================================================="
    local track_info="当前播放曲目"
    if [[ -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
        IFS=$'\x1f' read -r cur_artist cur_title _ _ _ _ _ < "$STATUS_FILE"
        [[ -n "$cur_title" && "$cur_title" != "未知曲目" ]] && track_info="${cur_artist} - ${cur_title}"
    fi
    echo -e "当前曲目: \033[1;35m${track_info}\033[0m"
    echo "--------------------------------------------------"
    echo "请选择反馈问题类型："
    echo "  1) 非东方歌曲 (non-touhou)"
    echo "  2) 音频损坏 / 播放异常 (playback)"
    echo "  3) 标签错误 / 歌名有误 (metadata)"
    echo "  4) 非音乐 / 空白音频 (non-music)"
    echo "  5) 版权投诉 / 内容违规 (violation)"
    echo "  6) 其他问题 (other)"
    echo "  0) 取消返回"
    echo "--------------------------------------------------"

    local type_choice=""
    read_prompt "请输入类型编号 [1-6, 0 取消, 默认 1]: " type_choice 0
    [[ -z "$type_choice" ]] && type_choice=1

    local fb_type=""
    case "$type_choice" in
        1) fb_type="non-touhou" ;;
        2) fb_type="playback" ;;
        3) fb_type="metadata" ;;
        4) fb_type="non-music" ;;
        5) fb_type="violation" ;;
        6) fb_type="other" ;;
        0|q|Q)
            echo -e "\033[1;33m已取消反馈，正在返回主界面...\033[0m"
            sleep 1
            render_main_header
            return 0
            ;;
        *)
            echo -e "\033[1;31m输入无效，已取消反馈，正在返回主界面...\033[0m"
            sleep 1
            render_main_header
            return 0
            ;;
    esac

    # 联系方式 (优先读取本地缓存，留空使用默认)
    local default_contact="thmr-cli-user"
    if [[ -f "$CONTACT_CACHE_FILE" ]]; then
        default_contact=$(cat "$CONTACT_CACHE_FILE" 2>/dev/null)
        [[ -z "$default_contact" ]] && default_contact="thmr-cli-user"
    fi

    local fb_contact=""
    read_prompt "请输入联系方式 (留空默认 [$default_contact]): " fb_contact "$default_contact"
    [[ -z "$fb_contact" ]] && fb_contact="$default_contact"

    # 写入缓存文件
    mkdir -p "$CACHE_DIR"
    echo "$fb_contact" > "$CONTACT_CACHE_FILE"

    # 补充说明 (可选)
    local fb_msg=""
    read_prompt "请输入补充说明 (可选，直接回车跳过): " fb_msg ""

    echo -e "\033[1;34m正在提交反馈到服务端...\033[0m"

    local payload
    payload=$(build_feedback_json "$fb_type" "$fb_contact" "$fb_msg")

    local resp
    resp=$(curl -sS --max-time 8 $IP_FLAG -X POST "${API_BASE}/api/stations/${STATION_ID}/feedback" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local fb_result
    fb_result=$(parse_feedback_json "$resp")

    local res_status="" res_id="" res_count="" res_thresh="" res_skip=""
    IFS=$'\x1f' read -r res_status res_id res_count res_thresh res_skip <<< "$fb_result"

    if [[ "$res_status" == "OK" ]]; then
        echo -e "\033[1;32m[反馈提交成功] 反馈编号: $res_id\033[0m"
        echo -e "当前曲目累计反馈数: \033[1;33m${res_count}/${res_thresh}\033[0m (达到 ${res_thresh} 条时服务端将自动切歌)"
        if [[ "$res_skip" == "1" ]]; then
            echo -e "\033[1;36m[提示] 该曲目累计反馈已触发阈值，服务端将自动跳过此曲！\033[0m"
        fi
    else
        echo -e "\033[1;31m[反馈提交失败] ${res_id:-$resp}\033[0m"
    fi

    echo "--------------------------------------------------"
    echo -e "正在返回主播放界面..."
    sleep 2
    render_main_header
}

show_history() {
    tput cnorm 2>/dev/null
    if [[ -z "$CUR_TITLE" && -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
        IFS=$'\x1f' read -r s_artist s_title _ _ _ s_prev_artist s_prev_title < "$STATUS_FILE"
        if [[ -n "$s_title" ]]; then
            CUR_ARTIST="$s_artist"
            CUR_TITLE="$s_title"
            if [[ -n "$s_prev_title" ]]; then
                if [[ -n "$s_prev_artist" ]]; then
                    PREV_TRACK="${s_prev_artist} - ${s_prev_title}"
                else
                    PREV_TRACK="${s_prev_title}"
                fi
            fi
        fi
    fi

    clear
    echo "=================================================="
    echo "       THMR 东方音乐电台 - 曲目回溯与历史播放记录     "
    echo "=================================================="
    if [[ -n "$PREV_TRACK" && "$PREV_TRACK" != " -" && "$PREV_TRACK" != "-" ]]; then
        echo -e "  \033[1;33m⏮️ 上一首播放:\033[0m $PREV_TRACK"
    else
        echo -e "  \033[1;33m⏮️ 上一首播放:\033[0m 暂无上一曲数据 (电台刚启动或无历史)"
    fi
    echo -e "  \033[1;32m▶️ 当前正在播:\033[0m ${CUR_ARTIST:-未知} - ${CUR_TITLE:-未知}"

    if [[ ${#SESSION_HISTORY[@]} -gt 0 ]]; then
        echo "--------------------------------------------------"
        echo -e "\033[1;34m📜 本次收听历史 (按时间倒序):\033[0m"
        local idx=1
        for ((i = ${#SESSION_HISTORY[@]} - 1; i >= 0; i--)); do
            echo -e "  ${idx}. ${SESSION_HISTORY[i]}"
            ((idx++))
            [[ $idx -gt 10 ]] && break
        done
    fi
    echo "=================================================="
    echo -e "\033[0;37m按任意键返回主界面 (或等待 5 秒自动返回)...\033[0m"

    local dummy=""
    read_key 5 dummy
    render_main_header
}

status_fetcher() {
    while true; do
        if curl -sS --max-time 4 $IP_FLAG "$API_STATUS_URL" > "$STATUS_RAW" 2>/dev/null; then
            local parsed
            parsed=$(parse_status_json "$STATUS_RAW")
            if [[ -n "$parsed" ]]; then
                echo "$parsed" > "$STATUS_FILE"
            fi
        fi
        sleep 5
    done
}
status_fetcher &
STATUS_FETCHER_PID=$!

# ----------------- 8. 前台热键监听与实时进度刷新循环 -----------------
SHOW_VOL_UNTIL=0
IS_PAUSED=0
IS_MUTED=0

while true; do
    # 检查 curl 守护进程状态
    if ! kill -0 "$CURL_PID" 2>/dev/null; then
        echo -e "\n\033[1;31m[错误] curl 拉流守护进程意外退出！日志如下：\033[0m"
        cat "$LOG_FILE" 2>/dev/null
        break
    fi

    # 检查 VLC 进程状态
    if ! kill -0 "$VLC_PID" 2>/dev/null; then
        echo -e "\n\033[1;33m[$(date '+%H:%M:%S')] VLC 播放进程已退出，正在结束播放。\033[0m"
        break
    fi

    # 监听用户按键（免回车，1秒超时以便轮询子进程存活与刷新进度）
    got_key=0
    key=""
    if read_key 1 key; then
        got_key=1
    fi

    if [[ $got_key -eq 1 ]]; then
        case "$key" in
            +|"=")
                if vol_pct=$(send_vlc_and_get_vol "volup 2"); then
                    render_vol_bar "$vol_pct"
                else
                    echo -ne "\r\033[K\033[1;36m[$(date '+%H:%M:%S')] 音量 +2\033[0m"
                fi
                SHOW_VOL_UNTIL=$(( $(date +%s) + 2 ))
                ;;
            -|_)
                if vol_pct=$(send_vlc_and_get_vol "voldown 2"); then
                    render_vol_bar "$vol_pct"
                else
                    echo -ne "\r\033[K\033[1;36m[$(date '+%H:%M:%S')] 音量 -2\033[0m"
                fi
                SHOW_VOL_UNTIL=$(( $(date +%s) + 2 ))
                ;;
            " "|p|P)
                send_vlc "pause"
                if [[ $IS_PAUSED -eq 0 ]]; then
                    IS_PAUSED=1
                    echo -ne "\r\033[K\033[1;33m[$(date '+%H:%M:%S')] ⏸ 播放已暂停 (按 Space 或 P 恢复)\033[0m"
                else
                    IS_PAUSED=0
                fi
                ;;
            m|M)
                send_vlc "key vol-mute"
                if [[ $IS_MUTED -eq 0 ]]; then
                    IS_MUTED=1
                    echo -ne "\r\033[K\033[1;31m[$(date '+%H:%M:%S')] 🔇 已静音 (按 M 恢复)\033[0m"
                else
                    IS_MUTED=0
                fi
                ;;
            h|H)
                show_history
                ;;
            f|F|r|R)
                handle_feedback
                ;;
            q|Q)
                echo -e "\n\033[1;33m用户请求退出...\033[0m"
                break
                ;;
        esac
    fi

    # 实时刷新曲目元数据与进度条 (当未在调节音量时)
    now_epoch=$(date +%s)
    if [[ $now_epoch -ge $SHOW_VOL_UNTIL ]]; then
        if [[ $IS_PAUSED -eq 1 ]]; then
            echo -ne "\r\033[K\033[1;33m[$(date '+%H:%M:%S')] ⏸ 播放已暂停 (按 Space 或 P 恢复)\033[0m"
        elif [[ $IS_MUTED -eq 1 ]]; then
            echo -ne "\r\033[K\033[1;31m[$(date '+%H:%M:%S')] 🔇 已静音 (按 M 恢复)\033[0m"
        elif [[ -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
            IFS=$'\x1f' read -r cur_artist cur_title cur_started_ms cur_dur cur_listeners prev_artist prev_title < "$STATUS_FILE"
            if [[ -n "$cur_title" && "$cur_title" != "未知曲目" ]]; then
                CUR_ARTIST="$cur_artist"
                CUR_TITLE="$cur_title"
                if [[ -n "$prev_title" ]]; then
                    if [[ -n "$prev_artist" ]]; then
                        PREV_TRACK="${prev_artist} - ${prev_title}"
                    else
                        PREV_TRACK="${prev_title}"
                    fi
                fi
                if [[ "$cur_title" != "$LAST_SEEN_TITLE" ]]; then
                    LAST_SEEN_TITLE="$cur_title"
                    SESSION_HISTORY+=("[$(date '+%H:%M')] ${cur_artist} - ${cur_title}")
                    if [[ ${#SESSION_HISTORY[@]} -gt 10 ]]; then
                        SESSION_HISTORY=("${SESSION_HISTORY[@]:1}")
                    fi
                fi
                started_sec=$((cur_started_ms / 1000))
                pos=$((now_epoch - started_sec))
                [[ $pos -lt 0 ]] && pos=0
                [[ $cur_dur -gt 0 && $pos -gt $cur_dur ]] && pos=$cur_dur
                render_track_bar "$cur_artist" "$cur_title" "$pos" "$cur_dur" "$cur_listeners"
            fi
        fi
    fi
done

cleanup
