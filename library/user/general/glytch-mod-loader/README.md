# Glytch Mod Loader

Browse the GlytchModPayloads catalog on the WiFi Pineapple Pager and install individual payloads with their supporting files.

## Requirements

- Pager firmware 1.0.8 or newer
- Bash, curl, Git with HTTPS and partial-clone support
- Internet connection

## Use

Place this directory in `/root/payloads/user/general/glytch-mod-loader/` and open it from the General payload menu. Choose a folder, then a payload. Existing installations prompt before updating.

Payloads install into the category declared in their `Category` header, defaulting to `general`. The loader exits after installation; launch the installed payload separately.

Updates retain other installed files. Interrupted copies are not rolled back.
