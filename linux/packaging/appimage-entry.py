"""PyInstaller entry point used only by the portable GNU/Linux build."""

from gantry.app import main


if __name__ == "__main__":
    raise SystemExit(main())
