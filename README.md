# Payload Library for the [WiFi Pineapple Pager](https://hak5.org/products/wifi-pineapple-pager) by [Hak5](https://hak5.org)

> **Note:** This repository is under construction.

This repository contains **community-developed payloads** for the Hak5 WiFi Pineapple Pager. Community developed payloads are listed and developers are encouraged to create pull requests to make changes to or submit new payloads.

**Payloads here are written in official DuckyScript™ + Bash specifically for the WiFi Pineapple Pager. Hak5 does NOT guarantee payload functionality.** <a href="#legal"><b>See Legal and Disclaimers</b></a>



<div align="center">
<img src="https://img.shields.io/github/forks/hak5/wifipineapplepager-payloads?style=for-the-badge"/>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<img src="https://img.shields.io/github/stars/hak5/wifipineapplepager-payloads?style=for-the-badge"/>
<br/>
<img src="https://img.shields.io/github/commit-activity/y/hak5/wifipineapplepager-payloads?style=for-the-badge">
<img src="https://img.shields.io/github/contributors/hak5/wifipineapple-pager?style=for-the-badge">
</div>
<br/>
<p align="center">
<br/>
<a href="https://hak5.org/blogs/payloads/tagged/wifi-pineapple-pager">View Featured Pager Payloads and Leaderboard</a>
<br/><i>Get your payload in front of thousands. Enter to win over $2,000 in prizes in the <a href="https://hak5.org/pages/payload-awards">Hak5 Payload Awards!</a></i>
</p>


<div align="center">
<a href="https://hak5.org/discord"><img src="https://img.shields.io/discord/506629366659153951?label=Hak5%20Discord&style=for-the-badge"></a>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<a href="https://youtube.com/hak5"><img src="https://img.shields.io/youtube/channel/views/UC3s0BtrBJpwNDaflRSoiieQ?label=YouTube%20Views&style=for-the-badge"/></a>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<a href="https://youtube.com/hak5"><img src="https://img.shields.io/youtube/channel/subscribers/UC3s0BtrBJpwNDaflRSoiieQ?style=for-the-badge"/></a>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<a href="https://twitter.com/hak5"><img src="https://img.shields.io/badge/follow-%40hak5-1DA1F2?logo=twitter&style=for-the-badge"/></a>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<a href="https://instagram.com/hak5gear"><img src="https://img.shields.io/badge/Instagram-E4405F?style=for-the-badge&logo=instagram&logoColor=white"/></a>
<br/><br/>

</div>

# Table of contents
<details open>
<ul>
<li><a href="#about-the-new-wifi-pineapple-pager">About the WiFi Pineapple Pager</a></li>
<li><b><a href="#contributing">Contributing Payloads</a></b></li>
<li><a href="#legal"><b>Legal and Disclaimers</b></a></li>
</ul> 
</details>


## Shop
- [WiFi Pineapple Pager](https://hak5.org/products/wifi-pineapple-pager "Purchase the NEW WiFi Pineapple Pager")
- [PayloadStudio Pro](https://hak5.org/products/payload-studio-pro "Purchase PayloadStudio Pro")
- [Shop All Hak5 Tools](https://shop.hak5.org "Shop All Hak5 Tools")
## Documentation / Learn More
-   [Documentation](https://docs.hak5.org/ "Documentation")
## Community
*Got Questions? Need some help? Reach out:*
-  [Discord](https://hak5.org/discord/ "Discord")


## Additional Links
<b> Follow the creators </b><br/>
<p >
	<a href="https://twitter.com/notkorben">Korben's Twitter</a> | 
	<a href="https://instagram.com/hak5korben">Korben's Instagram</a>
<br/>
	<a href="https://infosec.exchange/@kismetwireless">Dragorn's Mastodon</a> | 
<br/>
	<a href="https://twitter.com/hak5darren">Darren's Twitter</a> | 
	<a href="https://instagram.com/hak5darren">Darren's Instagram</a>
</p>

<br/>
<h1><a href="https://hak5.org/products/wifi-pineapple-pager">About the NEW WiFi Pineapple Pager</a></h1>

A WiFi Pineapple built for Hackers who don't stay put.


<p align="center">
<a href="https://youtu.be/GUaUerYCvs0"><img src="https://cdn.shopify.com/s/files/1/0068/2142/files/pager-transparent.png?v=1765835552"/></a>
<br/>
<i>New WiFi Pineapple Pager</i>
</p>

The first Payload-powered WiFi Pineapple is here — and it runs DuckyScript™, Hak5’s simple and powerful scripting language. Paired with Bash and backed by Linux, it brings serious scripting power to the palm of your hand.

Launch targeted attacks or set alert payloads to fire off based on live WiFi activity. Ringtones, vibes and visuals.

Take control of the airspace with the 8th generation PineAP engine — now over 100× faster. Rebuilt from the kernel up, this attack suite is hyper optimized for advanced WiFi operations, even in the most crowded RF environments.

Run Rogue AP, Man-in-the-Middle, and Deauth attacks. Nab handshakes, OSINT and more, all from a live dashboard.

# About DuckyScript™

DuckyScript is the payload language of Hak5 gear.

Originating on the Hak5 USB Rubber Ducky as a standalone language, the WiFi Pineapple Pager uses DuckyScript commands to bring the ethos of easy-to-use actions to the payload language.

DuckyScript commands are always in all capital letters to distinguish them from other system or script language commands.  Typically, they take a small number of options (or sometimes no options at all).

Payloads can be constructed of DuckyScript commands alone, or combined with the power of bash scripting and system commands to create fully custom, advanced actions.

The files in this repository are _the source code_ for your payloads and run _directly on the device_ **no compilation required** - simply place your `payload.sh` in the appropriate directory and you're ready to go!

<h1><a href="https://payloadstudio.hak5.org">Build your payloads with PayloadStudio</a></h1>
<p align="center">
Take your DuckyScript™ payloads to the next level with this full-featured,<b> web-based (entirely client side) </b> development environment.
<br/>
<a href="https://payloadstudio.hak5.org"><img src="https://cdn.shopify.com/s/files/1/0068/2142/products/payload-studio-icon_180x.png?v=1659135374"></a>
<br/>
<i>Payload studio features all of the conveniences of a modern IDE, right from your browser. From syntax highlighting and auto-completion to live error-checking and repo synchronization - building payloads for Hak5 hotplug tools has never been easier!
<br/><br/>
Supports your favorite Hak5 gear - USB Rubber Ducky, Bash Bunny, Key Croc, Shark Jack, Packet Squirrel & LAN Turtle!
<br/><br/></i><br/>
<a href="https://hak5.org/products/payload-studio-pro">Become a PayloadStudio Pro</a> and <b> Unleash your hacking creativity! </b>
<br/>
OR
<br/>
<a href="https://payloadstudio.hak5.org/community/"> Try Community Edition FREE</a> 
<br/><br/>
<img src="https://cdn.shopify.com/s/files/1/0068/2142/files/themes1_1_600x.gif?v=1659642557">
<br/>
<i> Payload Studio Themes Preview GIF </i>
<br/><br/>
<img src="https://cdn.shopify.com/s/files/1/0068/2142/files/AUTOCOMPLETE3_600x.gif?v=1659640513">
<br/>
<i> Payload Studio Autocomplete Preview GIF </i>
</p>

<h1><a href='https://payloadhub.com'>Contributing</a></h1>

<p align="center">
<a href="https://payloadhub.com"><img src="https://cdn.shopify.com/s/files/1/0068/2142/files/payloadhub.png?v=1652474600"></a>
<br/>
<a href="https://payloadhub.com">View Featured Payloads and Leaderboard </a>
</p>

# Please adhere to the following best practices and style guides when submitting a payload.

Once you have developed your payload, you are encouraged to contribute to this repository by submitting a Pull Request. Reviewed and Approved pull requests will add your payload to this repository, where they may be publically available.

Please include all resources required for the payload to run. If needed, provide a README.md in the root of your payload's directory to explain things such as intended use, required configurations, or anything that will not easily fit in the comments of the payload.txt itself. Please make sure that your payload is tested, and free of errors. If your payload contains (or is based off of) the work of other's please make sure to cite their work giving proper credit. 


### Purely Destructive payloads will not be accepted. No, it's not "just a prank".
Subject to change. Please ensure any submissions meet the [latest version](https://github.com/hak5/wifipineapple-pager/blob/master/README.md) of these standards before submitting a Pull Request.


## Naming Conventions

Please give your payload a unique, descriptive and appropriate name. Do not use spaces in payload, directory or file names. Each payload should be submit into its own directory, with `-` or `_` used in place of spaces, to one of the categories such as exfiltration, interception, sniffing, or recon. Do not create your own category.

The payload itself should be named `payload`.

## Payload Configuration

In many cases, payloads will require some level of configuration by the end payload user. Be sure to take the following into careful consideration to ensure your payload is easily tested, used and maintained. 

- Remember to use PLACEHOLDERS for configurable portions of your payload - do not share your personal URLs, API keys, Passphrases, etc...
- Do not leave defaults that point at live services
- Make note of both required and optional configuration(s) in your payload using comments at the top of your payload or "inline" where applicable

## Payload Format

Payloads should begin with comments specifying at the very least the name of the payload and author. Additional information such as a brief description, the target, any dependencies / prerequisites and the LED status used is helpful.

    # Title: Example payload
	# Description: Example payload with configuration options
	# Author: Hak5
	# Version: 1.0
	# Category: Remote-Access
	# Net Mode: NAT
	#
	# LED State Descriptions
	# Magenta Solid - Configuring NETMODE
	# LED OFF - Waiting for BUTTON
	# Red Blink 2 Times - Connection Failed
	# Amber Blink 5 Times - Connection Successful
	# Red Blink 1 Time - Command Failed
	# Cyan Blink 1 Time - Command Successful

### Configuration Options

Configurable options should be specified in variables at the top of the payload file:

    # Options
    SSH_USER="username"
	SSH_HOST="hostname"
    PORT=31337


## Staged Payloads
"Staged payloads" are payloads that **download** code from some resource external to the payload.txt. 

While staging code used in payloads is often useful and appropriate, using this (or another) github repository as the means of deploying those stages is not. This repository is **not a CDN for deployment on target systems**. 

Staged code should be copied to and hosted on an appropriate server for doing so **by the end user** - Github and this repository are simply resources for sharing code among developers and users.
See: [GitHub acceptable use policies](https://docs.github.com/en/site-policy/acceptable-use-policies/github-acceptable-use-policies#5-site-access-and-safety)

Additionally, any source code that is intended to be staged **(by the end user on the appropriate infrastructure)** should be included in any payload submissions either in the comments of the payload itself or as a seperate file. **Links to staged code are unacceptable**; not only for the reasons listed above but also for version control and user safety reasons. Arbitrary code hidden behind some pre-defined external resource via URL in a payload could be replaced at any point in the future unbeknownst to the user -- potentially turning a harmless payload into something dangerous.

### Including URLs
URLs used for retrieving staged code should refer exclusively to **example.com** using DEFINE in any payload submissions

### Staged Example

**Example scenario: your payload downloads a script and the executes it on a target machine.**
- Include the script in the directory with your payload
- Provide instructions for the user to move the script to the appropriate hosting service.
- Provide a DEFINE with the placeholder example.com for the user to easily configure once they have hosted the script



<h1><a href="https://hak5.org/pages/policy">Legal</a></h1>

Payloads from this repository are provided for educational purposes only.  Hak5 gear is intended for authorized auditing and security analysis purposes only where permitted subject to local and international laws where applicable. Users are solely responsible for compliance with all laws of their locality. Hak5 LLC and affiliates claim no responsibility for unauthorized or unlawful use.

WiFi Pineapple and DuckyScript are the trademarks of Hak5 LLC. Copyright © 2010 Hak5 LLC. All rights reserved. No part of this work may be reproduced or transmitted in any form or by any means without prior written permission from the copyright owner.
WiFi Pineapple and DuckyScript are subject to the Hak5 license agreement (https://hak5.org/license)
DuckyScript is the intellectual property of Hak5 LLC for the sole benefit of Hak5 LLC and its licensees. To inquire about obtaining a license to use this material in your own project, contact us. Please report counterfeits and brand abuse to legal@hak5.org.
This material is for education, authorized auditing and analysis purposes where permitted subject to local and international laws. Users are solely responsible for compliance. Hak5 LLC claims no responsibility for unauthorized or unlawful use.
Hak5 LLC products and technology are only available to BIS recognized license exception ENC favorable treatment countries pursuant to US 15 CFR Supplement No 3 to Part 740.

See also: 

[Hak5 Software License Agreement](https://shop.hak5.org/pages/software-license-agreement)
	
[Terms of Service](https://shop.hak5.org/pages/terms-of-service)

# Disclaimer
<h3><b>As with any script, you are advised to proceed with caution.</h3></b>
<h3><b>Generally, payloads may execute commands on your device. As such, it is possible for a payload to damage your device. Payloads from this repository are provided AS-IS without warranty. While Hak5 makes a best effort to review payloads, there are no guarantees as to their effectiveness.</h3></b>
