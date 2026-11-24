# Deploy with Remix

Files in this folder are single-file versions (all imports inlined) of the contracts, so Remix needs no npm imports.

| File | Deploy this contract | Constructor arguments |
|---|---|---|
| `RoscaGroup.flat.sol` | `RoscaGroup` | none |
| `PassportGate.flat.sol` (optional) | `PassportGate` | `attester` (address that signs Passport attestations) |
| `GroupFactory.flat.sol` | `GroupFactory` | see below |

`GroupFactory.flat.sol` also contains `DefaultRegistry`. Do not deploy it yourself: the factory creates it in its constructor.
Each file contains library and interface contracts too. In Remix, pick the contract named in the table from the CONTRACT dropdown.

## Compiler settings (must match)

- Compiler: 0.8.28
- EVM version: cancun
- Optimization: enabled, 200 runs

These flat files were compiled with exactly these settings. Runtime sizes: `RoscaGroup` 19,890 bytes (limit 24,576), `GroupFactory` 4,987, `PassportGate` 2,268.

## Order

1. Deploy `RoscaGroup` (no arguments). Copy its address as `IMPLEMENTATION`.
2. Optional: deploy `PassportGate(attester)`. Copy its address as `GATE`. If you skip the gate, use `0x0000000000000000000000000000000000000000` as `GATE` (circles then cannot use the Passport gate).
3. Deploy `GroupFactory` with these 8 arguments in order:

| # | Name | Meaning | Example |
|---|---|---|---|
| 1 | `admin_` | can only pause or unpause creating new circles. Use a multisig | `0xYourAdmin` |
| 2 | `implementation_` | address from step 1 | `IMPLEMENTATION` |
| 3 | `gate_` | address from step 2, or the zero address | `GATE` |
| 4 | `minPhiBps_` | minimum holdback in basis points (5000 = 50%) | `3000` |
| 5 | `minDepositBps_` | minimum deposit as basis points of one installment (10000 = 100%) | `10000` |
| 6 | `minC_` | smallest installment, in USDC base units (6 decimals, 1000000 = 1 USDC) | `1000000` |
| 7 | `maxC_` | largest installment, same units | `1000000000` |
| 8 | `maxDuration_` | longest allowed circle, in seconds (31536000 = 365 days) | `31536000` |

The example values are the ones used for the Arc Testnet deployment. They are immutable once deployed, so choose your own for anything else.

In Remix, paste the arguments for the Deploy button as one comma separated line, for example:
`0xAdmin,0xImplementation,0xGate,3000,10000,1000000,1000000000,31536000`

## Remix setup for Arc

1. Install a wallet that can add custom networks (for example MetaMask) and add the network:
   - Arc Testnet: chain id 5042002, RPC https://rpc.testnet.arc.io, explorer https://explorer.testnet.arc.io
   - Arc mainnet: chain id 5042, RPC https://rpc.mainnet.arc.io, explorer https://explorer.arc.io
2. In Remix, Deploy & Run Transactions: set ENVIRONMENT to "Injected Provider".
3. Leave VALUE at 0. On Arc the gas token is USDC, so the account needs a USDC balance for gas. Use the testnet faucet for Arc Testnet.
4. Start on Arc Testnet. Mainnet uses real funds and every transaction is irreversible. Review the addresses and constructor arguments yourself before confirming. Arc Studio does not deploy to mainnet.

## Check after deploying (Read functions on the factory)

- `admin()` equals your admin address
- `implementation()` equals the `RoscaGroup` address
- `gate()` equals your gate address (or zero)
- `registry()` returns the `DefaultRegistry` the factory created
- `minC()`, `maxC()`, `minPhiBps()`, `minDepositBps()`, `maxDuration()` equal what you entered

Then put the addresses in `.env` for the app (see the main README) and rebuild.
