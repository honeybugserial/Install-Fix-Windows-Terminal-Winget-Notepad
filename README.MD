# Fix Windows Terminal Winget and Notepad for win10 Win11

Powershell script to clean broken packages and re-install.

- I did accident with Winhance which resulted in breaking of terminal, winget, and notepad packages. Winhance also added auto remove to scheduled task, script will check to ensure no auto-removes for packages are set if auto remove is set to remove packages after rebooting windows. 
