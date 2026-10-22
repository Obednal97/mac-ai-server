#!/bin/bash
cp "$(dirname "$0")/hooks/pre-push" "$(git rev-parse --git-path hooks)/pre-push" && chmod +x "$(git rev-parse --git-path hooks)/pre-push"
