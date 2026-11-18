# Hemisphera

Private [ReaPack](https://reapack.com) repository.

## Layout

Packages live in category folders (e.g. `Scripts/Category/My script.lua`), each
starting with a ReaPack metadata header:

```lua
-- @description My script
-- @author Your Name
-- @version 1.0
-- @changelog Initial release
```

## Updating the index

`index.xml` is maintained with [reapack-index](https://github.com/cfillion/reapack-index):

```sh
gem install reapack-index
reapack-index --commit   # scan history, update index.xml and commit it
```

## Importing in REAPER

Extensions → ReaPack → Import repositories… and paste the raw URL of
`index.xml` (e.g. `https://raw.githubusercontent.com/<user>/<repo>/main/index.xml`).
