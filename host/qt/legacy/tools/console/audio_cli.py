"""Offline only: decode AQ without importing serial or opening a port."""
import argparse
from dataclasses import asdict
import json
import sys
from protocol import parse_audio


def main():
    parser = argparse.ArgumentParser(description="离线解析AQ回复；不连接串口")
    parser.add_argument("command", choices=("querydecode",))
    parser.add_argument("reply", nargs="?", help="A,<20hex>；省略则从标准输入读取")
    args = parser.parse_args()
    try:
        # Preserve wire CRLF; TextIO newline translation would turn it into LF.
        reply = args.reply if args.reply is not None else sys.stdin.buffer.read(256).decode("ascii")
    except UnicodeDecodeError:
        parser.error("AQ回复必须为ASCII")
    status = parse_audio(reply)
    if status is None:
        parser.error("无效AQ回复：须协议1、20位ASCII hex、合法clip/故障字段；仅允许可选CRLF")
    print(json.dumps(asdict(status), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
