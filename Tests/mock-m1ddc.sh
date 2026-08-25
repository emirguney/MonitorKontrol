#!/bin/zsh
set -u

case "$*" in
  "display list detailed")
    print '[1] LG UltraFine (TEST-UUID)'
    print ' - Product name:  LG UltraFine'
    ;;
  "display 1 get luminance") print '55' ;;
  "display 1 max luminance") print '100' ;;
  "display 1 get contrast") print '72' ;;
  "display 1 max contrast") print '100' ;;
  "display 1 get volume") print '24' ;;
  "display 1 max volume") print '100' ;;
  "display 1 get mute") print '2' ;;
  "display 1 get input") exit 1 ;;
  "display 1 get input-alt") print '210' ;;
  "display 1 set "*) print "Writing ${@: -1}" ;;
  *) exit 1 ;;
esac
