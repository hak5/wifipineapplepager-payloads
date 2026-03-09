# ⚡ OPKG Package Installer

> Minimal. Fast. No wasted calls.\
> Designed for OpenWRT / embedded payload environments.

------------------------------------------------------------------------

## 🧠 What It Does

-   Checks internet connectivity\
-   Shows installed packages\
-   Lets you enter one or multiple package names\
-   Detects what's missing\
-   Confirms before install\
-   Runs `opkg update` once\
-   Installs all selected packages in one shot\
-   Verifies success

No redundant `opkg` spam. No unnecessary updates. Clean execution.

------------------------------------------------------------------------

## 💻 Usage

When prompted, enter one or more packages:

python3

or

python3 nmap curl

Already installed packages are skipped automatically.

------------------------------------------------------------------------

## ⚙️ Core Logic

Cache installed packages:

opkg list-installed \| awk '{print \$1}'

Update once:

opkg update

Install once:

opkg -d mmc install "\${packages_to_install\[@\]}"

------------------------------------------------------------------------

## 🧨 Built For

-   OpenWRT
-   Embedded Linux
-   Field payload devices
-   Operator-driven installs
-   Lightweight provisioning

------------------------------------------------------------------------

## 🔐 Behavior

-   Exits if offline
-   Skips declined packages
-   Continues execution cleanly
-   Verifies installs after completion

------------------------------------------------------------------------

Stay lightweight.\
Stay efficient.\
Install only what you need.
