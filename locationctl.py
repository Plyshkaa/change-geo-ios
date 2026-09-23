#!/usr/bin/env python3
"""Small, explicit CLI around pymobiledevice3's iOS 17+ CoreDevice path."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
from pathlib import Path


BACKEND = (
    [sys.executable, "--backend"]
    if getattr(sys, "frozen", False)
    else [sys.executable, "-m", "pymobiledevice3"]
)


def build_device_options(udid: str | None, transport: str) -> list[str]:
    options: list[str] = []
    if udid:
        options.extend(["--udid", udid])
    if transport == "native":
        options.append("--native")
    elif transport == "userspace":
        options.append("--userspace")
    return options


def run_backend(arguments: list[str], *, hold: bool = False) -> int:
    command = [*BACKEND, *arguments]
    environment = os.environ.copy()
    environment.setdefault("PYTHONUNBUFFERED", "1")

    if hold:
        print("Location session is active. Press Ctrl+C to stop it.", flush=True)
        try:
            os.execvpe(sys.executable, command, environment)
        except OSError as error:
            print(f"Could not start pymobiledevice3: {error}", file=sys.stderr)
            return 1

    try:
        completed = subprocess.run(command, env=environment)
    except KeyboardInterrupt:
        print("\nStopping location session...", file=sys.stderr)
        return 130
    except OSError as error:
        print(f"Could not start pymobiledevice3: {error}", file=sys.stderr)
        return 1

    if completed.returncode != 0:
        print(
            "The device command failed. Check USB trust, Developer Mode, and the "
            "iOS version's developer services.",
            file=sys.stderr,
        )
    return completed.returncode


def add_connection_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--udid", help="Target one device when several are connected")
    parser.add_argument(
        "--transport",
        choices=("native", "userspace"),
        default="userspace",
        help="iOS 17+ tunnel transport (userspace is the tested default)",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="locationctl",
        description="Control the simulated location of a paired iPhone over USB.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    devices = commands.add_parser("devices", help="List devices visible to usbmuxd")
    devices.add_argument("--usb", action="store_true", help="Only show USB devices")

    set_location = commands.add_parser("set", help="Set one coordinate and keep it active")
    set_location.add_argument("latitude", type=float)
    set_location.add_argument("longitude", type=float)
    set_location.add_argument(
        "--hold-seconds",
        type=float,
        help="Stop automatically after this many seconds instead of waiting for Ctrl+C",
    )
    add_connection_options(set_location)

    clear = commands.add_parser("clear", help="Restore the real device location")
    add_connection_options(clear)

    play = commands.add_parser("play", help="Replay a GPX route")
    play.add_argument("gpx", type=Path)
    play.add_argument("--disable-sleep", action="store_true")
    play.add_argument(
        "--timing-randomness-range",
        type=int,
        default=0,
        help="Random timing noise in milliseconds for each GPX interval",
    )
    add_connection_options(play)

    return parser.parse_args()


def main() -> int:
    if getattr(sys, "frozen", False) and sys.argv[1:2] == ["--backend"]:
        sys.argv = [sys.argv[0], *sys.argv[2:]]
        from pymobiledevice3.__main__ import main as backend_main

        return int(backend_main())

    args = parse_args()

    if args.command == "devices":
        command = ["usbmux", "list"]
        if args.usb:
            command.append("--usb")
        return run_backend(command)

    connection = build_device_options(args.udid, args.transport)

    if args.command == "set":
        if not (-90 <= args.latitude <= 90 and -180 <= args.longitude <= 180):
            print("Coordinates are out of range", file=sys.stderr)
            return 2
        command = [
            "developer",
            "dvt",
            "simulate-location",
            "set",
            str(args.latitude),
            str(args.longitude),
            *connection,
        ]
        if args.hold_seconds is None:
            return run_backend(command, hold=True)

        if args.hold_seconds < 0:
            print("--hold-seconds must be non-negative", file=sys.stderr)
            return 2

        process = subprocess.Popen([*BACKEND, *command], env=os.environ.copy())
        try:
            process.wait(timeout=args.hold_seconds)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGINT)
            process.wait()
        # The backend treats SIGINT as the normal end of its held session.
        return 0 if process.returncode in (0, -signal.SIGINT, 130) else process.returncode

    if args.command == "clear":
        return run_backend(["developer", "dvt", "simulate-location", "clear", *connection])

    if not args.gpx.is_file():
        print(f"GPX file does not exist: {args.gpx}", file=sys.stderr)
        return 2
    if args.timing_randomness_range < 0:
        print("--timing-randomness-range must be non-negative", file=sys.stderr)
        return 2

    return run_backend(
        [
            "developer",
            "dvt",
            "simulate-location",
            "play",
            str(args.gpx),
            "--timing-randomness-range",
            str(args.timing_randomness_range),
            *(["--disable-sleep"] if args.disable_sleep else []),
            *connection,
        ],
        hold=True,
    )


if __name__ == "__main__":
    raise SystemExit(main())
