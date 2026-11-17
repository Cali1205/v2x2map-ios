#!/bin/sh
# The repo and its Actions logs are public. Strip signing identities (they contain the
# Apple account holder's real name) and e-mail addresses from xcodebuild output.
exec sed -E \
  -e 's/((Apple|iPhone|iOS) (Development|Distribution|Developer)[^:"]*: )[^"(]*/\1***/g' \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/***@***/g'
