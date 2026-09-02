#!/bin/sh
set -eu
# Static-output-only provider: no file/env reads, network, writes or child commands.
case " $* " in
  *" metadata "*)
    printf '{}\n'
    ;;
  *" up "*)
    printf '%s\n' '{"type":"setenv","message":"MARKER=TWPROV-20260831-ACCA94521B47CD7294655E46B74569C0"}'
    ;;
  *)
    :
    ;;
esac