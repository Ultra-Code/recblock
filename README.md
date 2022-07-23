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

### create a wallet
```zsh
zig build run -- createwallet

#.eg. to create two new wallets
# Assan's wallet
$ zig-dev build run -- createwallet
Your new address is 'AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg'

# Gaddy's wallet
$ zig-dev build run -- createwallet
Your new address is 'AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ'
```
### create a chain
```zsh
# create a blockchain at Gaddy's wallet
zig-dev build run -- createchain AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ

#.eg output
$ zig-dev build run -- createchain AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ
info: new blockchain is create with address 'AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ'
hash of the created blockchain is '0031D180D286BD75D0BD543AD391E071A36A32157C2D11D9629B9B7EA5B5349C'
info: You get a reward of RBC 10 for mining the coinbase transaction
```

### get balance
```zsh
zig-dev build run -- getbalance AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ

# get Gaddy's balance
$ zig-dev build run -- getbalance AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ
'AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ' has a balance of RBC 10

# get Assan's balance
$ zig-dev build run -- getbalance AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg
'AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg' has a balance of RBC 0
```

### send RBC to another Address
```zsh
zig-dev build run -- send --amount 7 --from AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ --to AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg

# send RBC 7 from Gaddy's wallet to Assan's wallet
$ zig-dev build run -- send --amount 7 --from AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ --to AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg
info: new transaction is '000AFBA4B03A90EDDF3B4534176714E39981F86AD8CAF5C773D48DE520F164B8'
done sending RBC 7 from 'AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ' to 'AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg'
'AZqc8JTbSu1xMQQD2TcVRZnj5oji5oIOLQ' now has a balance of 3 and 'AY0IZ21T7XFFEPwoiVxAbnYMxuZNshdRzg' a balance of 7
```

### print the blockchain ledger after performing some transactions
```zsh
zig build run -- printchain

# eg
$ zig build run -- printchain
info: starting blockchain iteration

info: previous hash is '00DAEC993931264A1125D31C7350DD8CEB5324AD66395BC3275B37AB11890623'
info: hash of current block is '00F37D69BA313642C046202009326F3B6C7DC264A14349642A227CFB542908D3'
info: nonce is 42
info: POW: true


info: previous hash is '005DD84136F0389689A89700347D0385396B7DED10A52178F2A932FE68CAC2FE'
info: hash of current block is '00DAEC993931264A1125D31C7350DD8CEB5324AD66395BC3275B37AB11890623'
info: nonce is 660
info: POW: true


info: previous hash is '000AFBA4B03A90EDDF3B4534176714E39981F86AD8CAF5C773D48DE520F164B8'
info: hash of current block is '005DD84136F0389689A89700347D0385396B7DED10A52178F2A932FE68CAC2FE'
info: nonce is 539
info: POW: true


info: previous hash is '0031D180D286BD75D0BD543AD391E071A36A32157C2D11D9629B9B7EA5B5349C'
info: hash of current block is '000AFBA4B03A90EDDF3B4534176714E39981F86AD8CAF5C773D48DE520F164B8'
info: nonce is 29
info: POW: true


info: previous hash is '0000000000000000000000000000000000000000000000000000000000000000'
info: hash of current block is '0031D180D286BD75D0BD543AD391E071A36A32157C2D11D9629B9B7EA5B5349C'
info: nonce is 387
info: POW: true


info: done
```
