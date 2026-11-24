# certs/

TAK client certificate for the **mesh ↔ TAK bridge** over TLS (port 8089). **Never commit real certificates.** The repository's `.gitignore` keeps `*.pem`, `*.p12`, `*.key` and `*.crt` in this folder out of git.

| File | Required | What it is |
|---|---|---|
| `client.pem` | yes (TLS) | the Pager's client certificate **and** private key, unencrypted PEM |
| `ca.pem` | recommended | the TAK Server CA (truststore), PEM, so the server certificate is checked |

Convert your TAK `.p12` files on a PC:

```
openssl pkcs12 -legacy -in pager01.p12 -nodes -out client.pem      # drop -legacy on OpenSSL 1.1
openssl pkcs12 -legacy -in truststore-root.p12 -nokeys -out ca.pem
```

Already use **PagerTAK** on this Pager? If its `certs/` folder has `client.pem`, PagerMesh uses that one and you need nothing here.

TLS also needs the `openssl` command on the Pager: `opkg install openssl-util`. TCP (8087) and UDP need no certificate.
