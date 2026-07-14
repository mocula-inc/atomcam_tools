#!/bin/bash

set -Ceu

case "${1:-}" in
  push)
    if [ "$(/bin/ls dist/*zip | wc -l)" -eq 0 ]; then
      echo "Error: No zip files found in dist/. Please run 'make zip' first."
      exit 1
    fi
    if [ -z "${BUCKET:-}" ]; then
      echo "Error: BUCKET variable is not set."
      exit 1
    fi
    SRC=$( /bin/ls ./dist/atomcam_tools_*.zip | sort -n -r | head -n 1)
    DIST=s3://${BUCKET}/firmware/$(basename "$SRC")
    aws s3 cp $SRC $DIST
    echo "Uploaded to $DIST"
    ;;
  *)
    echo "Usage: $0 push"
    exit 1
    ;;
esac
