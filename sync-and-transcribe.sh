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
TRANSCRIPTS_DIR="$REPO_DIR/transcripts"

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
    python3 -c "import opencc" 2>/dev/null || missing+=("opencc (pip install opencc)")

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
    for f in "$AUDIO_SRC"/*.m4a "$AUDIO_SRC"/*.M4A; do
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

# ---------- Step 2: Whisper 转写 ----------
transcribe() {
    echo ""
    echo "========== Step 2: 语音转文字 =========="

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

# ---------- Step 3: 繁体转简体（仅处理新增的 txt） ----------
convert_t2s() {
    echo ""
    echo "========== Step 3: 繁体 → 简体 =========="

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

        python3 -c "
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

# ---------- Step 4: Git 提交推送 ----------
git_push() {
    echo ""
    echo "========== Step 4: Git 提交推送 =========="

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

    git push origin main
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
    transcribe
    convert_t2s
    git_push

    echo ""
    echo "🎉 全部完成！"
    echo "👉 查看播放页: https://sheng-2000.github.io/audio-player/"
}

main "$@"
