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

# ----------------- 0. 环境与安全防呆拦截 -----------------
# 1. 拦截非 macOS 系统
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo -e "\n\033[1;31m[错误] 本脚本为 macOS 专用定制版本！\033[0m"
    echo -e "\033[1;33mLinux 环境请直接运行: ./thmr-cli-linux.sh\033[0m\n"
    exit 1
fi

# 2. 严禁以 root 身份直接执行
if [[ $EUID -eq 0 ]]; then
    echo -e "\n\033[1;31m[安全拦截] 严禁以 root 身份直接执行本脚本！\033[0m"
    echo -e "\033[1;33m说明：音视频播放属于用户层操作，遵循最小权限原则，无需 sudo。\033[0m"
    echo -e "\033[1;32m请切换为普通用户后重新执行: ./thmr-cli-macos.sh\033[0m\n"
    exit 1
fi

API_BASE="https://radio.yunmoan.cn"
PLAYER_VERSION="1.2.0"
CACHE_DIR="$HOME/.cache/thmr-cli"
SWIFT_BIN="$CACHE_DIR/thmr-player-macos-v${PLAYER_VERSION}"
CTRL_SOCK="/tmp/thmr_ctrl_${UID}.sock"
FIFO_PATH="/tmp/thmr_stream_${UID}.fifo"
LOG_FILE=$(mktemp /tmp/thmr_radio_log.XXXXXX)
STATUS_FILE=$(mktemp /tmp/thmr_status.XXXXXX)
STATUS_RAW=$(mktemp /tmp/thmr_raw.XXXXXX)
STATUS_SCRIPT=$(mktemp /tmp/thmr_parser.XXXXXX)

PLAYER_BACKEND=""   # "native" 或 "vlc"
VLC_BIN=""
PLAYER_PID=""
CURL_PID=""
STATUS_FETCHER_PID=""

# 预先生成轻量 JXA JSON 解析器脚本（零外部依赖，毫秒级解析）
cat << 'EOF' > "$STATUS_SCRIPT"
var fs = $.NSFileManager.defaultManager;
var path = ObjC.unwrap($.NSProcessInfo.processInfo.arguments.objectAtIndex(4));
var data = fs.contentsAtPath(path);
if (data) {
    var str = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js;
    try {
        var d = JSON.parse(str);
        var cur = d.current || {};
        var artist = cur.artist || "未知艺术家";
        var title = cur.title || "未知曲目";
        var startedAt = cur.startedAtMs || 0;
        var duration = cur.durationSec || 0;
        var listeners = (d.totals && d.totals.listeners) != null ? d.totals.listeners : 0;
        artist + "\t" + title + "\t" + startedAt + "\t" + duration + "\t" + listeners;
    } catch(e) { "" }
} else { "" }
EOF

# ----------------- 1. 播放引擎探测 (方案1: 原生 AVPlayer / 备选: VLC) -----------------
find_vlc() {
    if [[ -x "/Applications/VLC.app/Contents/MacOS/VLC" ]]; then
        VLC_BIN="/Applications/VLC.app/Contents/MacOS/VLC"
        return 0
    elif [[ -x "$HOME/Applications/VLC.app/Contents/MacOS/VLC" ]]; then
        VLC_BIN="$HOME/Applications/VLC.app/Contents/MacOS/VLC"
        return 0
    elif command -v vlc >/dev/null 2>&1; then
        VLC_BIN="vlc"
        return 0
    elif command -v cvlc >/dev/null 2>&1; then
        VLC_BIN="cvlc"
        return 0
    fi
    return 1
}

find_native() {
    if [[ -x "$SWIFT_BIN" ]] || command -v swiftc >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

detect_engine() {
    # 允许用户通过环境变量强制指定引擎：THMR_ENGINE=native 或 THMR_ENGINE=vlc
    if [[ "$THMR_ENGINE" == "vlc" ]]; then
        if find_vlc; then
            PLAYER_BACKEND="vlc"
            return 0
        else
            echo -e "\033[1;31m[错误] 指定了 VLC 引擎，但未在系统或 /Applications 中找到 VLC！\033[0m"
            exit 1
        fi
    elif [[ "$THMR_ENGINE" == "native" ]]; then
        if find_native; then
            PLAYER_BACKEND="native"
            return 0
        else
            echo -e "\033[1;31m[错误] 指定了原生引擎，但未找到 swiftc 编译器！\033[0m"
            exit 1
        fi
    fi

    # 优先检测 1：macOS 原生 AVPlayer 引擎 (方案1 - 零第三方软件依赖)
    if find_native; then
        PLAYER_BACKEND="native"
        return 0
    fi

    # 备选检测 2：检测是否已安装桌面版 VLC.app 或命令行 VLC
    if find_vlc; then
        PLAYER_BACKEND="vlc"
        return 0
    fi

    # 备选检测 3：Conda 虚拟环境支持
    if command -v conda >/dev/null 2>&1; then
        echo -e "\033[1;33m[提示] 未发现原生 Swift 编译器和 VLC，检测到系统安装有 Conda。\033[0m"
        echo -e "\033[1;33m根据规范，若需使用 Conda/Python 安装依赖，请部署在名为 thmr 的专属虚拟环境中。\033[0m"
    fi

    echo -e "\n\033[1;31m[错误] 未能检测到可用的 macOS 播放后端！\033[0m"
    echo -e "\033[1;33m请选择以下任一方式就绪播放引擎（无需安装 Homebrew）：\033[0m"
    echo -e "  \033[1;32m方式 1 (推荐·原生引擎)\033[0m: 安装 macOS 开发者命令行工具（自动获得 swiftc）："
    echo -e "         xcode-select --install"
    echo -e "  \033[1;32m方式 2 (传统引擎)\033[0m: 下载官方 VLC 播放器并拖入「应用程序」目录即可："
    echo -e "         https://www.videolan.org/vlc/download-macosx.html\n"
    exit 1
}

# ----------------- 2. 编译并缓存 macOS 原生播放器 (方案1) -----------------
ensure_native_player() {
    [[ -x "$SWIFT_BIN" ]] && return 0

    mkdir -p "$CACHE_DIR"
    local swift_src="$CACHE_DIR/player.swift"

    echo -e "\033[1;34m[$(date '+%H:%M:%S')] 首次运行：正在就绪 macOS 原生 AVPlayer 播放引擎...\033[0m"

    cat << 'EOF' > "$swift_src"
import Foundation
import AVFoundation

extension Date {
    func formattedTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }
}

final class RadioPlayer {
    let player: AVPlayer
    let socketPath: String
    let streamUrl: URL
    var serverFd: Int32 = -1
    var isRunning = true
    
    private var failCount = 0
    private var lastPlayTimestamp: Date = Date()
    private var isReconnecting = false
    
    init(url: URL, socketPath: String) {
        self.streamUrl = url
        self.socketPath = socketPath
        self.player = AVPlayer(url: url)
        self.player.volume = 0.8
        
        setupNotifications()
    }
    
    private func logTerminal(_ text: String) {
        let msg = "\r\u{001B}[K\(text)"
        if let tty = fopen("/dev/tty", "w") {
            fputs(msg, tty)
            fclose(tty)
        } else {
            fputs(msg, stderr)
        }
    }
    
    private func triggerReconnect() {
        guard isRunning && !isReconnecting else { return }
        isReconnecting = true
        
        let now = Date().timeIntervalSince(lastPlayTimestamp)
        if now >= 10.0 {
            failCount = 0
        }
        failCount += 1
        
        if failCount >= 5 {
            logTerminal("\u{001B}[1;31m[\(Date().formattedTime())] 连续重连失败达上限 (5/5)，停止重试。\u{001B}[0m\n")
            exit(1)
        }
        
        let delay: TimeInterval = 2.0
        logTerminal("\u{001B}[1;33m[\(Date().formattedTime())] 网络中断，\(Int(delay))秒后尝试自动重连 (连续失败: \(failCount)/5)...\u{001B}[0m")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.logTerminal("\u{001B}[1;34m[\(Date().formattedTime())] 正在重新连接音频流...\u{001B}[0m")
            let newItem = AVPlayerItem(url: self.streamUrl)
            self.player.replaceCurrentItem(with: newItem)
            self.player.play()
            self.isReconnecting = false
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.player.play()
        }
        
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerReconnect()
        }
    }
    
    func start() {
        setupSocket()
        player.play()
        
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            if self.player.timeControlStatus == .playing {
                self.lastPlayTimestamp = Date()
            } else if let item = self.player.currentItem, item.status == .failed {
                self.triggerReconnect()
            }
        }
        
        let sockQueue = DispatchQueue(label: "com.thmr.socket", qos: .userInitiated)
        sockQueue.async { [weak self] in
            self?.socketLoop()
        }
    }
    
    private func setupSocket() {
        unlink(socketPath)
        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            fputs("[Error] Socket creation failed\n", stderr)
            exit(1)
        }
        
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for i in 0..<min(pathBytes.count, maxLen) {
                rawPtr[i] = pathBytes[i]
            }
        }
        
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(serverFd, sa, len)
            }
        }
        if bindRes != 0 || listen(serverFd, 10) != 0 {
            fputs("[Error] Socket bind/listen failed\n", stderr)
            exit(1)
        }
    }
    
    private func socketLoop() {
        var buf = [CChar](repeating: 0, count: 512)
        while isRunning {
            let clientFd = accept(serverFd, nil, nil)
            guard clientFd >= 0 else { continue }
            
            let bytesRead = read(clientFd, &buf, buf.count - 1)
            if bytesRead > 0 {
                buf[bytesRead] = 0
                let rawCmd = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
                let resp = processCommand(rawCmd)
                if !resp.isEmpty {
                    _ = resp.withCString { write(clientFd, $0, strlen($0)) }
                }
            }
            close(clientFd)
        }
    }
    
    private func processCommand(_ cmd: String) -> String {
        let tokens = cmd.split(separator: " ").map { String($0) }
        guard let action = tokens.first else { return "ERR\n" }
        
        var response = "OK\n"
        let group = DispatchGroup()
        group.enter()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { group.leave(); return }
            switch action {
            case "volup":
                let delta: Float = (tokens.count > 1 ? Float(tokens[1]) : nil) ?? 5.0
                self.player.volume = min(1.0, max(0.0, self.player.volume + (delta / 100.0)))
                response = "VOL \(Int(round(self.player.volume * 100)))\n"
            case "voldown":
                let delta: Float = (tokens.count > 1 ? Float(tokens[1]) : nil) ?? 5.0
                self.player.volume = min(1.0, max(0.0, self.player.volume - (delta / 100.0)))
                response = "VOL \(Int(round(self.player.volume * 100)))\n"
            case "setvol":
                if tokens.count > 1, let v = Float(tokens[1]) {
                    self.player.volume = min(1.0, max(0.0, v / 100.0))
                }
                response = "VOL \(Int(round(self.player.volume * 100)))\n"
            case "getvol":
                response = "VOL \(Int(round(self.player.volume * 100)))\n"
            case "mute":
                self.player.isMuted.toggle()
                response = self.player.isMuted ? "MUTED\n" : "UNMUTED\n"
            case "pause":
                self.player.pause()
                response = "PAUSED\n"
            case "resume":
                self.player.play()
                response = "PLAYING\n"
            case "toggle":
                if self.player.timeControlStatus == .playing {
                    self.player.pause()
                    response = "PAUSED\n"
                } else {
                    self.player.play()
                    response = "PLAYING\n"
                }
            case "status":
                let st = self.player.timeControlStatus == .playing ? "PLAYING" : "PAUSED"
                response = "\(st) \(Int(round(self.player.volume * 100)))\n"
            case "quit":
                self.isRunning = false
                response = "BYE\n"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    exit(0)
                }
            default:
                response = "UNKNOWN\n"
            }
            group.leave()
        }
        
        _ = group.wait(timeout: .now() + 0.5)
        return response
    }
}

guard CommandLine.arguments.count > 2,
      let url = URL(string: CommandLine.arguments[1]) else {
    fputs("Usage: player <stream_url> <socket_path>\n", stderr)
    exit(1)
}

let player = RadioPlayer(url: url, socketPath: CommandLine.arguments[2])
player.start()
RunLoop.main.run()
EOF

    if swiftc -O "$swift_src" -o "$SWIFT_BIN" >/dev/null 2>&1; then
        echo -e "\033[1;32m[$(date '+%H:%M:%S')] 原生引擎就绪完成 (缓存于 $SWIFT_BIN)\033[0m"
        rm -f "$swift_src"
    else
        echo -e "\033[1;31m[错误] 原生引擎编译失败，请检查 swiftc 环境。\033[0m"
        exit 1
    fi
}

CLEANED_UP=0
# ----------------- 3. 全局清理钩子 (彻底防残留) -----------------
cleanup() {
    [[ "$CLEANED_UP" -eq 1 ]] && exit 0
    CLEANED_UP=1
    trap - INT TERM EXIT

    # 若未进入播放流程（如 --help 或参数验证退出），静默退出
    if [[ -z "$PLAYER_PID" && -z "$CURL_PID" && ! -S "$CTRL_SOCK" ]]; then
        exit 0
    fi

    echo -e "\n\n\033[1;33m[$(date '+%H:%M:%S')] 正在停止播放并彻底回收资源...\033[0m"

    # 1. 终止状态拉取轮询守护进程
    if [[ -n "$STATUS_FETCHER_PID" ]] && kill -0 "$STATUS_FETCHER_PID" 2>/dev/null; then
        kill -TERM "$STATUS_FETCHER_PID" 2>/dev/null
        wait "$STATUS_FETCHER_PID" 2>/dev/null
    fi

    # 2. 终止后台拉流守护进程
    if [[ -n "$CURL_PID" ]] && kill -0 "$CURL_PID" 2>/dev/null; then
        kill -9 "$CURL_PID" 2>/dev/null
    fi

    # 3. 终止播放核心进程
    if [[ -n "$PLAYER_PID" ]] && kill -0 "$PLAYER_PID" 2>/dev/null; then
        # 尝试温和退出
        if [[ -S "$CTRL_SOCK" ]]; then
            echo "quit" | nc -U "$CTRL_SOCK" >/dev/null 2>&1
            sleep 0.1
        fi
        kill -9 "$PLAYER_PID" 2>/dev/null
    fi

    # 4. 关闭写端文件描述符
    exec 3>&- 2>/dev/null

    # 5. 彻底清理临时文件与套接字
    rm -f "$CTRL_SOCK" "$FIFO_PATH" "$LOG_FILE" "$STATUS_FILE" "$STATUS_RAW" "$STATUS_SCRIPT" 2>/dev/null

    # 6. 恢复终端光标
    tput cnorm 2>/dev/null

    echo -e "\033[1;32m[$(date '+%H:%M:%S')] 进程与套接字已全部清理完毕，安全退出。\033[0m"
    exit 0
}
trap cleanup INT TERM EXIT

# 执行引擎探测
detect_engine

# ----------------- 4. 启动前交互式配置 (频道、音频源 & IP协议) -----------------
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "用法: $0 [频道 1/2] [音频源 1/2] [网络协议 1/2/3]"
    echo "  频道:   1 = 东方综合主频道 (默认 · 13万首全量随机)"
    echo "          2 = 东方综合精选频道 (500+首人工精选)"
    echo "  音频源: 1 = 国内音频源 (默认), 2 = 国际音频源"
    echo "  协议:   1 = 强制 IPv4, 2 = 强制 IPv6, 3 = 自动双栈 (默认)"
    echo "示例:"
    echo "  $0            # 全交互式引导启动"
    echo "  $0 1 1 3      # 主频道 + 国内源 + 自动双栈 (快速启动)"
    echo "  $0 2 1 3      # 精选频道 + 国内源 + 自动双栈 (快速启动)"
    exit 0
fi

# 参数兼容：支持 3 参数、2 参数或无参数交互
if [[ $# -ge 3 ]]; then
    CHANNEL_CHOICE="$1"
    SOURCE_CHOICE="$2"
    USER_CHOICE="$3"
elif [[ $# -eq 2 ]]; then
    CHANNEL_CHOICE=1
    SOURCE_CHOICE="$1"
    USER_CHOICE="$2"
else
    clear
    echo "=================================================="
    echo "       THMR东方网络电台流媒体播放端 (macOS 原生版)   "
    echo "         Maintainer: syameimaru-ayaya         "
    echo "=================================================="
    echo "步骤 1/3：请选择播放电台频道："
    echo "  1) 东方音乐电台 (主频道) [全量随机 · 130,000+ 首曲目]"
    echo "  2) 东方音乐电台 (精选频道) [人工精选 · 500+ 首优质同人曲]"
    echo "--------------------------------------------------"

    if [ -t 0 ]; then
        read -rp "请输入选项 [1/2，直接回车默认选 1]: " CHANNEL_CHOICE
    elif [ -r /dev/tty ] && [ -t 1 ]; then
        read -rp "请输入选项 [1/2，直接回车默认选 1]: " CHANNEL_CHOICE < /dev/tty
    else
        CHANNEL_CHOICE=1
    fi
fi

case "$CHANNEL_CHOICE" in
    2)
        STATION_ID="touhou-curated"
        STATION_NAME="东方综合精选频道"
        ;;
    *)
        STATION_ID="touhou"
        STATION_NAME="东方综合主频道"
        ;;
esac

STREAM_DOMESTIC="https://radio.zyghit.cn/radio/${STATION_ID}/320k"
STREAM_INTERNATIONAL="https://radio.yunmoan.cn/radio/${STATION_ID}/320k"
API_STATUS_URL="${API_BASE}/api/stations/${STATION_ID}/status"

if [[ -z "$SOURCE_CHOICE" ]]; then
    echo -e "\n已选定频道: \033[1;35m$STATION_NAME ($STATION_ID)\033[0m"
    echo "--------------------------------------------------"
    echo "步骤 2/3：请选择音频源线路："
    echo "  1) 国内音频源 (radio.zyghit.cn) [低延迟，国内推荐]"
    echo "  2) 国际音频源 (radio.yunmoan.cn) [海外优质节点]"
    echo "--------------------------------------------------"

    if [ -t 0 ]; then
        read -rp "请输入选项 [1/2，直接回车默认选 1]: " SOURCE_CHOICE
    elif [ -r /dev/tty ] && [ -t 1 ]; then
        read -rp "请输入选项 [1/2，直接回车默认选 1]: " SOURCE_CHOICE < /dev/tty
    else
        SOURCE_CHOICE=1
    fi
fi

case "$SOURCE_CHOICE" in
    2)
        STREAM_URL="$STREAM_INTERNATIONAL"
        SOURCE_NAME="国际音频源 (yunmoan.cn)"
        ;;
    *)
        STREAM_URL="$STREAM_DOMESTIC"
        SOURCE_NAME="国内音频源 (zyghit.cn)"
        ;;
esac

if [[ -z "$USER_CHOICE" ]]; then
    echo -e "\n已选定音频源: \033[1;32m$SOURCE_NAME\033[0m"
    echo "--------------------------------------------------"
    echo "步骤 3/3：请选择拉流的网络协议："
    echo "  1) 强制 IPv4 (-4)"
    echo "  2) 强制 IPv6 (-6)"
    echo "  3) 自动双栈 (由系统调度)"
    echo "--------------------------------------------------"

    if [ -t 0 ]; then
        read -rp "请输入选项 [1/2/3，直接回车默认选 3]: " USER_CHOICE
    elif [ -r /dev/tty ] && [ -t 1 ]; then
        read -rp "请输入选项 [1/2/3，直接回车默认选 3]: " USER_CHOICE < /dev/tty
    else
        USER_CHOICE=3
    fi
fi

case "$USER_CHOICE" in
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

echo -e "\n已选定配置:"
echo -e "  频道: \033[1;35m$STATION_NAME ($STATION_ID)\033[0m"
echo -e "  线路: \033[1;32m$SOURCE_NAME\033[0m | 模式: \033[1;32m$IP_NAME\033[0m"
if [[ "$PLAYER_BACKEND" == "native" ]]; then
    echo -e "  引擎: \033[1;36mmacOS 原生 AVPlayer 引擎 (方案1 - 零外部依赖)\033[0m"
else
    echo -e "  引擎: \033[1;36mVLC 引擎 ($VLC_BIN)\033[0m"
fi
echo "=================================================="
echo "操作提示："
echo "  [+] / [=] 增加音量    [-] / [_] 降低音量"
echo "  [Space] / [p] 暂停/播放  [m] 静音切换"
echo "  [f] / [r] 曲目反馈    [q] 退出播放"
echo "=================================================="

# ----------------- 5. 启动播放引擎与后台状态监控 -----------------
rm -f "$CTRL_SOCK" "$FIFO_PATH"

send_cmd() {
    local cmd="$1"
    echo "$cmd" | nc -U "$CTRL_SOCK" 2>/dev/null
}

format_time() {
    local s=$1
    printf "%02d:%02d" $((s / 60)) $((s % 60))
}

render_vol_bar() {
    local vol=$1
    local width=15
    local filled=$((vol * width / 100))
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

CONTACT_CACHE_FILE="$CACHE_DIR/contact"

handle_feedback() {
    tput cnorm 2>/dev/null
    echo -e "\n"
    echo "=================================================="
    local track_info="当前播放曲目"
    if [[ -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
        IFS=$'\t' read -r cur_artist cur_title _ _ _ < "$STATUS_FILE"
        [[ -n "$cur_title" && "$cur_title" != "未知曲目" ]] && track_info="${cur_artist} - ${cur_title}"
    fi
    echo -e "\033[1;36m[曲目反馈]\033[0m 当前曲目: \033[1;35m${track_info}\033[0m"
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
    if [ -t 0 ]; then
        read -rp "请输入类型编号 [1-6, 0 取消, 默认 1]: " type_choice
    elif [ -r /dev/tty ]; then
        read -rp "请输入类型编号 [1-6, 0 取消, 默认 1]: " type_choice < /dev/tty
    else
        type_choice=0
    fi

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
            echo -e "\033[1;33m已取消反馈，继续播放。\033[0m"
            sleep 1
            return 0
            ;;
        *)
            echo -e "\033[1;31m输入无效，已取消反馈。\033[0m"
            sleep 1
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
    if [ -t 0 ]; then
        read -rp "请输入联系方式 (留空默认 [$default_contact]): " fb_contact
    elif [ -r /dev/tty ]; then
        read -rp "请输入联系方式 (留空默认 [$default_contact]): " fb_contact < /dev/tty
    fi
    [[ -z "$fb_contact" ]] && fb_contact="$default_contact"

    # 写入缓存文件
    mkdir -p "$CACHE_DIR"
    echo "$fb_contact" > "$CONTACT_CACHE_FILE"

    # 补充说明 (可选)
    local fb_msg=""
    if [ -t 0 ]; then
        read -rp "请输入补充说明 (可选，直接回车跳过): " fb_msg
    elif [ -r /dev/tty ]; then
        read -rp "请输入补充说明 (可选，直接回车跳过): " fb_msg < /dev/tty
    fi

    echo -e "\033[1;34m正在提交反馈到服务端...\033[0m"

    local payload
    payload=$(osascript -l JavaScript -e '
        function run(argv) {
            return JSON.stringify({
                type: argv[0],
                contact: argv[1],
                message: argv[2],
                pageUrl: "thmr-cli-macos"
            });
        }
    ' "$fb_type" "$fb_contact" "$fb_msg" 2>/dev/null)

    local resp
    resp=$(curl -sS -X POST "${API_BASE}/api/stations/${STATION_ID}/feedback" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)

    local fb_result
    fb_result=$(osascript -l JavaScript -e '
        function run(argv) {
            try {
                var d = JSON.parse(argv[0]);
                if (d.ok) {
                    var count = d.feedbackCountForTrack || 1;
                    var thresh = d.autoSkipThreshold || 5;
                    var autoSkip = d.autoSkipRequested ? "1" : "0";
                    return "OK\t" + (d.feedbackId || "") + "\t" + count + "\t" + thresh + "\t" + autoSkip;
                } else {
                    return "ERR\t" + (d.error || "未知错误");
                }
            } catch(e) {
                return "ERR\t解析响应失败";
            }
        }
    ' "$resp" 2>/dev/null)

    local res_status="" res_id="" res_count="" res_thresh="" res_skip=""
    IFS=$'\t' read -r res_status res_id res_count res_thresh res_skip <<< "$fb_result"

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
    echo -e "正在恢复播放显示...\n"
    sleep 2
}

if [[ "$PLAYER_BACKEND" == "native" ]]; then
    # --- 启动 macOS 原生 AVPlayer 引擎 ---
    ensure_native_player
    echo -e "\033[1;34m[$(date '+%H:%M:%S')] 正在通过原生 AVPlayer 连接音频流...\033[0m"

    "$SWIFT_BIN" "$STREAM_URL" "$CTRL_SOCK" >"$LOG_FILE" 2>&1 &
    PLAYER_PID=$!

else
    # --- 启动 VLC 引擎 (完美兼容 /Applications/VLC.app) ---
    echo -e "\033[1;34m[$(date '+%H:%M:%S')] 正在通过 VLC 连接音频流...\033[0m"
    mkfifo "$FIFO_PATH"
    exec 3<> "$FIFO_PATH"

    curl_fetcher() {
        local retry_delay=2
        local fail_count=0
        while true; do
            local start_time=$(date +%s)
            curl -sS -L -N --connect-timeout 10 $IP_FLAG "$STREAM_URL" >&3 2>>"$LOG_FILE"
            local exit_code=$?
            [[ $exit_code -eq 130 || $exit_code -eq 143 || $exit_code -eq 137 ]] && break
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))
            if [[ $duration -ge 10 ]]; then
                fail_count=0
            else
                ((fail_count++))
            fi
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

    # 注意：macOS 下必须去除 Linux 专属的 --no-one-instance 参数
    "$VLC_BIN" -q -I dummy \
         --extraintf oldrc \
         --rc-unix "$CTRL_SOCK" \
         --rc-fake-tty \
         --no-video \
         --meta-title "THMR 东方音乐电台" \
         "$FIFO_PATH" >/dev/null 2>&1 &
    PLAYER_PID=$!
fi

# 等待套接字就绪
for ((i = 0; i < 30; i++)); do
    [[ -S "$CTRL_SOCK" ]] && break
    sleep 0.1
done

if [[ ! -S "$CTRL_SOCK" ]]; then
    echo -e "\033[1;31m[错误] 控制套接字初始化失败！日志如下：\033[0m"
    cat "$LOG_FILE" 2>/dev/null
    cleanup
fi

echo -e "\033[1;32m[$(date '+%H:%M:%S')] 播放已就绪，正在获取当前曲目信息...\033[0m\n"

# ----------------- 6. 启动后台曲目状态轮询进程 -----------------
status_fetcher() {
    while true; do
        if curl -sS --max-time 4 "$API_STATUS_URL" > "$STATUS_RAW" 2>/dev/null; then
            local parsed
            parsed=$(osascript -l JavaScript "$STATUS_SCRIPT" "$STATUS_RAW" 2>/dev/null)
            if [[ -n "$parsed" ]]; then
                echo "$parsed" > "$STATUS_FILE"
            fi
        fi
        sleep 5
    done
}
status_fetcher &
STATUS_FETCHER_PID=$!

# ----------------- 7. 前台热键监听与实时进度刷新循环 -----------------
SHOW_VOL_UNTIL=0
IS_PAUSED=0
IS_MUTED=0

while true; do
    # 检查播放进程存活
    if ! kill -0 "$PLAYER_PID" 2>/dev/null; then
        echo -e "\n\033[1;33m[$(date '+%H:%M:%S')] 播放核心进程已退出。\033[0m"
        break
    fi

    # 检查 curl 状态 (若为 VLC 模式)
    if [[ "$PLAYER_BACKEND" == "vlc" ]] && ! kill -0 "$CURL_PID" 2>/dev/null; then
        echo -e "\n\033[1;31m[错误] curl 拉流守护进程意外退出！\033[0m"
        break
    fi

    got_key=0
    key=""
    if [ -t 0 ]; then
        if read -r -s -n 1 -t 1 key; then
            got_key=1
        fi
    elif [ -r /dev/tty ]; then
        if read -r -s -n 1 -t 1 key < /dev/tty; then
            got_key=1
        fi
    else
        sleep 1
    fi

    if [[ $got_key -eq 1 ]]; then
        case "$key" in
            +|"=")
                if [[ "$PLAYER_BACKEND" == "native" ]]; then
                    resp=$(send_cmd "volup 5")
                    vol=$(echo "$resp" | awk '{print $2}')
                    [[ -n "$vol" ]] && render_vol_bar "$vol"
                else
                    send_cmd "volup 2"
                    echo -ne "\r\033[K\033[1;36m[$(date '+%H:%M:%S')] 音量 +2\033[0m"
                fi
                SHOW_VOL_UNTIL=$(( $(date +%s) + 2 ))
                ;;
            -|_)
                if [[ "$PLAYER_BACKEND" == "native" ]]; then
                    resp=$(send_cmd "voldown 5")
                    vol=$(echo "$resp" | awk '{print $2}')
                    [[ -n "$vol" ]] && render_vol_bar "$vol"
                else
                    send_cmd "voldown 2"
                    echo -ne "\r\033[K\033[1;36m[$(date '+%H:%M:%S')] 音量 -2\033[0m"
                fi
                SHOW_VOL_UNTIL=$(( $(date +%s) + 2 ))
                ;;
            " "|p|P)
                if [[ "$PLAYER_BACKEND" == "native" ]]; then
                    resp=$(send_cmd "toggle")
                    if [[ "$resp" == *"PAUSED"* ]]; then
                        IS_PAUSED=1
                        echo -ne "\r\033[K\033[1;33m[$(date '+%H:%M:%S')] ⏸ 播放已暂停 (按 Space 或 P 恢复)\033[0m"
                    else
                        IS_PAUSED=0
                    fi
                else
                    send_cmd "pause"
                    if [[ $IS_PAUSED -eq 0 ]]; then
                        IS_PAUSED=1
                        echo -ne "\r\033[K\033[1;33m[$(date '+%H:%M:%S')] ⏸ 播放已暂停 (按 Space 或 P 恢复)\033[0m"
                    else
                        IS_PAUSED=0
                    fi
                fi
                ;;
            m|M)
                if [[ "$PLAYER_BACKEND" == "native" ]]; then
                    resp=$(send_cmd "mute")
                    if [[ "$resp" == *"MUTED"* ]]; then
                        IS_MUTED=1
                        echo -ne "\r\033[K\033[1;31m[$(date '+%H:%M:%S')] 🔇 已静音 (按 M 恢复)\033[0m"
                    else
                        IS_MUTED=0
                    fi
                fi
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

    # 实时刷新曲目元数据与进度条 (当未在调节音量、且未处于暂停/静音提示状态时)
    now_epoch=$(date +%s)
    if [[ $now_epoch -ge $SHOW_VOL_UNTIL && $IS_PAUSED -eq 0 && $IS_MUTED -eq 0 ]]; then
        if [[ -f "$STATUS_FILE" && -s "$STATUS_FILE" ]]; then
            IFS=$'\t' read -r cur_artist cur_title cur_started_ms cur_dur cur_listeners < "$STATUS_FILE"
            if [[ -n "$cur_title" && "$cur_title" != "未知曲目" ]]; then
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
