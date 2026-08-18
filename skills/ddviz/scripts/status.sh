#!/bin/sh
# Reports whether ddviz is enabled or disabled.
test -e "${DDVIZ_DATA_DIR:-$HOME/.ddviz}/DDVIZ_DISABLED" && echo disabled || echo enabled
