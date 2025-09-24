#!/usr/bin/env bash
# net_mount_v01.sh — ultra-simple starter menu

while true; do
  echo
  echo "========================"
  echo "   Simple Menu (v0.1)   "
  echo "========================"
  echo "1) Option 1"
  echo "2) Option 2"
  echo "3) Exit"
  echo -n "Choose an option [1-3]: "
  read -r choice

  case "$choice" in
    1)
      echo "Option 1 selected"
      ;;
    2)
      echo "Option 2 selected"
      ;;
    3)
      echo "Exiting script. Bye!"
      exit 0
      ;;
    *)
      echo "Invalid selection. Please choose 1, 2, or 3."
      ;;
  esac
done
