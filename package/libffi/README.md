# libffi compatibility fallback

Exact copy of `package/libs/libffi/Makefile` from
VIKINGYFY/immortalwrt commit `533597a3745e1fb46b0996df36b2b6fb650cf048`
(`owrt`), including the upstream `fficonfig.h` staging fix
`32bec3df4163228f00dd1cd054a28e7053f4d2ac` following the core import
`9b835ec6264f3364a22a9c67909f16bf5e5328d1`.
Makefile SHA256: `2bab7a694f4c59d2e28769e0060bcf9951ec6c5b6fbff7e8f4776e40aae62a12`.
The original GPL notice in the recipe is preserved; libffi source is MIT-licensed.

`Scripts/PRIVATE.sh` calls the installer after feeds installation and before
configuration. It only fills a missing recipe in `wrt/package/libs/libffi`;
upstream core/feed recipes remain unchanged. Once upstream main contains libffi,
the fallback sleeps automatically. No feed downgrade or branch switch is used.
