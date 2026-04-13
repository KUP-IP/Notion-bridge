#!/bin/bash
cd "$(dirname "$0")"
echo "=== Building NotionBridge (debug) ==="
swift build -c debug 2>&1
if [ $? -eq 0 ]; then
    echo ""
    echo "=== Build succeeded — launching app ==="
    open .build/NotionBridge.app
else
    echo ""
    echo "=== Build FAILED — see errors above ==="
    read -p "Press Enter to close..."
fi
