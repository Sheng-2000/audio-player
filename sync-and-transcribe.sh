#!/bin/bash
# ============================================================
#  马可福音 音频同步 + 语音转文字 一键脚本
#  用法: bash sync-and-transcribe.sh
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
AUDIO_SRC="/Users/sheng/Sheng/MyData/02-任务空间/家庭生活/其他/audio-player"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"   # 脚本所在目录 = 仓库根目录
WHISPER="/Users/sheng/Library/Python/3.9/bin/whisper"
# OpenCC 所需的 Python 解释器（macOS 自带 CLI Tools 的 3.9，已装 opencc）
# 注意：沙箱/部分环境中 `python3` 可能指向无 opencc 的新版本，故显式指定
PYTHON="/Library/Developer/CommandLineTools/usr/bin/python3"
TRANSCRIPTS_DIR="$REPO_DIR/transcripts"

# ffmpeg（压缩用）
FFMPEG="$(command -v ffmpeg || true)"
FFPROBE="$(command -v ffprobe || true)"

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

# ---------- 前置检查 ----------
check_deps() {
    local missing=()
    [[ ! -d "$AUDIO_SRC" ]] && missing+=("音频源目录: $AUDIO_SRC")
    [[ ! -x "$WHISPER" ]]  && missing+=("whisper: $WHISPER")
    [[ -n "$FFMPEG" ]]     || missing+=("ffmpeg (brew install ffmpeg)")
    [[ -n "$FFPROBE" ]]    || missing+=("ffprobe (随 ffmpeg 安装)")
    "$PYTHON" -c "import opencc" 2>/dev/null || missing+=("opencc (pip install opencc)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺少依赖:"
        for m in "${missing[@]}"; do echo "  - $m"; done
        exit 1
    fi
    log "依赖检查通过"
}

# ---------- 检测新增 ----------
check_new_files() {
    NEW_AUDIO=()
    for f in "$AUDIO_SRC"/*.m4a "$AUDIO_SRC"/*.M4A "$AUDIO_SRC"/*.mp3 "$AUDIO_SRC"/*.MP3; do
        [[ -f "$f" ]] || continue
        local basename=$(basename "$f")
        [[ -f "$REPO_DIR/$basename" ]] || NEW_AUDIO+=("$basename")
    done
}

# ---------- Step 1: 同步音频 ----------
sync_audio() {
    echo ""
    echo "========== Step 1: 同步音频 =========="

    if [[ ${#NEW_AUDIO[@]} -eq 0 ]]; then
        warn "没有新增音频，无需同步"
        return
    fi

    for name in "${NEW_AUDIO[@]}"; do
        cp "$AUDIO_SRC/$name" "$REPO_DIR/$name"
        log "新增音频: $name"
    done
    log "共新增 ${#NEW_AUDIO[@]} 个音频文件"
}

# ---------- Step 2: 压缩新增音频（重编码为 mono AAC 24kHz/48kbps） ----------
compress_audio() {
    echo ""
    echo "========== Step 2: 压缩新增音频 =========="

    local count=0
    for name in "${NEW_AUDIO[@]}"; do
        local src="$REPO_DIR/$name"

        # 临时文件与最终输出（mp3 统一转成同名 .m4a）
        local base="${name%.*}"
        local ext="${name##*.}"
        ext="${ext,,}"   # 转小写
        local out_final
        if [[ "$ext" == "mp3" ]]; then
            out_final="$REPO_DIR/${base}.m4a"
        else
            out_final="$src"
        fi
        local tmp="/tmp/reenc_${base}.m4a"

        # 已压缩过（m4a 输出已存在且与仓库同名）则跳过
        if [[ -f "$out_final" && "$ext" != "mp3" ]]; then
            continue
        fi

        log "压缩: $name -> $(basename "$out_final") ..."
        local before after
        before=$(stat -f%z "$src" 2>/dev/null || echo 0)

        # 时长校验用源时长
        local dur_src=0
        dur_src=$("$FFPROBE" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$src" 2>/dev/null | head -1)
        dur_src=${dur_src:-0}

        # 重编码到临时目录（失败不覆盖原文件）
        rm -f "$tmp"
        if ! "$FFMPEG" -y -i "$src" -ac 1 -ar 24000 -b:a 48k -c:a aac "$tmp" >/dev/null 2>&1 || [[ ! -f "$tmp" ]]; then
            err "压缩失败: $name"
            continue
        fi

        # 时长容差校验（±2%）
        local dur_dst=0
        dur_dst=$("$FFPROBE" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp" 2>/dev/null | head -1)
        dur_dst=${dur_dst:-0}
        if [[ -n "$dur_src" ]] && awk -v a="$dur_src" -v b="$dur_dst" 'BEGIN{exit !(a>0 && (b-a)/a > 0.02)}'; then
            warn "时长偏差 $name: $(echo "$dur_src" | cut -d. -f1)s -> $(echo "$dur_dst" | cut -d. -f1)s"
        fi

        # 原子替换；mp3 需删除旧 .mp3
        mv -f "$tmp" "$out_final"
        if [[ "$ext" == "mp3" && -f "$src" && "$src" != "$out_final" ]]; then
            rm -f "$src"
        fi

        local after
        after=$(stat -f%z "$out_final")
        log "压缩完成: $(basename "$out_final")  ($((before/1024))KB -> $((after/1024))KB)"
        ((count++))
    done

    # 同步：若因 mp3->m4a 产生新文件名，需刷新 NEW_AUDIO 列表，让后续转写/繁转简用最终 m4a 名
    NEW_AUDIO=()
    for f in "$REPO_DIR"/*.m4a "$REPO_DIR"/*.M4A; do
        [[ -f "$f" ]] || continue
        local basename=$(basename "$f")
        # 只要该 m4a 在源目录有同名音频，即视为本次新增（压缩后的产物）
        [[ -f "$AUDIO_SRC/$basename" || -f "$AUDIO_SRC/${basename%.*}.mp3" || -f "$AUDIO_SRC/${basename%.*}.MP3" ]] && NEW_AUDIO+=("$basename")
    done

    if [[ $count -eq 0 ]]; then
        warn "没有需要压缩的新增音频"
    else
        log "共压缩 $count 个音频"
    fi
}

# ---------- Step 3: Whisper 转写 ----------
transcribe() {
    echo ""
    echo "========== Step 3: 语音转文字 =========="

    mkdir -p "$TRANSCRIPTS_DIR"

    local count=0
    for f in "$REPO_DIR"/*.m4a "$REPO_DIR"/*.M4A; do
        [[ -f "$f" ]] || continue
        local basename=$(basename "$f")
        local name="${basename%.m4a}"
        name="${name%.M4A}"
        local txt="$TRANSCRIPTS_DIR/${name}.txt"

        if [[ -f "$txt" ]]; then
            continue
        else
            log "正在转写: $basename ..."
            "$WHISPER" "$f" \
                --model tiny \
                --language zh \
                --output_format txt \
                --output_dir "$TRANSCRIPTS_DIR/" \
                2>&1 | tail -1

            if [[ -f "$txt" ]]; then
                log "转写完成: ${name}.txt"
                ((count++))
            else
                err "转写失败: $basename"
            fi
        fi
    done

    if [[ $count -eq 0 ]]; then
        warn "没有新的转写任务"
    else
        log "共转写 $count 个文件"
    fi
}

# ---------- Step 4: 繁体转简体（仅处理新增的 txt） ----------
convert_t2s() {
    echo ""
    echo "========== Step 4: 繁体 → 简体 =========="

    local count=0
    for f in "$REPO_DIR"/*.m4a "$REPO_DIR"/*.M4A; do
        [[ -f "$f" ]] || continue
        local basename=$(basename "$f")
        local name="${basename%.m4a}"
        name="${name%.M4A}"
        local txt="$TRANSCRIPTS_DIR/${name}.txt"

        # 只处理新增音频对应的文字稿
        if [[ ! " ${NEW_AUDIO[*]} " =~ " ${basename} " ]]; then
            continue
        fi
        [[ -f "$txt" ]] || continue

        "$PYTHON" -c "
import opencc
cc = opencc.OpenCC('t2s')
with open('$txt', 'r') as f:
    content = f.read()
simplified = cc.convert(content)
with open('$txt', 'w') as f:
    f.write(simplified)
"
        log "繁转简: $(basename "$txt")"
        ((count++))
    done

    if [[ $count -eq 0 ]]; then
        warn "没有需要繁转简的文件"
    else
        log "共处理 $count 个文字稿"
    fi
}

# ---------- Step 5: Git 提交推送 ----------
git_push() {
    echo ""
    echo "========== Step 5: Git 提交推送 =========="

    cd "$REPO_DIR"

    # 添加所有变更
    git add -A

    # 检查是否有变更
    if git diff --cached --quiet; then
        warn "没有变更需要提交"
        return
    fi

    # 生成 commit message
    local new_audio=$(git diff --cached --name-only --diff-filter=A | grep -c '\.m4a' || true)
    local new_txt=$(git diff --cached --name-only --diff-filter=A | grep -c '\.txt' || true)
    local mod_txt=$(git diff --cached --name-only --diff-filter=M | grep -c '\.txt' || true)

    local msg="sync: "
    local parts=()
    [[ $new_audio -gt 0 ]] && parts+=("${new_audio}个音频")
    [[ $new_txt -gt 0 ]]   && parts+=("${new_txt}个文字稿")
    [[ $mod_txt -gt 0 ]]   && parts+=("${mod_txt}个文字稿更新")

    if [[ ${#parts[@]} -eq 0 ]]; then
        msg+="update"
    else
        msg+=$(IFS='+'; echo "${parts[*]}")
    fi

    git commit -m "$msg"
    log "提交: $msg"

    # 绕过可能存在的本地出口代理（沙箱/公司网络常见 HTTP_PROXY 对 GitHub 返回 502）
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
    git -c http.version=HTTP/1.1 push origin main
    log "已推送到 GitHub"
}

# ---------- 主流程 ----------
main() {
    echo "🎙️  马可福音 音频同步 + 转写工具"
    echo "================================"
    echo "音频源: $AUDIO_SRC"
    echo "仓库:   $REPO_DIR"
    echo ""

    check_deps
    check_new_files

    if [[ ${#NEW_AUDIO[@]} -eq 0 ]]; then
        warn "没有新增音频，无需处理，退出 ✌️"
        exit 0
    fi

    log "检测到 ${#NEW_AUDIO[@]} 个新增音频: ${NEW_AUDIO[*]}"
    sync_audio
    compress_audio
    transcribe
    convert_t2s
    git_push

    echo ""
    echo "🎉 全部完成！"
    echo "👉 查看播放页: https://sheng-2000.github.io/audio-player/"
}

main "$@"
