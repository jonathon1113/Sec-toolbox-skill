#!/usr/bin/env python3
"""pty_runner.py - 在伪终端(TTY)下运行命令，并按规则自动应答提示

为什么需要它：
  雷池官方安装脚本 manager.py 会检查 "STDIN 不是标准的 TTY"，
  非交互环境下直接报错退出；而且它会询问「选择动作」「安装目录」等问题。
  本脚本用 pty 分配真终端，并按规则自动回答，保证可无人值守安装。

规则（按顺序匹配，命中即应答）:
  选择动作 / 1.安装      -> "1"
  安装目录                -> 空行（使用默认 /data/safeline）
  端口                    -> 空行（使用默认）
  是否 / 确认 / 继续 / 创建 -> "n"（跳过可选步骤）

用法: python3 pty_runner.py "<要执行的命令>" [日志文件]
"""
import os
import pty
import re
import select
import sys
import time

RULES = [
    (re.compile(r"选择你要执行的动作|选择动作|1\.安装"), "1\n"),
    (re.compile(r"安装目录"), "\n"),
    (re.compile(r"端口"), "\n"),
    (re.compile(r"是否|确认|继续|创建|要不要"), "n\n"),
]


def main():
    if len(sys.argv) < 2:
        print("用法: pty_runner.py \"<命令>\" [日志文件]", file=sys.stderr)
        return 2

    cmd = sys.argv[1]
    log_path = sys.argv[2] if len(sys.argv) > 2 else None

    logf = open(log_path, "ab", buffering=0) if log_path else None

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm"
        os.execvp("bash", ["bash", "-c", cmd])
        os._exit(127)

    buf = b""
    last_send = 0.0
    try:
        while True:
            ready, _, _ = select.select([fd], [], [], 1.0)
            if ready:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                if logf:
                    logf.write(data)
                buf += data
            text = buf.decode("utf-8", "replace")
            for pat, reply in RULES:
                if pat.search(text) and time.time() - last_send > 2.0:
                    try:
                        os.write(fd, reply.encode())
                    except OSError:
                        pass
                    last_send = time.time()
                    buf = b""
                    break
            if os.waitpid(pid, os.WNOHANG)[0] != 0:
                # 子进程已退出，读取剩余输出
                try:
                    rest = os.read(fd, 65536)
                    if rest and logf:
                        logf.write(rest)
                except OSError:
                    pass
                break
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.close(fd)
        except Exception:
            pass
        if logf:
            logf.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
