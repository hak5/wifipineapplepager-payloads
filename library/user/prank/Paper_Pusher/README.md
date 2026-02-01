
<div align="center">

# Paper-Pusher
**A [Hak5 WiFi Pineapple Pager](https://shop.hak5.org/products/pager) payload for sending spam to WiFi connected printers over LAN.**

![gif](https://github.com/user-attachments/assets/792e6522-ade0-4bfb-bed7-25e3a3336714)

github.com/OSINTI4L

</div>

Paper-Pusher uses `Nmap` to scan the LAN subnet to find paper printers with port 9100 open and sends spam to be printed via RAW printing with `Netcat`.

The payload assumes that the subnet netmask is: `255.255.255.0`.

You can enter text to be printed when prompted or leave blank to dispense blank paper only. You will also be prompted for how many pages you would like to be printed.

If you have multiple printers on the LAN it might break the script. I don't have multiple printers so I can't test it, *shrugs*.

This payload is ported from the original [Paper-Pusher.sh](https://github.com/OSINTI4L/Paper-Pusher).

*Shout out to SpuriousIndices aka the Printer God for teaching me how to mess with printers.*
