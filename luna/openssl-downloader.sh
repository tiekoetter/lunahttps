#!/bin/bash

set -e

OPENSSL_DIR="openssl-lts"
DL_DIR="dl"

# Clean destination directory
echo "Cleaning directory: $DL_DIR"
rm -rf "$DL_DIR"
rm -rf "$OPENSSL_DIR"
mkdir -p "$DL_DIR"
cd "$DL_DIR"

# Fetch HTML and find the first [LTS] line, then extract the .tar.gz URL
DOWNLOAD_URL=$(curl -s https://openssl-library.org/source/ | \
  awk '/\[LTS\]/,/<\/tr>/' | \
  grep -oP 'https://github.com/openssl/openssl/releases/download/[^"]+\.tar\.gz' | \
  head -n1)

if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "Failed to find the latest LTS OpenSSL version."
    exit 1
fi

FILENAME=$(basename "$DOWNLOAD_URL")

echo "Downloading OpenSSL LTS from: $DOWNLOAD_URL"
curl -LO "$DOWNLOAD_URL"

# Extract and rename to 'openssl'
echo "Extracting $FILENAME..."
tar -xzf "$FILENAME"

# Get extracted directory name
EXTRACTED_DIR=$(tar -tf "$FILENAME" | head -n1 | cut -d/ -f1)

cd ..
cp -R "$DL_DIR/$EXTRACTED_DIR/" "$OPENSSL_DIR"

echo "Extraction complete. Final directory:"
ls -l "$OPENSSL_DIR"

