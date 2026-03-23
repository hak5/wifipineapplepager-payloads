#!/usr/bin

# Title:  Package Installer
# Author: spywill
# Description: Install packages by entering package name
# Version: 1.0

# Check internet connection
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
	LOG green "Online"
else
	ERROR_DIALOG "Offline internet connection is required exiting"
	exit
fi

PROMPT "Title: Package Installer

Enter the names of the package to be
installed example: (python3) (python3 nmap)

press any button to continue"

LOG yellow "List of already installed package:"
installed_packages="$(opkg list-installed | awk '{print $1}')"
LOG "$installed_packages"

LOG yellow "Press A button to continue."
WAIT_FOR_BUTTON_PRESS A

user_input=$(TEXT_PICKER "Enter name of Package" "python3")

missing_packages=()
packages_to_install=()
packages=($user_input)

# Check which packages are missing (no repeated opkg calls)
for package in "${packages[@]}"; do
	if echo "$installed_packages" | grep -qx "$package"; then
		LOG yellow "Package $package is already installed."
	else
		missing_packages+=("$package")
		LOG red "Missing package $package."
	fi
done

# If nothing is missing → continue payload
if [ ${#missing_packages[@]} -eq 0 ]; then
	LOG green "All selected packages are already installed."
else
	# Ask confirmation
	for package in "${missing_packages[@]}"; do
		install=$(CONFIRMATION_DIALOG "Install $package")

		case "$install" in
			"$DUCKYSCRIPT_USER_CONFIRMED")
				LOG yellow "User selected yes install $package."
				packages_to_install+=("$package")
				;;
			"$DUCKYSCRIPT_USER_DENIED")
				LOG yellow "User skipped $package."
				;;
			*)
				LOG red "Unknown response for $package — skipping."
				;;
		esac
	done

	# Run update ONCE if we have anything to install
	if [ ${#packages_to_install[@]} -gt 0 ]; then
		spinnerid=$(START_SPINNER "Updating and installing packages...")
		opkg update
		opkg -d mmc install "${packages_to_install[@]}"
		STOP_SPINNER "$spinnerid"

		# Refresh installed cache ONCE
		installed_packages="$(opkg list-installed | awk '{print $1}')"

		# Verify installs
		for package in "${packages_to_install[@]}"; do
			if echo "$installed_packages" | grep -qx "$package"; then
				LOG green "$package installed successfully."
			else
				ERROR_DIALOG "Failed to install $package."
			fi
		done
	fi
fi
