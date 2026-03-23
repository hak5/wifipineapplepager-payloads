
n.n.n / 2025-05-22
==================

  * added check for aioquic & updated version to reflect recent changes
  * Merge pull request #310 from ctjf/master
  * Merge pull request #308 from BlWasp/error_code_returned
  * Merge pull request #311 from stfnw/master
  * DHCP poisoner: refactor FindIP
  * added quic support based on xpn's work
  * Indentation typos
  * Add status code control
  * Merge pull request #305 from L1-0/patch-1
  * Update RPC.py
  * Merge pull request #301 from q-roland/kerberos_relaying_llmnr
  * Adding answer name spoofing capabilities when poisoning LLMNR for Kerberos relaying purpose

n.n.n / 2025-05-22
==================

  * added check for aioquic & updated version to reflect recent changes
  * Merge pull request #310 from ctjf/master
  * Merge pull request #308 from BlWasp/error_code_returned
  * Merge pull request #311 from stfnw/master
  * DHCP poisoner: refactor FindIP
  * added quic support based on xpn's work
  * Indentation typos
  * Add status code control
  * Merge pull request #305 from L1-0/patch-1
  * Update RPC.py
  * Merge pull request #301 from q-roland/kerberos_relaying_llmnr
  * Adding answer name spoofing capabilities when poisoning LLMNR for Kerberos relaying purpose
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

<!-- insertion marker -->
## Unreleased

<small>[Compare with latest](https://github.com/lgandx/Responder/compare/v3.1.4.0...HEAD)</small>

### Added

- Add options for poisoners ([807bd57](https://github.com/lgandx/Responder/commit/807bd57a96337ab77f2fff50729a6eb229e5dc37) by f3rn0s).
- Add randomness in TTL value to avoid some EDR detections ([f50f0be](https://github.com/lgandx/Responder/commit/f50f0be59c0de6fd0ff8eef62ba31db96815c878) by nodauf).
- added support for either resolv.conf or resolvectl ([1a2f2fd](https://github.com/lgandx/Responder/commit/1a2f2fdb22a2bf8b04e0ac99219831457b7ba43a) by lgandx).

### Fixed

- Fixed issue with smb signing detection ([413bc8b](https://github.com/lgandx/Responder/commit/413bc8be3169d215f7d5f251a78c8d8404e52f61) by lgandx).
- fixed minor bug ([e51f24e](https://github.com/lgandx/Responder/commit/e51f24e36c1f84bc995a690d385c506c35cc6175) by lgandx).
- Fixed bug when IPv6 is disabled via GRUB. ([fa297c8](https://github.com/lgandx/Responder/commit/fa297c8a16f605bdb731542c67280a4d8bc023c4) by lgandx).

### Removed

- removed debug string ([4b560f6](https://github.com/lgandx/Responder/commit/4b560f6e17493dcfc6bf653d0ebe0547a88735ac) by lgandx).
- removed bowser listener ([e564e51](https://github.com/lgandx/Responder/commit/e564e5159b9a1bfe3c5f1101b3ab11672e0fd46b) by lgandx).

<!-- insertion marker -->
## [v3.1.4.0](https://github.com/lgandx/Responder/releases/tag/v3.1.4.0) - 2024-01-04

<small>[Compare with v3.1.3.0](https://github.com/lgandx/Responder/compare/v3.1.3.0...v3.1.4.0)</small>

### Added

- added LDAPS listener ([6d61f04](https://github.com/lgandx/Responder/commit/6d61f0439c1779767c9ea9840ac433ed98e672cd) by exploide).
- added:error handling on exceptions. ([f670fba](https://github.com/lgandx/Responder/commit/f670fbaa7fcd3b072aef7cf29f43c1d76d6f13bf) by lgandx).
- Added full path to gen-self-sign-cert.sh ([69f431e](https://github.com/lgandx/Responder/commit/69f431e58f07c231e75a73b0782855e9277573ac) by kevintellier).
- add flag (-s) to enable smbv1scan ([cf0c4ee](https://github.com/lgandx/Responder/commit/cf0c4ee659779c027374155716f09b13cb41abb5) by requin).
- add hostname on smbv2 scan result ([709df2c](https://github.com/lgandx/Responder/commit/709df2c6e18ec2fa6647fdaaa4d9f9e2cb7920f8) by requin).
- Added dump by legacy protocols ([b8818ed](https://github.com/lgandx/Responder/commit/b8818ed0c47d9d615c4ba1dcff99e8d2d98296d5) by lgandx).
- added requirements.txt ([00d9d27](https://github.com/lgandx/Responder/commit/00d9d27089d8f02658b08f596d28d1722c276d57) by lgandx).
- Added: append .local TLD to DontRespondToNames + MDNS bug fix ([0bc226b](https://github.com/lgandx/Responder/commit/0bc226b4beaa84eb3ac26f5d563959ccf567262b) by lgandx).
- Added Quiet mode ([2cd66a9](https://github.com/lgandx/Responder/commit/2cd66a9b92aa6ca2b7fba0fea03b0a285c186683) by jb).

### Fixed

- Fixed issue in http srv, more hashes & signature reduction. ([66ee7f8](https://github.com/lgandx/Responder/commit/66ee7f8f08f57926f5b3694ffb9e87619eee576f) by lgandx).
- fixed a TypeError in MSSQLBrowser ([20cdd9c](https://github.com/lgandx/Responder/commit/20cdd9c7c23e620e3d530f76003b94407882e9cd) by exploide).
- fixed 'SyntaxWarning: invalid escape sequence' for Python 3.12+ ([e9bd8a4](https://github.com/lgandx/Responder/commit/e9bd8a43ef353a03ba9195236a3aa5faf3788faa) by exploide).
- fixed minor bug on py 3.10 ([31393c7](https://github.com/lgandx/Responder/commit/31393c70726206fc1056f76ef6b81a981d7954c5) by lgandx).
- fixed HTTP basic auth parsing when password contains colons ([dc33d1f](https://github.com/lgandx/Responder/commit/dc33d1f858e9bbc58ae8edf030dbfee208d748f1) by exploide).
- Fixing soft failure which results in missed SMTP credential interception ([34603ae](https://github.com/lgandx/Responder/commit/34603aed0aadfe3c3625ea729cbc9dc0f06e7e73) by Syntricks).
- Fixing collections import issue for /tools/MultiRelay/odict.py ([aa8d818](https://github.com/lgandx/Responder/commit/aa8d81861bcdfc3dbf253b617ec044fd4807e9d4) by Shutdown).
- Fixing import issue like in /tools/odict.py ([2c4cadb](https://github.com/lgandx/Responder/commit/2c4cadbf7dec6e26ec2494a0cfde38655f5bebaf) by Shutdown).
- fix typo of ServerTlype ([0c80b76](https://github.com/lgandx/Responder/commit/0c80b76f5758dfae86bf4924a49b29c31e2e77f8) by deltronzero).
- Fixed potential disruption on Proxy-Auth ([c51251d](https://github.com/lgandx/Responder/commit/c51251db5ff311743238b1675d52edb7c6849f00) by lgandx).
- fixed the RespondTo/DontRespondTo issue ([2765ef4](https://github.com/lgandx/Responder/commit/2765ef4e668bc3493924aae5032e3ec63078ac42) by lgandx).

### Removed

- removed patreon donation link. ([700b7d6](https://github.com/lgandx/Responder/commit/700b7d6222afe3c1d6fb17a0a522e1166e6ad025) by lgandx).
- removed useless string ([08e44d7](https://github.com/lgandx/Responder/commit/08e44d72acd563910c153749b3c204ce0304bdd1) by lgandx).
- removed debug ([4ea3d7b](https://github.com/lgandx/Responder/commit/4ea3d7b76554dee5160aaf76a0235074590284f8) by lgandx).
- Removed Patreon link ([8e12d2b](https://github.com/lgandx/Responder/commit/8e12d2bcfe11cc23e35ea678b9e4979856183d0e) by lgandx).
- Removed machine accounts dump, since they are not crackable ([c9b5dd0](https://github.com/lgandx/Responder/commit/c9b5dd040e27de95638b33da7a35e5187efb4aac) by lgandx).

## [v3.1.3.0](https://github.com/lgandx/Responder/releases/tag/v3.1.3.0) - 2022-07-26

<small>[Compare with v3.1.2.0](https://github.com/lgandx/Responder/compare/v3.1.2.0...v3.1.3.0)</small>

### Fixed

- Fixed: Warnings on python 3.10 ([9b1c99c](https://github.com/lgandx/Responder/commit/9b1c99ccd29890496b0194c061266997e28be4c0) by lgandx).
- Fix missing paren error ([0c7a3ff](https://github.com/lgandx/Responder/commit/0c7a3ffabeee77cb9f3d960168a357e9583b2f9f) by cweedon).
- Fix double logging of first hash or cleartext ([e7eb3bc](https://github.com/lgandx/Responder/commit/e7eb3bcce85c5d437082214c0e8044919cccee56) by Gustaf Blomqvist).

### Removed

- removed -r reference from help msg. ([983a1c6](https://github.com/lgandx/Responder/commit/983a1c6576cb7dfe6cabea93e56dc4f2c557621b) by lgandx).
- removed -r references ([03fa9a7](https://github.com/lgandx/Responder/commit/03fa9a7187c80586629c58a297d0d78f2f8da559) by lgandx).

## [v3.1.2.0](https://github.com/lgandx/Responder/releases/tag/v3.1.2.0) - 2022-02-12

<small>[Compare with v3.1.1.0](https://github.com/lgandx/Responder/compare/v3.1.1.0...v3.1.2.0)</small>

### Added

- added support for OPT EDNS ([5cf6922](https://github.com/lgandx/Responder/commit/5cf69228cf5ce4c0433904ee1d05955e8fd6f618) by lgandx).

### Fixed

- Fixed options formating in README ([f85ad77](https://github.com/lgandx/Responder/commit/f85ad77d595f5d79b86ddce843bc884f1ff4ac9e) by Andrii Nechytailov).

## [v3.1.1.0](https://github.com/lgandx/Responder/releases/tag/v3.1.1.0) - 2021-12-17

<small>[Compare with v3.0.9.0](https://github.com/lgandx/Responder/compare/v3.0.9.0...v3.1.1.0)</small>

### Added

- Added IPv6 support ([5d4510c](https://github.com/lgandx/Responder/commit/5d4510cc1d0479b13ece9d58ea60d187daf8cdab) by lgandx).
- added: dhcp inform ([3e8c9fd](https://github.com/lgandx/Responder/commit/3e8c9fdb0eceb3eb1f7c6dbc81502b340a5ca152) by lgandx).
- Added DHCP DNS vs DHCP WPAD ([76f6c88](https://github.com/lgandx/Responder/commit/76f6c88df31bbd59dc6dceba1b59251012e45f81) by lgandx).
- Added DHCP DNS vs WPAD srv injection ([9dc7798](https://github.com/lgandx/Responder/commit/9dc779869b5a47fdf26cf79a727ea4a853f0d129) by lgandx).
- Added date and time for each Responder session config log. ([bb17595](https://github.com/lgandx/Responder/commit/bb17595e3fc9fafa58c8979bebc395ed872ef598) by lgandx).

### Removed

- removed fingerprint.py ([0b56d6a](https://github.com/lgandx/Responder/commit/0b56d6aaeb00406b364cf152b258365393d64ccc) by lgandx).

## [v3.0.9.0](https://github.com/lgandx/Responder/releases/tag/v3.0.9.0) - 2021-12-10

<small>[Compare with v3.0.8.0](https://github.com/lgandx/Responder/compare/v3.0.8.0...v3.0.9.0)</small>

### Added

- added the ability to provide external IP on WPAD poison via DHCP ([ba885b9](https://github.com/lgandx/Responder/commit/ba885b9345024809555d1a2c1f8cc463870602bb) by lgandx).
- Added a check for MSSQL ([5680487](https://github.com/lgandx/Responder/commit/568048710f0cf5c04c53fd8e026fdd1b3f5c16e6) by lgandx).

### Fixed

- Fixed the ON/OFF for poisoners when in Analyze mode. ([3cd5140](https://github.com/lgandx/Responder/commit/3cd5140c800d8f4e9e8547e4137cafe33fc2f066) by lgandx).

### Removed

- Remove analyze mode on DNS since you need to ARP to get queries ([17e62bd](https://github.com/lgandx/Responder/commit/17e62bda1aed4884c1f08e514faba8c1e39b36ad) by lgandx).

## [v3.0.8.0](https://github.com/lgandx/Responder/releases/tag/v3.0.8.0) - 2021-12-03

<small>[Compare with v3.0.7.0](https://github.com/lgandx/Responder/compare/v3.0.7.0...v3.0.8.0)</small>

### Added

- Added DB for RunFinger results & Report ([f90b76f](https://github.com/lgandx/Responder/commit/f90b76fed202ee4a6e17a030151c8de4430717a8) by lgandx).
- added timeout option for fine tuning ([a462d1d](https://github.com/lgandx/Responder/commit/a462d1df061b214eebcabdbe3f95caa5dd8ea3c7) by lgandx).
- added DHCP db & updated the report script to reflect that ([1dfa997](https://github.com/lgandx/Responder/commit/1dfa997da8c0fa1e51a1be30b2a3d5f5d92f4b7f) by lgandx).
- Added support for single IP or range file. ([02fb3f8](https://github.com/lgandx/Responder/commit/02fb3f8978286a486d633a707889ea8992a7f43a) by lgandx).

### Fixed

- fix: DHCP now working on VPN interface ([88a2c6a](https://github.com/lgandx/Responder/commit/88a2c6a53b721da995fbbd8e5cd82fb40d4af268) by lgandx).
- Fixed a bug and increased speed. ([1b2a22f](https://github.com/lgandx/Responder/commit/1b2a22facfd54820cc5f8ebba06f5cd996e917dc) by lgandx).

### Removed

- Removed old DHCP script since its now a Responder module. ([d425783](https://github.com/lgandx/Responder/commit/d425783be994b0d2518633e4b93e13e305685e5b) by lgandx).
- removed default certs ([de778f6](https://github.com/lgandx/Responder/commit/de778f66982817f1149408bc2e080371d3d4a71d) by lgandx).
- Removed the static certs and added automatic cert generation ([21afd35](https://github.com/lgandx/Responder/commit/21afd357f828b586cfa96992c8c978024285b162) by lgandx).
- removed debug str ([826b5af](https://github.com/lgandx/Responder/commit/826b5af9e2e37d50afdd3eb3ee66121e6c81c2a2) by lgandx).

## [v3.0.7.0](https://github.com/lgandx/Responder/releases/tag/v3.0.7.0) - 2021-10-26

<small>[Compare with v3.0.6.0](https://github.com/lgandx/Responder/compare/v3.0.6.0...v3.0.7.0)</small>

### Added

- Added DHCP server ([c449b6b](https://github.com/lgandx/Responder/commit/c449b6bcb990959e352967b3842b09978b9b2729) by lgandx).
- Add --lm switch for ESS downgrade ([dcb80d9](https://github.com/lgandx/Responder/commit/dcb80d992e385a0f0fdd3f724a0b040a42439306) by Pixis).
- Add ESS disabling information ([51f8ab4](https://github.com/lgandx/Responder/commit/51f8ab43682973df32534ca97c99fb1318a0c77d) by Pixis).
- Add ESS downgrade parameter ([baf80aa](https://github.com/lgandx/Responder/commit/baf80aa4f0e1aaf9ee81ffe6b0b5089d39f42516) by pixis).

### Fixed

- fixed minor isse ([350058c](https://github.com/lgandx/Responder/commit/350058c1795e43c23950b6bd23c33f45795ec7cc) by lgandx).

## [v3.0.6.0](https://github.com/lgandx/Responder/releases/tag/v3.0.6.0) - 2021-04-19

<small>[Compare with v3.0.5.0](https://github.com/lgandx/Responder/compare/v3.0.5.0...v3.0.6.0)</small>

### Added

- Added WinRM rogue server ([8531544](https://github.com/lgandx/Responder/commit/85315442bd010dd61fcb62de8d6ca9cc969426ba) by lgandx).

## [v3.0.5.0](https://github.com/lgandx/Responder/releases/tag/v3.0.5.0) - 2021-04-17

<small>[Compare with v3.0.4.0](https://github.com/lgandx/Responder/compare/v3.0.4.0...v3.0.5.0)</small>

### Added

- Added dce-rpc module + enhancements + bug fix. ([e91e37c](https://github.com/lgandx/Responder/commit/e91e37c9749f58330e0d68ce062a48b100a2d09e) by lgandx).

### Removed

- removed addiontional RR on SRV answers ([027e6b9](https://github.com/lgandx/Responder/commit/027e6b95c3ca89367cb5123758c2fc29aba27a59) by lgandx).

## [v3.0.4.0](https://github.com/lgandx/Responder/releases/tag/v3.0.4.0) - 2021-04-12

<small>[Compare with v3.0.3.0](https://github.com/lgandx/Responder/compare/v3.0.3.0...v3.0.4.0)</small>

### Added

- Added DNS SRV handling for ldap/kerberos + LDAP netlogon ping ([1271b8e](https://github.com/lgandx/Responder/commit/1271b8e17983bd3969d951ce2b4c9b75600f94b9) by lgandx).
- added a check for exec file ([cc3a5b5](https://github.com/lgandx/Responder/commit/cc3a5b5cfffbb8e7430030aa66a2981feae7fe85) by lgandx).
- Added donation banner. ([8104139](https://github.com/lgandx/Responder/commit/8104139a3535a49caf7ec0ed64e8e33ea686494f) by lgandx).
- added donation address and minor typo ([06f9f91](https://github.com/lgandx/Responder/commit/06f9f91f118b0729a74d3c1810a493886655e6f1) by lgandx).
- added smb filetime support ([b0f044f](https://github.com/lgandx/Responder/commit/b0f044fe4e710597ae73e6f1af87ea246b0cd365) by lgandx).

### Removed

- removed FindSMB2UPTime.py since RunFinger already get this info ([6c51080](https://github.com/lgandx/Responder/commit/6c51080109fd8c9305021336c0dc8c72e01b5541) by lgandx).
- Removed MultiRelay binaries ([35b12b4](https://github.com/lgandx/Responder/commit/35b12b48323b1960960aba916334635d5a590875) by lgandx).
- Removed BindShell executable file ([5d762c4](https://github.com/lgandx/Responder/commit/5d762c4a550f2c578f4d7874f24563240276852d) by lgandx).
- Removed donation banner ([ccee87a](https://github.com/lgandx/Responder/commit/ccee87aa95f2ec16827592ba9d98c4895cec0cb9) by lgandx).
- removed verification ([dd1a674](https://github.com/lgandx/Responder/commit/dd1a67408081c94490a3263c46b2eb0b6107e542) by lgandx).

## [v3.0.3.0](https://github.com/lgandx/Responder/releases/tag/v3.0.3.0) - 2021-02-08

<small>[Compare with v3.0.2.0](https://github.com/lgandx/Responder/compare/v3.0.2.0...v3.0.3.0)</small>

### Added

- Added support for SMB2 signing ([24e7b7c](https://github.com/lgandx/Responder/commit/24e7b7c667c3c9feb1cd3a25b16bd8d9c2df5ec6) by lgandx).
- Added SMB2 support for RunFinger and various other checks. ([e24792d](https://github.com/lgandx/Responder/commit/e24792d7743dbf3a5c5ffac92113e36e5d682e42) by lgandx).

### Fixed

- Fix wrong syntax ([fb10d20](https://github.com/lgandx/Responder/commit/fb10d20ea387448ad084a57f5f4441c908fc53cc) by Khiem Doan).
- fix custom challenge in python3 ([7b47c8f](https://github.com/lgandx/Responder/commit/7b47c8fe4edcb53b035465985d92500b96fb1a84) by ThePirateWhoSmellsOfSunflowers).
- Fix typos in README ([12b796a](https://github.com/lgandx/Responder/commit/12b796a292b87be15ef8eec31cb276c447b9e8c8) by Laban Sköllermark).

## [v3.0.2.0](https://github.com/lgandx/Responder/releases/tag/v3.0.2.0) - 2020-09-28

<small>[Compare with v3.0.1.0](https://github.com/lgandx/Responder/compare/v3.0.1.0...v3.0.2.0)</small>

### Fixed

- Fixed LLMNR/NBT-NS/Browser issue when binding to a specific interface ([af7d27a](https://github.com/lgandx/Responder/commit/af7d27ac8cb3c2b0664a8b0a11940c0f3c25c891) by lgandx).

## [v3.0.1.0](https://github.com/lgandx/Responder/releases/tag/v3.0.1.0) - 2020-08-19

<small>[Compare with v3.0.0.0](https://github.com/lgandx/Responder/compare/v3.0.0.0...v3.0.1.0)</small>

### Added

- Added DNSUpdate.py, a small script to add DNS record to DC for gatering from different VLANs ([05617de](https://github.com/lgandx/Responder/commit/05617defefcd6954915d0b42d73d4ccfcccad2d4) by Sagar-Jangam).

### Fixed

- Fix encoding issue in Python 3 ([7420f62](https://github.com/lgandx/Responder/commit/7420f620825d5a5ae6dc68364a5680910f7f0512) by Sophie Brun).

## [v3.0.0.0](https://github.com/lgandx/Responder/releases/tag/v3.0.0.0) - 2020-01-09

<small>[Compare with v2.3.4.0](https://github.com/lgandx/Responder/compare/v2.3.4.0...v3.0.0.0)</small>

### Added

- Added py3 and py2 compatibility + many bugfix ([b510b2b](https://github.com/lgandx/Responder/commit/b510b2bb2523a3fe24953ac685e697914a60b26c) by lgandx).

## [v2.3.4.0](https://github.com/lgandx/Responder/releases/tag/v2.3.4.0) - 2019-08-17

<small>[Compare with v2.3.3.9](https://github.com/lgandx/Responder/compare/v2.3.3.9...v2.3.4.0)</small>

### Added

- Added RDP rogue server ([c52843a](https://github.com/lgandx/Responder/commit/c52843a5359a143c5a94a74c095d6ac4679cd4b1) by lgandx).
- Added proper changes to RunFinger (and is not checking for MS17-010 straight away) ([105502e](https://github.com/lgandx/Responder/commit/105502edd401615604e09a9a71a268252c82523d) by Paul A).

### Fixed

- Fix socket timeout on HTTP POST requests ([e7a787c](https://github.com/lgandx/Responder/commit/e7a787cbc4e01e92be6e062e94211dca644fae0c) by Crypt0-M3lon).
- fixed minor bugfix on recent merge ([38e721d](https://github.com/lgandx/Responder/commit/38e721da9826b95ed3599151559e8f8c535e4d6e) by lgandx).
- Fix multi HTTP responses ([defabfa](https://github.com/lgandx/Responder/commit/defabfa543f0b567d7e981003c7a00d7f02c3a16) by Clément Notin).
- Fix version number in settings.py ([621c5a3](https://github.com/lgandx/Responder/commit/621c5a3c125646c14db19fc48f30e4075102c929) by Clément Notin).
- Fixed some small typos in MS17-010 output ([daaf6f7](https://github.com/lgandx/Responder/commit/daaf6f7296ee754fe37b2382d0e459f7b6e74dcc) by Chris Maddalena).

### Removed

- removed debug string ([47e63ae](https://github.com/lgandx/Responder/commit/47e63ae4ec3266a35845d0bf116cf17fa0d17fd7) by lgandx).

## [v2.3.3.9](https://github.com/lgandx/Responder/releases/tag/v2.3.3.9) - 2017-11-20

<small>[Compare with v2.3.3.8](https://github.com/lgandx/Responder/compare/v2.3.3.8...v2.3.3.9)</small>

### Added

- Added: check for null sessions and MS17-010 ([b37f562](https://github.com/lgandx/Responder/commit/b37f56264a6b57faff81c12a8143662bf1ddb91d) by lgandx).
- Add ignore case on check body for html inject ([47c3115](https://github.com/lgandx/Responder/commit/47c311553eb38327622d5e6b25e20a662c31c30d) by Lionel PRAT).
- added support for plain auth ([207b0d4](https://github.com/lgandx/Responder/commit/207b0d455c95a5cd68fbfbbc022e5cc3cb41878f) by lgandx).

## [v2.3.3.8](https://github.com/lgandx/Responder/releases/tag/v2.3.3.8) - 2017-09-05

<small>[Compare with v2.3.3.7](https://github.com/lgandx/Responder/compare/v2.3.3.7...v2.3.3.8)</small>

### Changed

- Changed the complete LDAP parsing hash algo (ntlmv2 bug). ([679cf65](https://github.com/lgandx/Responder/commit/679cf65cff0c537b594d284cd01e2ea9c690d4ae) by lgandx).

## [v2.3.3.7](https://github.com/lgandx/Responder/releases/tag/v2.3.3.7) - 2017-09-05

<small>[Compare with v2.3.3.6](https://github.com/lgandx/Responder/compare/v2.3.3.6...v2.3.3.7)</small>

### Added

- Add in check for uptime since March 14th 2017, which could indicate the system is vulnerable to MS17-010 ([5859c31](https://github.com/lgandx/Responder/commit/5859c31e8ecf35c5b12ac653e8ab793bc9270604) by Matt Kelly).
- Add Microsoft SQL Server Browser responder ([bff935e](https://github.com/lgandx/Responder/commit/bff935e71ea401a4477004022623b1617ac090b3) by Matthew Daley).
- added: mimi32 cmd,  MultiRelay random RPC & Namedpipe & latest mimikatz ([38219e2](https://github.com/lgandx/Responder/commit/38219e249e700c1b20317e0b96f4a120fdfafb98) by lgandx).

### Fixed

- Fixed various bugs and improved the LDAP module. ([be26b50](https://github.com/lgandx/Responder/commit/be26b504b5133c78158d9794cd361ce1a7418775) by lgandx).
- Fixed space typo in FindSMB2UPTime.py ([11c0096](https://github.com/lgandx/Responder/commit/11c00969c36b2ed51763ee6c975870b05e84cdcb) by myst404).
- Fixed instances of "CRTL-C" to "CTRL-C" ([44a4e49](https://github.com/lgandx/Responder/commit/44a4e495ccb21098c6b882feb25e636510fc72b9) by Randy Ramos).

## [v2.3.3.6](https://github.com/lgandx/Responder/releases/tag/v2.3.3.6) - 2017-03-29

<small>[Compare with v2.3.3.5](https://github.com/lgandx/Responder/compare/v2.3.3.5...v2.3.3.6)</small>

### Fixed

- Fixed bug in FindSMB2UPTime ([6f3cc45](https://github.com/lgandx/Responder/commit/6f3cc4564c9cf34b75ef5469fd54edd4b3004b54) by lgandx).

### Removed

- Removed Paypal donation link. ([b05bdca](https://github.com/lgandx/Responder/commit/b05bdcab9600ad4e7ef8b70e2d8ee1b03b8b442a) by lgandx).

## [v2.3.3.5](https://github.com/lgandx/Responder/releases/tag/v2.3.3.5) - 2017-02-18

<small>[Compare with v2.3.3.4](https://github.com/lgandx/Responder/compare/v2.3.3.4...v2.3.3.5)</small>

## [v2.3.3.4](https://github.com/lgandx/Responder/releases/tag/v2.3.3.4) - 2017-02-18

<small>[Compare with v2.3.3.3](https://github.com/lgandx/Responder/compare/v2.3.3.3...v2.3.3.4)</small>

### Added

- Added: Hashdump, Stats report ([21d48be](https://github.com/lgandx/Responder/commit/21d48be98fd30a9fd0747588cbbb070ed0ce100b) by lgandx).
- added `ip` commands in addition to ifconfig and netstat ([db61f24](https://github.com/lgandx/Responder/commit/db61f243c9cc3c9821703c78e780e745703c0bb3) by thejosko).

### Fixed

- fixed crash: typo. ([0642999](https://github.com/lgandx/Responder/commit/0642999741b02de79266c730cc262bb3345644f9) by lgandx).
- Fix for RandomChallenge function. Function getrandbits can return less than 64 bits, thus decode('hex') will crash with TypeError: Odd-length string ([de6e869](https://github.com/lgandx/Responder/commit/de6e869a7981d49725e791303bd16c4159d70880) by Gifts).
- Fix Proxy_Auth. Random challenge broke it. ([5a2ee18](https://github.com/lgandx/Responder/commit/5a2ee18bfaa66ff245747cf8afc114a9a894507c) by Timon Hackenjos).

## [v2.3.3.3](https://github.com/lgandx/Responder/releases/tag/v2.3.3.3) - 2017-01-03

<small>[Compare with v2.3.3.2](https://github.com/lgandx/Responder/compare/v2.3.3.2...v2.3.3.3)</small>

### Added

- Added: Random challenge for each requests (default) ([0d441d1](https://github.com/lgandx/Responder/commit/0d441d1899053fde6792288fc83be0c883df19f0) by lgandx).

## [v2.3.3.2](https://github.com/lgandx/Responder/releases/tag/v2.3.3.2) - 2017-01-03

<small>[Compare with v2.3.3.1](https://github.com/lgandx/Responder/compare/v2.3.3.1...v2.3.3.2)</small>

### Added

- Added: Random challenge for each requests (default) ([1d38cd3](https://github.com/lgandx/Responder/commit/1d38cd39af9154f5a9e898428de25fe0afa68d2f) by lgandx).
- Added paypal button ([17dc81c](https://github.com/lgandx/Responder/commit/17dc81cb6833a91300d0669398974f0ed9bc006e) by lgandx).
- Added: Scripting support. -c and -d command line switch ([ab2d890](https://github.com/lgandx/Responder/commit/ab2d8907f033384e593a38073e50604a834f4bf3) by lgandx).
- Added: BTC donation address ([730808c](https://github.com/lgandx/Responder/commit/730808c83c0c7f67370ceeff977b0e727eb28ea4) by lgandx).

### Removed

- Removed ThreadingMixIn. MultiRelay should process one request at the timeand queue the next ones. ([4a7499d](https://github.com/lgandx/Responder/commit/4a7499df039269094c718eb9e19760e79eea86f7) by lgandx).

## [v2.3.3.1](https://github.com/lgandx/Responder/releases/tag/v2.3.3.1) - 2016-10-18

<small>[Compare with v2.3.3.0](https://github.com/lgandx/Responder/compare/v2.3.3.0...v2.3.3.1)</small>

### Added

- Added: Logs dumped files for multiple targets ([d560105](https://github.com/lgandx/Responder/commit/d5601056b386a7ae3ca167f0562cbe87bf004c38) by lgandx).

### Fixed

- Fixed wrong challenge issue ([027f841](https://github.com/lgandx/Responder/commit/027f841cdf11fd0ad129825dcc70d6ac8b5d3983) by lgandx).

## [v2.3.3.0](https://github.com/lgandx/Responder/releases/tag/v2.3.3.0) - 2016-10-12

<small>[Compare with v2.3.2.8](https://github.com/lgandx/Responder/compare/v2.3.2.8...v2.3.3.0)</small>

### Added

- Added: Compability for Multi-Relay ([5b06173](https://github.com/lgandx/Responder/commit/5b0617361ede8df67caad4ca89723ad18a67fa53) by lgandx).

### Fixed

- Fix values for win98 and win10 (requested here: https://github.com/lgandx/Responder/pull/7/commits/d9d34f04cddbd666865089d809eb5b3d46dd9cd4) ([60c91c6](https://github.com/lgandx/Responder/commit/60c91c662607c3991cb760c7dd221e81cfb69518) by lgandx).
- Fixed the bind to interface issue (https://github.com/lgandx/Responder/issues/6) ([ce211f7](https://github.com/lgandx/Responder/commit/ce211f7fcfa7ea9e3431161fec5075ca63730070) by lgandx).
- fixed bug in hash parsing. ([0cf1087](https://github.com/lgandx/Responder/commit/0cf1087010088ef1c3fecc7d2ad851c7c49d0639) by lgandx).

### Changed

- Changed to executable ([3e46ecd](https://github.com/lgandx/Responder/commit/3e46ecd27e53c58c3dc38888a2db1d3340a5a3ab) by lgandx).

## [v2.3.2.8](https://github.com/lgandx/Responder/releases/tag/v2.3.2.8) - 2016-10-06

<small>[Compare with v2.3.2.7](https://github.com/lgandx/Responder/compare/v2.3.2.7...v2.3.2.8)</small>

### Added

- Added: Now delete services on the fly. ([c6e401c](https://github.com/lgandx/Responder/commit/c6e401c2290fbb6c68bbc396915ea3fa7b11b5f0) by lgandx).

## [v2.3.2.7](https://github.com/lgandx/Responder/releases/tag/v2.3.2.7) - 2016-10-05

<small>[Compare with v2.3.2.6](https://github.com/lgandx/Responder/compare/v2.3.2.6...v2.3.2.7)</small>

### Added

- Added: Possibility to target all users. use 'ALL' with -u ([d81ef9c](https://github.com/lgandx/Responder/commit/d81ef9c33ab710f973c68f60cd0b7960f9e4841b) by lgandx).

### Fixed

- Fixed minor bug ([7054c60](https://github.com/lgandx/Responder/commit/7054c60f38cafc7e1c4d8a6ce39e12afbfc8b482) by lgandx).

## [v2.3.2.6](https://github.com/lgandx/Responder/releases/tag/v2.3.2.6) - 2016-10-05

<small>[Compare with v2.3.2.5](https://github.com/lgandx/Responder/compare/v2.3.2.5...v2.3.2.6)</small>

## [v2.3.2.5](https://github.com/lgandx/Responder/releases/tag/v2.3.2.5) - 2016-10-03

<small>[Compare with v2.3.2.4](https://github.com/lgandx/Responder/compare/v2.3.2.4...v2.3.2.5)</small>

### Added

- Added logs folder. ([cd09e19](https://github.com/lgandx/Responder/commit/cd09e19a9363867a75d7db1dea4830969bc0d68e) by lgandx).
- Added: Cross-protocol NTLMv1-2 relay (beta). ([ab67070](https://github.com/lgandx/Responder/commit/ab67070a2b82e94f2abb506a69f8fa8c0dc09852) by lgandx).

### Removed

- Removed logs folder. ([5d83778](https://github.com/lgandx/Responder/commit/5d83778ac7caba920874dc49f7523c6ef80b6d7b) by lgandx).

## [v2.3.2.4](https://github.com/lgandx/Responder/releases/tag/v2.3.2.4) - 2016-09-12

<small>[Compare with v2.3.2.3](https://github.com/lgandx/Responder/compare/v2.3.2.3...v2.3.2.4)</small>

## [v2.3.2.3](https://github.com/lgandx/Responder/releases/tag/v2.3.2.3) - 2016-09-12

<small>[Compare with v2.3.2.2](https://github.com/lgandx/Responder/compare/v2.3.2.2...v2.3.2.3)</small>

### Added

- Added new option in Responder.conf. Capture multiple hashes from the same client. Default is On. ([35d933d](https://github.com/lgandx/Responder/commit/35d933d5964df607ec714ced93e4cb197ff2bfe7) by lgandx).

## [v2.3.2.2](https://github.com/lgandx/Responder/releases/tag/v2.3.2.2) - 2016-09-12

<small>[Compare with v2.3.2.1](https://github.com/lgandx/Responder/compare/v2.3.2.1...v2.3.2.2)</small>

### Added

- Added support for webdav, auto credz. ([ad9ce6e](https://github.com/lgandx/Responder/commit/ad9ce6e659ffd9dd31714260f906c8de02223398) by lgandx).
- Added option -e, specify an external IP address to redirect poisoned traffic to. ([04c270f](https://github.com/lgandx/Responder/commit/04c270f6b75cd8eb833cca3b71965450d925e6ac) by lgandx).

### Removed

- removed debug info ([3e2e375](https://github.com/lgandx/Responder/commit/3e2e375987ce2ae03e6a88ffadabb13823ba859c) by lgandx).

## [v2.3.2.1](https://github.com/lgandx/Responder/releases/tag/v2.3.2.1) - 2016-09-11

<small>[Compare with v2.3.2](https://github.com/lgandx/Responder/compare/v2.3.2...v2.3.2.1)</small>

## [v2.3.2](https://github.com/lgandx/Responder/releases/tag/v2.3.2) - 2016-09-11

<small>[Compare with v2.3.1](https://github.com/lgandx/Responder/compare/v2.3.1...v2.3.2)</small>

### Added

- Added proxy auth server + various fixes and improvements ([82fe64d](https://github.com/lgandx/Responder/commit/82fe64dfd988321cbc1a8cb3d8f01caa38f4193e) by lgandx).
- Added current date for all HTTP headers, avoiding easy detection ([ecd62c3](https://github.com/lgandx/Responder/commit/ecd62c322f48eadb235312ebb1e57375600ef0f1) by lgandx).

### Removed

- Removed useless HTTP headers ([881dae5](https://github.com/lgandx/Responder/commit/881dae59cf3c95047d82b34208f57f94b3e85b04) by lgandx).

## [v2.3.1](https://github.com/lgandx/Responder/releases/tag/v2.3.1) - 2016-09-09

<small>[Compare with v2.3.0](https://github.com/lgandx/Responder/compare/v2.3.0...v2.3.1)</small>

### Added

- Added SMBv2 support enabled by default. ([85d7974](https://github.com/lgandx/Responder/commit/85d7974513a9b6378ed4c0c07a7dd640c27ead9b) by lgandx).
- added new option, for Config-Responder.log file. ([a9c2b29](https://github.com/lgandx/Responder/commit/a9c2b297c6027030e3f83c7626fff6f66d5a4f1b) by lgaffie).
- Add compatability with newer net-tools ifconfig. ([e19e349](https://github.com/lgandx/Responder/commit/e19e34997e68a2f567d04d0c013b7870530b7bfd) by Hank Leininger).
- Add HTTP Referer logging ([16e6464](https://github.com/lgandx/Responder/commit/16e6464748d3497943a9d96848ead9058dc0f7e9) by Hubert Seiwert).
- Added recent Windows versions. ([6eca29d](https://github.com/lgandx/Responder/commit/6eca29d08cdd0d259760667da0c41e76d2cd2693) by Jim Shaver).
- Added: Support for OSx ([59e48e8](https://github.com/lgandx/Responder/commit/59e48e80dd6153f83899413c2fc71a46367d4abf) by lgandx).

### Fixed

- Fixed colors in log files ([d9258e2](https://github.com/lgandx/Responder/commit/d9258e2dd80ab1d62767377250c76bf5c9f2a50d) by lgaffie).
- Fixed the regexes for Authorization: headers. ([a81a9a3](https://github.com/lgandx/Responder/commit/a81a9a31e4dbef2890fbf51830b6a9374d6a8f8a) by Hank Leininger).
- Fix Windows 10 support. ([a84b351](https://github.com/lgandx/Responder/commit/a84b3513e1fdd47025ceaa743ce0f506f162640b) by ValdikSS).
- Fixed color bug in Analyze mode ([04c841d](https://github.com/lgandx/Responder/commit/04c841d34e0d32970f08ae91ad0f931b1b90d6ab) by lgandx).
- fixed minor bug ([6f8652c](https://github.com/lgandx/Responder/commit/6f8652c0fccfe83078254d7b38cb9fd517a6bf42) by lgandx).
- Fixed Icmp-Redirect.. ([df63c1f](https://github.com/lgandx/Responder/commit/df63c1fc138d1682a86bc2114a5352ae897865c6) by lgandx).
- Fixed some tools and +x on some executables ([8171a96](https://github.com/lgandx/Responder/commit/8171a96b9eaac3cd25ef18e8ec8b303c5877f4d0) by lgandx).
- Fix generation of HTTP response in HTTP proxy ([b2830e0](https://github.com/lgandx/Responder/commit/b2830e0a4f46f62db4d34b3e8f93ea505be32000) by Antonio Herraiz).
- Fix misspelling of poisoners ([6edc01d](https://github.com/lgandx/Responder/commit/6edc01d8511189489e4b5fd9873f25712920565c) by IMcPwn).

### Changed

- change IsOSX to utils.IsOsX. Fixes #89 ([08c3a90](https://github.com/lgandx/Responder/commit/08c3a90b400d0aff307dd43ff4cd6f01ca71a6cb) by Jared Haight).
- Changed email address ([f5a8bf0](https://github.com/lgandx/Responder/commit/f5a8bf0650bc088b6ef5ae7432f2baef0d52852c) by lgandx).
- Changed connection to SQlite db to support different encoded charsets ([0fec40c](https://github.com/lgandx/Responder/commit/0fec40c3b4c621ee21a88906e77c6ea7a56cb8a9) by Yannick Méheut).
- Changed comment to be more clear about what is being done when logging ([08535e5](https://github.com/lgandx/Responder/commit/08535e55391d762be4259a1fada330ef3f0ac134) by Yannick Méheut).

### Removed

- Removed the config dump in Responder-Session.log. New file gets created in logs, with host network config such as dns, routes, ifconfig and config dump ([a765a8f](https://github.com/lgandx/Responder/commit/a765a8f0949de37940364d0a228aff72c0701aa0) by lgaffie).

## [v2.3.0](https://github.com/lgandx/Responder/releases/tag/v2.3.0) - 2015-09-11

<small>[Compare with v2.1.4](https://github.com/lgandx/Responder/compare/v2.1.4...v2.3.0)</small>

### Added

- Added support for Samba4 clients ([ee033e0](https://github.com/lgandx/Responder/commit/ee033e0c7f28a0584c8ebcb2c31fe949581f0022) by lgandx).
- Added support for upstream proxies for the rogue WPAD server ([f4bd612](https://github.com/lgandx/Responder/commit/f4bd612e083698fd94308fd2fd15ba7d8d289fd8) by jrmdev).

### Fixed

- Fixed Harsh Parser variable typo ([5ab431a](https://github.com/lgandx/Responder/commit/5ab431a4fe24a2ba4666b9c51ad59a0bb8a0053d) by lgandx).
- fixed var name ([62ed8f0](https://github.com/lgandx/Responder/commit/62ed8f00626a2ad0fbbfb845e808d77938f4513a) by byt3bl33d3r).
- Fixes MDNS Name parsing error ([3261288](https://github.com/lgandx/Responder/commit/3261288c82fee415dd8e1ba64b80596ef97da490) by byt3bl33d3r).
- Fixed FTP module. ([75664a4](https://github.com/lgandx/Responder/commit/75664a4f37feb897be52480223cd1633d322ede8) by jrmdev).
- Fixing a bug in HTTP proxy, was calling recv() too many times ([ddaa9f8](https://github.com/lgandx/Responder/commit/ddaa9f87674dc8ac3f9104196f2f92cdec130682) by lanjelot).

### Changed

- changed operand ([cb9c2c8](https://github.com/lgandx/Responder/commit/cb9c2c8b97761cc5e00051efd74c9c3fdaf5762d) by byt3bl33d3r).

## [v2.1.4](https://github.com/lgandx/Responder/releases/tag/v2.1.4) - 2014-12-06

<small>[Compare with v2.1.3](https://github.com/lgandx/Responder/compare/v2.1.3...v2.1.4)</small>

### Added

- Added: FindSMB2UPTime script. Find when is the last time a >= 2008 server was updated. ([7a95ef1](https://github.com/lgandx/Responder/commit/7a95ef1474d3cea88680f359581aa89a4e9c30f5) by lgandx).

## [v2.1.3](https://github.com/lgandx/Responder/releases/tag/v2.1.3) - 2014-11-27

<small>[Compare with v2.1.2](https://github.com/lgandx/Responder/compare/v2.1.2...v2.1.3)</small>

### Added

- Added: DontRespondToName and DontRespondTo; NAC/IPS detection evasion ([36ef78f](https://github.com/lgandx/Responder/commit/36ef78f85aea5db33f37a6d1d73bf3bb7f82336f) by lgandx).
- Added --version and kost's fix for /etc/resolv.conf empty lines parsing. ([c05bdfc](https://github.com/lgandx/Responder/commit/c05bdfce17234b216b408080d9aba5db443de507) by lgandx).

## [v2.1.2](https://github.com/lgandx/Responder/releases/tag/v2.1.2) - 2014-08-26

<small>[Compare with v2.1.0](https://github.com/lgandx/Responder/compare/v2.1.0...v2.1.2)</small>

### Added

- Added: Log command line in Responder-Session.log. ([f69e93c](https://github.com/lgandx/Responder/commit/f69e93c02e81a83309d3863f6d5680b36378a16b) by lgandx).

### Fixed

- Fixed serve-always and serve-exe with the new WPAD server. ([cf7b477](https://github.com/lgandx/Responder/commit/cf7b4771caf335a1a283fae08923c413acae3343) by lgandx).

## [v2.1.0](https://github.com/lgandx/Responder/releases/tag/v2.1.0) - 2014-08-16

<small>[Compare with v2.0.9](https://github.com/lgandx/Responder/compare/v2.0.9...v2.1.0)</small>

### Fixed

- fixed: identation. ([5c9fec9](https://github.com/lgandx/Responder/commit/5c9fec923c8cb77f00466db6192b1ecb8980bdcf) by lgandx).

## [v2.0.9](https://github.com/lgandx/Responder/releases/tag/v2.0.9) - 2014-05-28

<small>[Compare with v2.0.8](https://github.com/lgandx/Responder/compare/v2.0.8...v2.0.9)</small>

### Fixed

- Fixed high cpu usage in some specific cases ([4558861](https://github.com/lgandx/Responder/commit/4558861ce2dd56c0e4c5157437c8726a26e382c5) by lgandx).

### Removed

- Removed: old style options. Just use -r instead of -r On ([a21aaf7](https://github.com/lgandx/Responder/commit/a21aaf7987e26eee5455d68cd76ff56b5466b7f2) by lgandx).

## [v2.0.8](https://github.com/lgandx/Responder/releases/tag/v2.0.8) - 2014-04-22

<small>[Compare with v2.0.7](https://github.com/lgandx/Responder/compare/v2.0.7...v2.0.8)</small>

### Added

- Added: in-scope target,  windows >= Vista support (-R) and  unicast answers only. ([2e4ed61](https://github.com/lgandx/Responder/commit/2e4ed61bba2df61a1e1165b466a369639c425955) by lgandx).

## [v2.0.7](https://github.com/lgandx/Responder/releases/tag/v2.0.7) - 2014-04-16

<small>[Compare with v2.0.6](https://github.com/lgandx/Responder/compare/v2.0.6...v2.0.7)</small>

### Added

- Added: in-scope llmnr/nbt-ns name option ([1c79bed](https://github.com/lgandx/Responder/commit/1c79bedac9083992ba019ff7134cdb3c718a6f15) by lgandx).
- Added: Kerberos server and -d cli option. ([dcede0f](https://github.com/lgandx/Responder/commit/dcede0fdf5e060e77fc51fbad2da3dbbff8edf8d) by lgandx).

## [v2.0.6](https://github.com/lgandx/Responder/releases/tag/v2.0.6) - 2014-04-01

<small>[Compare with v2.0.5](https://github.com/lgandx/Responder/compare/v2.0.5...v2.0.6)</small>

### Fixed

- Fixed [Enter] key issue ([c97a13c](https://github.com/lgandx/Responder/commit/c97a13c1bdb79b4dcdf43f889fdd586c3c39b893) by lgandx).

## [v2.0.5](https://github.com/lgandx/Responder/releases/tag/v2.0.5) - 2014-03-22

<small>[Compare with v2.0.4](https://github.com/lgandx/Responder/compare/v2.0.4...v2.0.5)</small>

### Added

- Added: In-scope IP handling for MDNS ([b14ff0b](https://github.com/lgandx/Responder/commit/b14ff0b36a100736f293ddbd8bbe1c538a370347) by lgandx).

## [v2.0.4](https://github.com/lgandx/Responder/releases/tag/v2.0.4) - 2014-03-22

<small>[Compare with v2.0.3](https://github.com/lgandx/Responder/compare/v2.0.3...v2.0.4)</small>

### Added

- Added: MDNS Poisoner ([90479ad](https://github.com/lgandx/Responder/commit/90479adcca066602885ea2bfec32953ce71d6977) by lgandx).

## [v2.0.3](https://github.com/lgandx/Responder/releases/tag/v2.0.3) - 2014-03-21

<small>[Compare with v2.0.2](https://github.com/lgandx/Responder/compare/v2.0.2...v2.0.3)</small>

### Fixed

- fix: Bind to interface bug. ([a1a4f46](https://github.com/lgandx/Responder/commit/a1a4f46c7ba8861ff71c1ea2045a72acf2c829bd) by lgandx).

## [v2.0.2](https://github.com/lgandx/Responder/releases/tag/v2.0.2) - 2014-02-06

<small>[Compare with v2.0.1](https://github.com/lgandx/Responder/compare/v2.0.1...v2.0.2)</small>

### Added

- Added: Analyze mode; Lanman Domain/SQL/Workstation passive discovery. ([2c9273e](https://github.com/lgandx/Responder/commit/2c9273eb2ca8d5080ff81273f602547fe649c259) by lgandx).

## [v2.0.1](https://github.com/lgandx/Responder/releases/tag/v2.0.1) - 2014-01-30

<small>[Compare with first commit](https://github.com/lgandx/Responder/compare/e821133708098c74497a3f9b0387a3ad048d5a48...v2.0.1)</small>

### Added

- Added: Analyze ICMP Redirect plausibility on current subnet. ([06df704](https://github.com/lgandx/Responder/commit/06df704960c556e3c2261a52827d55eb7b4ed0d4) by lgandx).
- Added: Analyze stealth mode. See all traffic, but dont answer (-A cli). Minor bugs also fixed. ([9bb2f81](https://github.com/lgandx/Responder/commit/9bb2f81044cd94f36f54c8daf7f1183bc761bb24) by lgandx).
- Added: -F command line switch to force authentication on PAC file retrieval. Default is Off ([3f48c11](https://github.com/lgandx/Responder/commit/3f48c114d5e713bfe68bef1717e18d3c266f358e) by lgandx).
- Added: IMAP module and enhanced wpad. ([af60de9](https://github.com/lgandx/Responder/commit/af60de95679f20eca4765b1450f80c48fbef689c) by lgandx).
- Added: SMTP PLAIN/LOGIN module ([6828f1b](https://github.com/lgandx/Responder/commit/6828f1b11ebfc0fc25a8fd00e8f373f3adfb7fc6) by lgandx).
- Added: POP3 module. ([f48ea3f](https://github.com/lgandx/Responder/commit/f48ea3f4b644c3eb25c63d402c6d30fcd29be529) by lgandx).
- Added: MSSQL Plaintext module ([4c3a494](https://github.com/lgandx/Responder/commit/4c3a494c86b7a95cf2c43a71bac182f231bf71cb) by lgandx).
- Added: SMBRelay module ([4dd9d8c](https://github.com/lgandx/Responder/commit/4dd9d8c1df3717ed928e73083c30e21aa5eaf8b4) by lgandx).
- added: Command switch -v for verbose mode. Responder is now less verbose. ([46b98a6](https://github.com/lgandx/Responder/commit/46b98a616d540ae618198784d0775e687371858e) by lgandx).
- Added support for .pac file requests. ([6b7e5b6](https://github.com/lgandx/Responder/commit/6b7e5b6441c7fdf19a163b8efb6fd588ccfee8ae) by lgandx).
- Added: print HTTP URL, POST data requested prior auth ([f616718](https://github.com/lgandx/Responder/commit/f6167183e046d2759ab6b885dd2f94bb2902c564) by lgandx).
- Added command switch -I. This option override Responder.conf Bind_to setting ([68de4ac](https://github.com/lgandx/Responder/commit/68de4ac26ec34bbf24524abb0c0b11ae34aa27a3) by lgandx).
- Added: in-scope only target. See Responder.conf. ([0465bd6](https://github.com/lgandx/Responder/commit/0465bd604d7cc22ef2c97f938d8564677030e5bd) by lgandx).
- Added: Fake access denied html page ([9b608aa](https://github.com/lgandx/Responder/commit/9b608aad30529e2bfea4d7c6e99343df0ba2d9d0) by lgandx).
- Added: Configuration file, removed several cli options and several fixes. ([95eed09](https://github.com/lgandx/Responder/commit/95eed099424568d4c67402f12a5de5d9d72c3041) by lgandx).
- Added: Configuration file for Responder ([d573102](https://github.com/lgandx/Responder/commit/d57310273df524b99d17c97b49ee35eb3aec7b52) by lgandx).
- Added: Bind shell listening on port 140, use it with -e or -exe option if needed ([1079de0](https://github.com/lgandx/Responder/commit/1079de052b7cc7c6caeb80e6ee081568ff359317) by Lgandx).
- Added: Ability to serve whatever kind of file via HTTP and WPAD There's now 3 new options. ([a8c2952](https://github.com/lgandx/Responder/commit/a8c29522db3555f7733a80d29271b3229e1149c6) by Lgandx).
- added -I option to bind all sockets to a specific ip (eg: listen only on eth0) ([d5088b2](https://github.com/lgandx/Responder/commit/d5088b24ee3d8bead640b37480be57fe564e70b5) by Lgandx).
- added: HTTP auth forward to SMB. This is useful for SMB Relay or LM downgrade from HTTP NTLM ESS to SMB LM. ([0fcaa68](https://github.com/lgandx/Responder/commit/0fcaa68c074e496edb2164ca35659ff636b5a361) by Lgandx).
- added automatic poisoning mode when a primary and a secondary DNS is specified. ([ccbbbe3](https://github.com/lgandx/Responder/commit/ccbbbe34535c12b664a39f5a99f98c1da79ca5a6) by Lgandx).
- Added HTTPS module. ([9250281](https://github.com/lgandx/Responder/commit/92502814aa3becdd064f0bfb160af826adb42f60) by Lgandx).
- Added support for LM hash downgrade. Default still NTLMSSP. ([09f8f72](https://github.com/lgandx/Responder/commit/09f8f7230d66cb35e1e6bed9fb2c9133ad5cc415) by Lgandx).
- Added: Client ip is now part of the cookie filename ([2718f9c](https://github.com/lgandx/Responder/commit/2718f9c51310e18e91d6d90c86657bdd72889f2a) by Lgandx).
- Added a folder for storing HTTP cookies files ([d1a14e2](https://github.com/lgandx/Responder/commit/d1a14e2f27d856ca1551232502835d6cddb3602d) by Lgandx).
- Added WPAD transparent proxy ([9f1c3bc](https://github.com/lgandx/Responder/commit/9f1c3bcba32c6feb008a39ece688522dcd9e757f) by Lgandx).

### Fixed

- Fixed WPAD cookie capture ([afe2b63](https://github.com/lgandx/Responder/commit/afe2b63c6a556a6da97e7ac89c96f89276d521c3) by lgandx).
- Fix: Command line switch typo ([4fb4233](https://github.com/lgandx/Responder/commit/4fb4233424273849085781225298de39b6c9c098) by lgandx).
- Fixed minor bugs ([f8a16e2](https://github.com/lgandx/Responder/commit/f8a16e28ee15a3af91542269e5b1ec9c69ea3d75) by Lgandx).
- Fixed duplicate entry in hash file for machine accounts ([4112b1c](https://github.com/lgandx/Responder/commit/4112b1cd5d06f021dcc145f32d29b53d4cb8d82a) by Lgandx).
- fix for anonymous NTLM connection for LDAP server ([1c47e7f](https://github.com/lgandx/Responder/commit/1c47e7fcb112d0efdb509e56a1b08d557eb9f375) by Lgandx).

### Changed

- Changed WPAD to Off by default. Use command line -w On to enable. ([bf2fdf0](https://github.com/lgandx/Responder/commit/bf2fdf083cdadf81747f87eb138a474911928b77) by lgandx).
- changed .txt to no extension. ([5f7bfa8](https://github.com/lgandx/Responder/commit/5f7bfa8cbe75d0c7fd24c8a83c44a5c3b02717a4) by lgandx).
- Changed Windows =< 5.2 documentation to XP/2003 and earlier for clarification ([56dd7b8](https://github.com/lgandx/Responder/commit/56dd7b828cf85b88073e88a8b4409f7dae791d49) by Garret Picchioni).

### Removed

- Removed bind to interface support for OsX. Responder for OsX can only listen on all interfaces. ([dbfdc27](https://github.com/lgandx/Responder/commit/dbfdc2783156cfeede5114735ae018a925b3fa78) by lgandx).

