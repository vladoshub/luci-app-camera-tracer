#!/bin/sh

logger -t camera-tracer-hook \
  "trigger source=$1 photo=$2 video=$3 epoch=$4 time=$5"