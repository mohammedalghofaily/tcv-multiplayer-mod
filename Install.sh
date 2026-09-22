#!/bin/sh
# Linux counterpart to Install.bat. Run it from a terminal, optionally with the
# path to your game's .x86_64 (or .exe) after it. Like Install.bat it never
# downloads or installs Python itself; your distro's package manager does that.

cd "$(dirname "$0")" || exit 1

if [ ! -f install_mod.py ]; then
    echo "I can't find install_mod.py, which should be sat right next to this file."
    echo "Extract the whole download first rather than running this out of the zip."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "This needs Python 3, and it isn't installed. Install it with your"
    echo "package manager (the package is usually called python3 or python),"
    echo "then run this again."
    exit 1
fi

python3 install_mod.py "$@"
result=$?
if [ "$result" -ne 0 ]; then
    echo
    echo "Something went wrong. The message above says what."
    echo "If you're stuck, open an issue on GitHub and attach the diagnostics zip."
fi
exit "$result"
