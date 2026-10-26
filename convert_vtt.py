#!/usr/bin/env python3
import sys
import os

def vtt_to_text(vtt_path):
    with open(vtt_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    result = []
    skip = False
    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line == 'WEBVTT':
            continue
        # 跳过序号行（纯数字）
        if line.isdigit():
            continue
        # 跳过时间戳行（包含 -->）
        if '-->' in line:
            continue
        # 保留内容行
        result.append(line)
    
    return '\n'.join(result)

if __name__ == '__main__':
    vtt_path = '/sessions/69e1ea7eabb40e2720eae97c/workspace/transcripts/马可福音 3-07~19.vtt'
    txt_path = '/sessions/69e1ea7eabb40e2720eae97c/workspace/transcripts/马可福音 3-07~19.txt'
    
    text = vtt_to_text(vtt_path)
    with open(txt_path, 'w', encoding='utf-8') as f:
        f.write(text)
    
    print(f"vtt 转 txt 完成：{txt_path}")
