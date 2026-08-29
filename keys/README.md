# Development signing keys

`dev.key` / `dev.crt` are a **development-only** RSA-4096 key pair used to
sign the FIT images built by this flake and compiled into both barebox stages
as the `fit` keyring (`CONFIG_CRYPTO_PUBLIC_KEYS`).

The private key is checked into this repository on purpose: the point of this
repository is a *reproducible reference* bootchain, and anyone must be able to
rebuild and re-sign the images bit-for-bit. That also means:

* **Never use these keys for anything but this example.**
* A security assessment of the bootchain must treat the private key as
  public knowledge. Attacks that require signing a payload with `dev.key`
  are therefore out of scope; attacks that bypass or weaken verification
  are in scope.

Regenerate with:

```sh
openssl genrsa -out dev.key 4096
openssl req -batch -new -x509 -days 36500 -key dev.key -out dev.crt \
    -subj "/CN=bvbe-development-key-DO-NOT-USE-IN-PRODUCTION"
```

The file names matter: `mkimage -k keys` looks up `<key-name-hint>.key` and
`<key-name-hint>.crt`, and the `key-name-hint` in `config/fit/*.its` is `dev`.
