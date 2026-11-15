#!/bin/sh
# Samples the UIKit reference into Samples/ios-<major>.json. See sample.py for the options.
exec python3 "$(dirname "$0")/sample.py" "$@"
