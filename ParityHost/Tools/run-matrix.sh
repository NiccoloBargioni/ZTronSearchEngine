#!/bin/sh
# Runs the parity matrix on the simulators of this Mac. See matrix.py for the options.
exec python3 "$(dirname "$0")/matrix.py" "$@"
