#!/bin/sh
cd /Users/keepup/Developer/keepr-bridge
nohup .build/arm64-apple-macosx/debug/KeeprApp > /tmp/keeprapp.log 2>&1 &
echo $!
