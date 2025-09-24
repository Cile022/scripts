#!/usr/bin/env bash
# net_mount_v01.sh — whiptail starter with ASCII welcome screen

# ASCII art for welcome
ASCII_ART="
{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}
{}                                    {}
{}    ____ _ _       ___ ____  ____   {}
{}   / ___(_) | ___ / _ \___ \|___ \  {}
{}  | |   | | |/ _ \ | | |__) | __) | {}
{}  | |___| | |  __/ |_| / __/ / __/  {}
{}   \____|_|_|\___|\___/_____|_____| {}
{}                                    {}
{}                                    {}
{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}
"

# Show welcome splash
whiptail --title "Welcome" --msgbox "$ASCII_ART\n\nWelcome to the SMB Helper Script!" 15 60

# Main menu loop
while true; do
  CHOICE=$(whiptail --title "Simple Menu (v0.1)" --menu "Choose an option:" 15 50 4 \
    "1" "Option 1" \
    "2" "Option 2" \
    "3" "Exit script" 3>&1 1>&2 2>&3)

  exitstatus=$?
  if [ $exitstatus -ne 0 ]; then
    whiptail --title "Exit" --msgbox "Cancelled. Exiting script." 8 40
    exit 0
  fi

  case "$CHOICE" in
    1)
      whiptail --title "Result" --msgbox "Option 1 selected" 8 40
      ;;
    2)
      whiptail --title "Result" --msgbox "Option 2 selected" 8 40
      ;;
    3)
      whiptail --title "Exit" --msgbox "Exiting script. Bye!" 8 40
      exit 0
      ;;
    *)
      whiptail --title "Error" --msgbox "Invalid choice." 8 40
      ;;
  esac
done
