# recblock
Blockchain for a record management and money transfer system

## Build package native
```zsh
zig build
```

## Build for windows on linux
```zsh
zig build -Dtarget=-Dtarget=x86_64-windows-gnu`
```

## Build for linux static
```zsh
zig build -Dtarget=x86_64-linux-musl
```

## Build in release mode
```zsh
zig build -Drelease-fast
```

## HOW TO USE PROGRAM

### create a chain
```zsh
zig build run -- createchain 'name'
#.eg.
zig build run -- createchain 'Genesis'
```

### get balance
```zsh
zig build run -- getbalance 'Genesis'
```

### send RBC to another Address
```zsh
zig build run -- send --amount 1 --from 'Genesis' --to 'Assan'
```

### print the blockchain ledger
```zsh
zig build run -- printchain
```
