# SQLCipher upstream provenance

- Project: SQLCipher Community Edition
- Upstream: <https://github.com/sqlcipher/sqlcipher>
- Version: 4.17.0
- Source commit: `810db22f575ee7cf94ea96a3e91622b5fcece3dc`
- Release archive SHA-256:
  `79c0e164b9c059e7487bf8f29272f601cca5f3312cc267461f81e349962a5058`
- License: BSD-3-Clause; retained in `SQLCIPHER-LICENSE.md`

`sqlite3.c` and `include/sqlite3.h` are the official generated amalgamation.
They were generated on macOS with:

```bash
CFLAGS='-O2 \
  -DSQLITE_HAS_CODEC \
  -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
  -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown \
  -DSQLCIPHER_CRYPTO_CC' \
LDFLAGS='-framework Security -framework Foundation' \
./configure --disable-tcl --with-tempstore=yes
make
```

Swift Package Manager supplies the equivalent macros in `Package.swift`.
CommonCrypto is part of macOS, so the packaged application has no Homebrew,
OpenSSL, or external dynamic-library dependency.
